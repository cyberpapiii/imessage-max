import Foundation

/// Watches Messages.app's outgoing file transfers for a staged attachment.
///
/// Messages exposes transfers only by name, so a send records how many
/// outgoing transfers already carry the name (`baseline`) before handing
/// the file over, and only the transfers after that count belong to it.
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
    private static let deferredRemovalDelay: Duration = .seconds(30)

    static func outgoingStatuses(named trackingName: String) throws -> [String] {
        let execution = try Osascript.run(statusesForNameScript, arguments: [trackingName]).get()
        let output = execution.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        guard execution.terminationStatus == 0 else {
            // Status probe is not a send: never map through SendScript.classifyStderr
            // (fileNotFound / chatNotFound arms are wrong here).
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

    /// Polls until the transfer finishes or fails, or the poll window closes.
    /// Removes the staged copy at terminal states, and on timeout after a
    /// grace delay because Messages may still be reading it.
    static func waitForCompletion(
        of staged: OutgoingFileStager.StagedFile,
        baseline: Int,
        stager: OutgoingFileStager
    ) -> Result<Void, SendFailure> {
        let deadline = Date().addingTimeInterval(pollTimeout)
        var sawPending = false

        while Date() < deadline {
            do {
                let newStatuses = Array(try outgoingStatuses(named: staged.trackingName).dropFirst(baseline))
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
                return .failure(SendFailure(error, disposition: .mayHaveCompleted))
            } catch {
                return .failure(SendFailure(.failed(ClientErrorMessages.internalDetail(error, context: "Checking attachment transfer status")), disposition: .mayHaveCompleted))
            }

            Thread.sleep(forTimeInterval: pollInterval)
        }

        stager.scheduleRemoval(staged, after: deferredRemovalDelay)
        let outcome: SendError = sawPending
            ? .transferPending(staged.trackingName)
            : .transferStatusUnknown(staged.trackingName)
        return .failure(SendFailure(outcome, disposition: .mayHaveCompleted))
    }
}
