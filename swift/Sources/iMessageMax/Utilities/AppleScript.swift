// Sources/iMessageMax/Utilities/AppleScript.swift
import Foundation

enum SendError: LocalizedError {
    case automationPermissionRequired
    case messagesAppUnavailable
    case recipientNotFound(String)
    case chatNotFound(String)
    case fileNotFound(String)
    case transferPending(String)
    case transferFailed(String)
    case transferStatusUnknown(String)
    case timeout
    case failed(String)
    case invalidParams(String)

    var errorDescription: String? {
        switch self {
        case .automationPermissionRequired:
            return """
                Messages.app Automation permission required. \
                When prompted, click 'OK' to allow iMessage Max to send messages. \
                If you missed the prompt: System Settings → Privacy & Security → \
                Automation → Enable Messages.app for your terminal/application.
                """
        case .messagesAppUnavailable:
            return "Messages.app is not responding. Please open Messages.app and try again."
        case .recipientNotFound(let recipient):
            return "Could not find recipient '\(recipient)' in Messages.app."
        case .chatNotFound(let guid):
            return "Could not find chat '\(guid)' in Messages.app."
        case .fileNotFound(let path):
            return "Could not read file at '\(path)'."
        case .transferPending(let filename):
            return "Messages accepted '\(filename)', but the transfer is still pending and could not be confirmed as delivered yet."
        case .transferFailed(let filename):
            return "Messages created a transfer for '\(filename)', but it failed."
        case .transferStatusUnknown(let filename):
            return "Messages accepted '\(filename)', but no reliable transfer status could be confirmed."
        case .timeout:
            return "Send operation timed out. Messages.app may be unresponsive."
        case .failed(let message):
            return "Send failed: \(message)"
        case .invalidParams(let message):
            return message
        }
    }
}

enum AppleScriptRunner {
    struct ScriptExecutionResult {
        let stdout: String
        let stderr: String
        let terminationStatus: Int32
    }

    struct PreparedOutgoingFile {
        let fileURL: URL
        let trackingName: String
        let existingOutgoingTransferCount: Int
    }

    enum TransferObservation {
        case finished
        case failed
        case pending
        case unknown
    }

    // `system attribute` corrupts non-ASCII input from the environment, so all
    // dynamic values are passed through `argv` to preserve Unicode end-to-end.
    private static let transferStatusesForNameScript = """
        on run argv
            set trackingName to item 1 of argv
            tell application "Messages"
                get transfer status of (every file transfer whose name is trackingName and direction is outgoing)
            end tell
        end run
        """

    private static let sendTextToParticipantScript = """
        on run argv
            set recipientId to item 1 of argv
            set messageText to item 2 of argv
            tell application "Messages"
                set targetService to 1st account whose service type = iMessage
                set targetBuddy to participant recipientId of targetService
                send messageText to targetBuddy
            end tell
        end run
        """

    private static let sendTextToChatScript = """
        on run argv
            set chatGuid to item 1 of argv
            set messageText to item 2 of argv
            tell application "Messages"
                set targetChat to chat id chatGuid
                send messageText to targetChat
            end tell
        end run
        """

    private static let sendFileToParticipantScript = """
        on run argv
            set recipientId to item 1 of argv
            set filePath to item 2 of argv
            set attachmentFile to POSIX file filePath
            tell application "Messages"
                set targetService to 1st account whose service type = iMessage
                set targetBuddy to participant recipientId of targetService
                send attachmentFile to targetBuddy
            end tell
        end run
        """

    private static let sendFileToChatScript = """
        on run argv
            set chatGuid to item 1 of argv
            set filePath to item 2 of argv
            set attachmentFile to POSIX file filePath
            tell application "Messages"
                set targetChat to chat id chatGuid
                send attachmentFile to targetChat
            end tell
        end run
        """

    static func sendTextToParticipant(handle: String, message: String) -> Result<Void, SendError> {
        guard handle.count <= 100 else {
            return .failure(.invalidParams("Recipient too long"))
        }
        guard message.count <= 20_000 else {
            return .failure(.invalidParams("Message too long (max 20,000 chars)"))
        }

        return run(
            script: sendTextToParticipantScript,
            arguments: [handle, message],
            missingTargetError: .recipientNotFound(handle)
        )
    }

