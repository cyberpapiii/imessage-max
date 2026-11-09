import Foundation

protocol ScriptRunning: Sendable {
    func send(_ payload: SendPayload, to target: SendTarget) async -> Result<Void, SendFailure>
}

typealias ScriptExecutor = @Sendable (_ script: String, _ arguments: [String]) -> Result<Osascript.Output, SendError>

struct LiveScriptRunner: ScriptRunning {
    let access: MessagesAccess
    let stager: OutgoingFileStager
    let runScript: ScriptExecutor

    init(
        access: MessagesAccess,
        stager: OutgoingFileStager = OutgoingFileStager(),
        runScript: @escaping ScriptExecutor = { Osascript.run($0, arguments: $1) }
    ) {
        self.access = access
        self.stager = stager
        self.runScript = runScript
    }

    /// The send blocks its thread while it starts Messages, waits for the
    /// process and polls the transfer, so it runs off the cooperative pool.
    func send(_ payload: SendPayload, to target: SendTarget) async -> Result<Void, SendFailure> {
        await MessagesAccess.offPool { sendBlocking(payload, to: target) }
    }

    func sendBlocking(_ payload: SendPayload, to target: SendTarget) -> Result<Void, SendFailure> {
        switch payload {
        case .text(let body):
            access.prepareForScript()
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
            return TransferMonitor.waitForCompletion(
                of: staged, baseline: baseline, stager: stager,
                statusQuery: { try TransferMonitor.outgoingStatuses(named: $0, runScript: runScript) })
        }
    }

    private func stage(_ path: String) throws -> (OutgoingFileStager.StagedFile, baseline: Int) {
        stager.sweepExpired()
        let source = try stager.openSource(path)
        defer { source.close() }
        access.prepareForScript()
        let baseline = try TransferMonitor.outgoingStatuses(named: source.trackingName, runScript: runScript).count
        return (try stager.stage(source), baseline)
    }

    private func dispatch(
        _ payloadKind: SendScript.PayloadKind,
        _ payloadArgument: String,
        to target: SendTarget,
        sentFileName: String
    ) -> Result<Void, SendFailure> {
        let result = runDispatch(payloadKind, payloadArgument, to: target, sentFileName: sentFileName)
        access.noteScriptOutcome(result)
        return result
    }

    private func runDispatch(
        _ payloadKind: SendScript.PayloadKind,
        _ payloadArgument: String,
        to target: SendTarget,
        sentFileName: String
    ) -> Result<Void, SendFailure> {
        let script = SendScript.source(target.scriptKind, payloadKind)
        switch runScript(script, [target.scriptArgument, payloadArgument]) {
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
