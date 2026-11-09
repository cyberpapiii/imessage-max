import Foundation

enum TransferMonitor {
    enum Observation {
        case finished
        case failed
        case pending
        case unknown
    }

    private static let statusesForNameScript = """
        on run argv
            set trackingName to item 1 of argv
            tell application "Messages"
                get transfer status of (every file transfer whose name is trackingName and direction is outgoing)
            end tell
        end run
        """

    private static let pendingStatuses: Set<String> = [
        "preparing", "waiting", "transferring", "finalizing"
    ]

    private static let pollTimeout: TimeInterval = 15
    private static let pollInterval: TimeInterval = 0.5
    static let deferredRemovalDelay: Duration = .seconds(30)

    static func outgoingStatuses(
        named trackingName: String,
        runScript: ScriptExecutor = { Osascript.run($0, arguments: $1) }
    ) throws -> [String] {
        let execution = try runScript(statusesForNameScript, [trackingName]).get()
        let output = execution.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        guard execution.terminationStatus == 0 else {
            let raw = output.isEmpty ? execution.stderr : output
            guard let line = Osascript.clientSafeFirstLine(raw, logLabel: "transfer status stderr (scrubbed)") else {
                throw SendError.failed("Transfer status query failed. Check the server log for details.")
            }
            throw SendError.failed(line.isEmpty ? "transfer status query failed" : line)
        }

        if output.isEmpty || output == "missing value" {
            return []
        }

        return output
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
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

    static func waitForCompletion(
        of staged: OutgoingFileStager.StagedFile,
        baseline: Int,
        stager: OutgoingFileStager,
        statusQuery: (String) throws -> [String] = { try outgoingStatuses(named: $0) },
        removalDelay: Duration = deferredRemovalDelay
    ) -> Result<Void, SendFailure> {
        let deadline = Date().addingTimeInterval(pollTimeout)
        var sawPending = false

        while Date() < deadline {
            do {
                let newStatuses = Array(try statusQuery(staged.trackingName).dropFirst(baseline))
                switch interpret(newStatuses) {
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
            } catch let error as SendError {
                stager.scheduleRemoval(staged, after: removalDelay)
                return .failure(SendFailure(error, disposition: .mayHaveCompleted))
            } catch {
                stager.scheduleRemoval(staged, after: removalDelay)
                return .failure(SendFailure(.failed(ClientErrorMessages.internalDetail(error, context: "Checking attachment transfer status")), disposition: .mayHaveCompleted))
            }

            Thread.sleep(forTimeInterval: pollInterval)
        }

        stager.scheduleRemoval(staged, after: removalDelay)
        let outcome: SendError = sawPending
            ? .transferPending(staged.trackingName)
            : .transferStatusUnknown(staged.trackingName)
        return .failure(SendFailure(outcome, disposition: .mayHaveCompleted))
    }
}