    static func sendTextToChat(guid: String, message: String) -> Result<Void, SendError> {
        guard !guid.isEmpty else {
            return .failure(.invalidParams("Chat guid is required"))
        }
        guard message.count <= 20_000 else {
            return .failure(.invalidParams("Message too long (max 20,000 chars)"))
        }

        return run(
            script: sendTextToChatScript,
            arguments: [guid, message],
            missingTargetError: .chatNotFound(guid)
        )
    }

    static func sendFileToParticipant(handle: String, filePath: String) -> Result<Void, SendError> {
        guard handle.count <= 100 else {
            return .failure(.invalidParams("Recipient too long"))
        }
        let preparedFile: PreparedOutgoingFile
        do {
            preparedFile = try prepareTrackedOutgoingFile(sourcePath: filePath)
        } catch let error as SendError {
            return .failure(error)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }

        let handoff = run(
            script: sendFileToParticipantScript,
            arguments: [handle, preparedFile.fileURL.path],
            missingTargetError: .recipientNotFound(handle)
        )
        guard case .success = handoff else { return handoff }
        return waitForTransferCompletion(preparedFile: preparedFile)
    }

    static func sendFileToChat(guid: String, filePath: String) -> Result<Void, SendError> {
        guard !guid.isEmpty else {
            return .failure(.invalidParams("Chat guid is required"))
        }
        let preparedFile: PreparedOutgoingFile
        do {
            preparedFile = try prepareTrackedOutgoingFile(sourcePath: filePath)
        } catch let error as SendError {
            return .failure(error)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }

        let handoff = run(
            script: sendFileToChatScript,
            arguments: [guid, preparedFile.fileURL.path],
            missingTargetError: .chatNotFound(guid)
        )
        guard case .success = handoff else { return handoff }
        return waitForTransferCompletion(preparedFile: preparedFile)
    }

    static func prepareTrackedOutgoingFile(sourcePath: String) throws -> PreparedOutgoingFile {
        cleanupOldStagedFilesIfPossible()

        let validatedPath = try validateFilePath(sourcePath)
        let sourceURL = URL(fileURLWithPath: validatedPath)
        let trackingName = sourceURL.lastPathComponent
        let existingOutgoingTransferCount = try queryOutgoingTransferStatuses(
            trackingName: trackingName
        ).count
        let stagedDirectory = stagingRootDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stagedURL = stagedDirectory.appendingPathComponent(trackingName, isDirectory: false)

        try FileManager.default.createDirectory(
            at: stagedDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: sourceURL, to: stagedURL)

        return PreparedOutgoingFile(
            fileURL: stagedURL,
            trackingName: trackingName,
            existingOutgoingTransferCount: existingOutgoingTransferCount
        )
    }

    static func interpretTransferStatuses(_ statuses: [String]) -> TransferObservation {
        let normalized = statuses
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        if normalized.contains("failed") {
            return .failed
        }
        if normalized.contains("finished") {
            return .finished
        }
        if normalized.contains(where: pendingTransferStatuses.contains) {
            return .pending
        }
        return .unknown
    }

    private static let pendingTransferStatuses: Set<String> = [
        "preparing", "waiting", "transferring", "finalizing"
    ]

