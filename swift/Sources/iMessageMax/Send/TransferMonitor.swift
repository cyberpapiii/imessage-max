import Foundation

/// Follows the Messages file transfer a send created, by its id.
///
/// Messages finds transfers by file name only, and a staged copy keeps the
/// name the recipient sees, so two sends of files with the same name used to
/// read each other's status. Now a send holds `nameLocks` for its name from
/// the snapshot of existing transfer ids, through the dispatch, until its own
/// new transfer id shows up. After that it polls that id alone, and another
/// send of the same name can start.
enum TransferMonitor {
    enum Observation {
        case finished
        case failed
        case pending
        case unknown
    }

    static let idsForNameScript = """
        on run argv
            set trackingName to item 1 of argv
            tell application "Messages"
                set transferIds to id of every file transfer whose name is trackingName and direction is outgoing
            end tell
            set AppleScript's text item delimiters to linefeed
            return transferIds as text
        end run
        """

    static let statusForIdScript = """
        on run argv
            set transferId to item 1 of argv
            tell application "Messages"
                get transfer status of file transfer id transferId
            end tell
        end run
        """

    private static let pendingStatuses: Set<String> = [
        "preparing", "waiting", "transferring", "finalizing"
    ]

    static let pollTimeout: TimeInterval = 15
    private static let pollInterval: TimeInterval = 0.5
    static let deferredRemovalDelay: Duration = .seconds(30)

    /// One holder at a time per transfer name. AppleScript's `is` ignores
    /// case, so the key does too.
    static let nameLocks = KeyedLock()

    static func lockKey(_ trackingName: String) -> String { trackingName.lowercased() }

    /// The ids of the outgoing transfers named `trackingName`.
    static func outgoingTransferIds(
        named trackingName: String,
        runScript: ScriptExecutor = { ScriptGate.shared.run($0, arguments: $1) }
    ) throws -> [String] {
        try output(of: idsForNameScript, [trackingName], runScript: runScript)
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The transfer status of one transfer, such as "finished".
    static func transferStatus(
        id transferId: String,
        runScript: ScriptExecutor = { ScriptGate.shared.run($0, arguments: $1) }
    ) throws -> String {
        let status = try output(of: statusForIdScript, [transferId], runScript: runScript)
        return status == "missing value" ? "" : status
    }

    private static func output(of script: String, _ arguments: [String], runScript: ScriptExecutor) throws -> String {
        let execution = try runScript(script, arguments).get()
        let output = execution.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        guard execution.terminationStatus == 0 else {
            let raw = output.isEmpty ? execution.stderr : output
            guard let line = Osascript.clientSafeFirstLine(raw, logLabel: "transfer status stderr (scrubbed)") else {
                throw SendError.failed("Transfer status query failed. Check the server log for details.")
            }
            throw SendError.failed(line.isEmpty ? "transfer status query failed" : line)
        }
        return output
    }

    static func interpret(_ statuses: [String]) -> Observation {
        let normalized = statuses
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        if normalized.contains("failed") {
            return .failed
        }
        if normalized.contains("finished") {
            return .finished
        }
        if normalized.contains(where: pendingStatuses.contains) {
            return .pending
        }
        return .unknown
    }

    /// Waits for the transfers this send created: ids named like the staged
    /// file that were not in `baseline`. Call it while holding the name's lock,
    /// so no other send of the same name can add one. Returns an empty list
    /// when none appeared by `deadline`.
    static func newTransferIds(
        named trackingName: String,
        excluding baseline: Set<String>,
        until deadline: Date,
        idQuery: (String) throws -> [String],
        pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws -> [String] {
        while true {
            let fresh = try idQuery(trackingName).filter { !baseline.contains($0) }
            if !fresh.isEmpty || Date() >= deadline { return fresh }
            pause(pollInterval)
        }
    }

    /// Polls the status of `transferIds` until they finish, fail or
    /// `deadline` passes, and removes the staged copy once it is no longer needed.
    static func waitForCompletion(
        of staged: OutgoingFileStager.StagedFile,
        transferIds: [String],
        until deadline: Date,
        stager: OutgoingFileStager,
        statusQuery: (String) throws -> String,
        removalDelay: Duration = deferredRemovalDelay,
        pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> Result<Void, SendFailure> {
        var sawPending = false

        while !transferIds.isEmpty {
            do {
                switch interpret(try transferIds.map(statusQuery)) {
                case .finished:
                    stager.remove(staged)
                    return .success(())
                case .failed:
                    stager.remove(staged)
                    return .failure(SendFailure(.transferFailed(staged.trackingName), disposition: .mayHaveCompleted))
                case .pending:
                    sawPending = true
                case .unknown:
                    break
                }
            } catch {
                return .failure(queryFailed(error, staged: staged, stager: stager, removalDelay: removalDelay))
            }
            if Date() >= deadline { break }
            pause(pollInterval)
        }

        stager.scheduleRemoval(staged, after: removalDelay)
        let outcome: SendError = sawPending
            ? .transferPending(staged.trackingName)
            : .transferStatusUnknown(staged.trackingName)
        return .failure(SendFailure(outcome, disposition: .mayHaveCompleted))
    }

    /// A status query failed after the dispatch: the file may be on its way,
    /// so the staged copy stays a while for Messages to read.
    static func queryFailed(
        _ error: any Error,
        staged: OutgoingFileStager.StagedFile,
        stager: OutgoingFileStager,
        removalDelay: Duration = deferredRemovalDelay
    ) -> SendFailure {
        stager.scheduleRemoval(staged, after: removalDelay)
        let sendError = (error as? SendError)
            ?? .failed(ClientErrorMessages.internalDetail(error, context: "Checking attachment transfer status"))
        return SendFailure(sendError, disposition: .mayHaveCompleted)
    }
}

/// A blocking lock per key, for the threads `MessagesAccess.offPool` starts.
final class KeyedLock: @unchecked Sendable {
    private let condition = NSCondition()
    private var held: Set<String> = []

    func lock(_ key: String) {
        condition.lock()
        defer { condition.unlock() }
        while held.contains(key) { condition.wait() }
        held.insert(key)
    }

    func unlock(_ key: String) {
        condition.lock()
        defer { condition.unlock() }
        held.remove(key)
        condition.broadcast()
    }
}
