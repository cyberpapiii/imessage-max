import Foundation

protocol ScriptRunning: Sendable {
    func send(_ payload: SendPayload, to target: SendTarget) async -> Result<Void, SendFailure>
}

struct LiveScriptRunner: ScriptRunning {
    let stager: OutgoingFileStager

    init(stager: OutgoingFileStager = OutgoingFileStager()) {
        self.stager = stager
    }

    /// The send blocks its thread (process wait, transfer polling), so run
    /// it on a GCD background thread, never on the cooperative pool. GCD grows
    /// its pool to absorb blocked threads. The cooperative pool does not, so a
    /// blocked send there would stall unrelated requests service-wide.
    func send(_ payload: SendPayload, to target: SendTarget) async -> Result<Void, SendFailure> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: sendBlocking(payload, to: target))
            }
        }
    }

    func sendBlocking(_ payload: SendPayload, to target: SendTarget) -> Result<Void, SendFailure> {
        switch payload {
        case .text(let body):
            return dispatch(payload.scriptKind, body, to: target, sentFileName: "")

        case .file(let path):
            let staged: OutgoingFileStager.StagedFile
            let baseline: Int
            do {
                (staged, baseline) = try stage(path)
            } catch let error as SendError {
                return .failure(SendFailure(error, disposition: .notStarted))
            } catch {
                return .failure(SendFailure(.failed(ClientErrorMessages.internalDetail(error, context: "Preparing the attachment")), disposition: .notStarted))
            }

            let handoff = dispatch(payload.scriptKind, staged.fileURL.path, to: target, sentFileName: staged.trackingName)
            guard case .success = handoff else {
                stager.remove(staged)
                return handoff
            }
            return TransferMonitor.waitForCompletion(of: staged, baseline: baseline, stager: stager)
        }
    }

    private func stage(_ path: String) throws -> (OutgoingFileStager.StagedFile, baseline: Int) {
        stager.sweepExpired()
        let source = try stager.openSource(path)
        defer { source.close() }
        let baseline = try TransferMonitor.outgoingStatuses(named: source.trackingName).count
        return (try stager.stage(source), baseline)
    }

    private func dispatch(
        _ payloadKind: SendScript.PayloadKind,
        _ payloadArgument: String,
        to target: SendTarget,
        sentFileName: String
    ) -> Result<Void, SendFailure> {
        let script = SendScript.source(target.scriptKind, payloadKind)
        switch Osascript.run(script, arguments: [target.scriptArgument, payloadArgument]) {
        case .failure(.timeout):
            return .failure(SendFailure(.timeout, disposition: .mayHaveCompleted))
        case .failure(let error):
            return .failure(SendFailure(error, disposition: .notStarted))
        case .success(let output):
            return SendScript.interpretResult(
                stdout: output.stdout,
                stderr: output.stderr,
                terminationStatus: output.terminationStatus,
                sentFileName: sentFileName,
                missingTargetError: target.missingTargetError
            )
        }
    }
}
