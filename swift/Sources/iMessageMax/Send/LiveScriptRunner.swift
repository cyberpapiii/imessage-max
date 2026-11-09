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
        runScript: @escaping ScriptExecutor = { ScriptGate.shared.run($0, arguments: $1) }
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
            if let blocked = access.prepareForSend() {
                return .failure(SendFailure(blocked, disposition: .notStarted))
            }
            return dispatch(payload.scriptKind, body, to: target, sentFileName: "")

        case .file(let path):
            let source: OutgoingFileStager.Source
            do {
                stager.sweepExpired()
                source = try stager.openSource(path)
            } catch {
                return .failure(Self.notStarted(error))
            }

            // Held until this send's own transfer id is known, so a send of
            // another file with the same name cannot take it for its own.
            let key = TransferMonitor.lockKey(source.trackingName)
            TransferMonitor.nameLocks.lock(key)
            let handoff = handOff(source, to: target)
            TransferMonitor.nameLocks.unlock(key)

            switch handoff {
            case .failure(let failure):
                return .failure(failure)
            case .success(let transfer):
                return TransferMonitor.waitForCompletion(
                    of: transfer.staged, transferIds: transfer.ids, until: transfer.deadline, stager: stager,
                    statusQuery: { transferId in
                        // Messages may have quit or crashed since the handoff.
                        // Started by the query itself it would show its window.
                        access.prepareForScript()
                        return try TransferMonitor.transferStatus(id: transferId, runScript: runScript)
                    })
            }
        }
    }

    private struct HandedOffTransfer {
        let staged: OutgoingFileStager.StagedFile
        /// The transfers Messages created for this send.
        let ids: [String]
        let deadline: Date
    }

    /// Stages the file, dispatches it, and finds the transfer it created.
    /// The caller holds the lock for the file's name.
    private func handOff(_ source: OutgoingFileStager.Source, to target: SendTarget) -> Result<HandedOffTransfer, SendFailure> {
        let staged: OutgoingFileStager.StagedFile
        let baseline: Set<String>
        do {
            defer { source.close() }
            if let blocked = access.prepareForSend() { throw blocked }
            baseline = Set(try TransferMonitor.outgoingTransferIds(named: source.trackingName, runScript: runScript))
            staged = try stager.stage(source)
        } catch {
            return .failure(Self.notStarted(error))
        }

        let dispatched = dispatch(.file, staged.fileURL.path, to: target, sentFileName: staged.trackingName)
        if case .failure(let failure) = dispatched {
            stager.remove(staged)
            return .failure(failure)
        }

        let deadline = Date().addingTimeInterval(TransferMonitor.pollTimeout)
        do {
            let ids = try TransferMonitor.newTransferIds(
                named: staged.trackingName, excluding: baseline, until: deadline,
                idQuery: { name in
                    access.prepareForScript()
                    return try TransferMonitor.outgoingTransferIds(named: name, runScript: runScript)
                })
            return .success(HandedOffTransfer(staged: staged, ids: ids, deadline: deadline))
        } catch {
            return .failure(TransferMonitor.queryFailed(error, staged: staged, stager: stager))
        }
    }

    private static func notStarted(_ error: any Error) -> SendFailure {
        let sendError = (error as? SendError)
            ?? .failed(ClientErrorMessages.internalDetail(error, context: "Preparing the attachment"))
        return SendFailure(sendError, disposition: .notStarted)
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