    private static func validateFilePath(_ filePath: String) throws -> String {
        let expandedPath = (filePath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue else {
            throw SendError.fileNotFound(filePath)
        }
        guard FileManager.default.isReadableFile(atPath: expandedPath) else {
            throw SendError.fileNotFound(filePath)
        }
        return expandedPath
    }

    private static func queryOutgoingTransferStatuses(trackingName: String) throws -> [String] {
        let result = execute(
            script: transferStatusesForNameScript,
            arguments: [trackingName],
            timeoutSeconds: 30
        )
        switch result {
        case .failure(let error):
            throw error
        case .success(let execution):
            let output = execution.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            guard execution.terminationStatus == 0 else {
                throw SendError.failed(output.isEmpty ? execution.stderr : output)
            }

            if output.isEmpty || output == "missing value" {
                return []
            }

            return output
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    private static func waitForTransferCompletion(preparedFile: PreparedOutgoingFile) -> Result<Void, SendError> {
        let timeoutSeconds: TimeInterval = 15
        let pollInterval: TimeInterval = 0.5
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var sawPending = false
        var sawStatuses = false

        while Date() < deadline {
            do {
                let allStatuses = try queryOutgoingTransferStatuses(trackingName: preparedFile.trackingName)
                let newStatuses = Array(allStatuses.dropFirst(preparedFile.existingOutgoingTransferCount))
                let observation = interpretTransferStatuses(newStatuses)
                switch observation {
                case .finished:
                    return .success(())
                case .failed:
                    return .failure(.transferFailed(preparedFile.trackingName))
                case .pending:
                    sawPending = true
                    sawStatuses = true
                case .unknown:
                    if !newStatuses.isEmpty {
                        sawStatuses = true
                    }
                }
            } catch let error as SendError {
                return .failure(error)
            } catch {
                return .failure(.failed(error.localizedDescription))
            }

            Thread.sleep(forTimeInterval: pollInterval)
        }

        if sawPending {
            return .failure(.transferPending(preparedFile.trackingName))
        }
        if sawStatuses {
            return .failure(.transferStatusUnknown(preparedFile.trackingName))
        }
        return .failure(.transferStatusUnknown(preparedFile.trackingName))
    }

    private static func stagingRootDirectory() -> URL {
        let picturesDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)
        return picturesDirectory.appendingPathComponent("imessage-max-staging", isDirectory: true)
    }

    private static func cleanupOldStagedFilesIfPossible() {
        let root = stagingRootDirectory()
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-48 * 60 * 60)
        for url in contents {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    static func runScriptForTesting(
        script: String,
        arguments: [String]
    ) -> Result<String, SendError> {
        let result = execute(script: script, arguments: arguments, timeoutSeconds: 30)
        switch result {
        case .failure(let error):
            return .failure(error)
        case .success(let execution):
            guard execution.terminationStatus == 0 else {
                let message = execution.stderr.isEmpty ? execution.stdout : execution.stderr
                return .failure(.failed(message))
            }
            return .success(execution.stdout)
        }
    }

    private static func run(
        script: String,
        arguments: [String],
        missingTargetError: SendError
    ) -> Result<Void, SendError> {
        let result = execute(script: script, arguments: arguments, timeoutSeconds: 30)
        switch result {
        case .failure(let error):
            return .failure(error)
        case .success(let execution):
            if execution.terminationStatus != 0 {
                let stderr = execution.stderr.lowercased()

                // Detect Automation permission errors
                if stderr.contains("not allowed") ||
                    stderr.contains("not permitted") ||
                    stderr.contains("assistive access")
                {
                    return .failure(.automationPermissionRequired)
                }

                // Detect if Messages app isn't running/responding
                if stderr.contains("connection is invalid") ||
                    stderr.contains("application isn't running")
                {
                    return .failure(.messagesAppUnavailable)
                }

                if stderr.contains("no such file") ||
                    stderr.contains("file") && stderr.contains("wasn’t found") ||
                    stderr.contains("file") && stderr.contains("wasn't found")
                {
                    return .failure(.fileNotFound(arguments.last ?? ""))
                }

                if stderr.contains("can't get participant") ||
                    stderr.contains("can't get chat") ||
                    stderr.contains("doesn't understand") ||
                    stderr.contains("invalid key form")
                {
                    return .failure(missingTargetError)
                }

                return .failure(.failed(stderr))
            }

            return .success(())
        }
    }

    private static func execute(
        script: String,
        arguments: [String],
        timeoutSeconds: Int
    ) -> Result<ScriptExecutionResult, SendError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script] + (arguments.isEmpty ? [] : ["--"] + arguments)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()

            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                process.waitUntilExit()
                semaphore.signal()
            }

            let result = semaphore.wait(timeout: .now() + .seconds(timeoutSeconds))
            if result == .timedOut {
                process.terminate()
                return .failure(.timeout)
            }

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""

            return .success(
                ScriptExecutionResult(
                    stdout: stdout,
                    stderr: stderr,
                    terminationStatus: process.terminationStatus
                )
            )
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }
}
