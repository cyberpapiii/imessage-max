// Sources/iMessageMax/Utilities/AppleScript.swift
import Foundation

// MARK: - ScriptRunning protocol

/// Abstraction over the four send-execution functions used by SendTool.
/// The production implementation is LiveScriptRunner; tests inject a stub.
protocol ScriptRunning: Sendable {
    func sendTextToParticipant(handle: String, message: String) async -> Result<Void, SendFailure>
    func sendFileToParticipant(handle: String, filePath: String) async -> Result<Void, SendFailure>
    func sendTextToChat(guid: String, message: String) async -> Result<Void, SendFailure>
    func sendFileToChat(guid: String, filePath: String) async -> Result<Void, SendFailure>
}

/// Production implementation: forwards to AppleScriptRunner statics.
/// The statics block their thread (process wait, transfer polling), so run
/// them on a GCD background thread, never on the cooperative pool. GCD grows
/// its pool to absorb blocked threads. The cooperative pool does not, so a
/// blocked send there would stall unrelated requests service-wide.
struct LiveScriptRunner: ScriptRunning {
    private func onBackgroundThread(
        _ work: @escaping @Sendable () -> Result<Void, SendFailure>
    ) async -> Result<Void, SendFailure> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    func sendTextToParticipant(handle: String, message: String) async -> Result<Void, SendFailure> {
        await onBackgroundThread {
            AppleScriptRunner.sendTextToParticipant(handle: handle, message: message)
        }
    }

    func sendFileToParticipant(handle: String, filePath: String) async -> Result<Void, SendFailure> {
        await onBackgroundThread {
            AppleScriptRunner.sendFileToParticipant(handle: handle, filePath: filePath)
        }
    }

    func sendTextToChat(guid: String, message: String) async -> Result<Void, SendFailure> {
        await onBackgroundThread {
            AppleScriptRunner.sendTextToChat(guid: guid, message: message)
        }
    }

    func sendFileToChat(guid: String, filePath: String) async -> Result<Void, SendFailure> {
        await onBackgroundThread {
            AppleScriptRunner.sendFileToChat(guid: guid, filePath: filePath)
        }
    }
}

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

    static func sendTextToParticipant(handle: String, message: String) -> Result<Void, SendFailure> {
        guard handle.count <= 100 else {
            return .failure(SendFailure(.invalidParams("Recipient too long"), disposition: .notStarted))
        }
        guard message.count <= 20_000 else {
            return .failure(SendFailure(.invalidParams("Message too long (max 20,000 chars)"), disposition: .notStarted))
        }

        return run(
            script: sendTextToParticipantScript,
            arguments: [handle, message],
            missingTargetError: .recipientNotFound(handle)
        )
    }

    static func sendTextToChat(guid: String, message: String) -> Result<Void, SendFailure> {
        guard !guid.isEmpty else {
            return .failure(SendFailure(.invalidParams("Chat guid is required"), disposition: .notStarted))
        }
        guard message.count <= 20_000 else {
            return .failure(SendFailure(.invalidParams("Message too long (max 20,000 chars)"), disposition: .notStarted))
        }

        return run(
            script: sendTextToChatScript,
            arguments: [guid, message],
            missingTargetError: .chatNotFound(guid)
        )
    }

    static func sendFileToParticipant(handle: String, filePath: String) -> Result<Void, SendFailure> {
        guard handle.count <= 100 else {
            return .failure(SendFailure(.invalidParams("Recipient too long"), disposition: .notStarted))
        }
        let preparedFile: PreparedOutgoingFile
        do {
            preparedFile = try prepareTrackedOutgoingFile(sourcePath: filePath)
        } catch let error as SendError {
            return .failure(SendFailure(error, disposition: .notStarted))
        } catch {
            return .failure(SendFailure(.failed(ClientErrorMessages.internalDetail(error, context: "Preparing the attachment")), disposition: .notStarted))
        }

        let handoff = run(
            script: sendFileToParticipantScript,
            arguments: [handle, preparedFile.fileURL.path],
            missingTargetError: .recipientNotFound(handle)
        )
        guard case .success = handoff else {
            removeStagedDirectory(for: preparedFile)
            return handoff
        }
        return waitForTransferCompletion(preparedFile: preparedFile)
    }

    static func sendFileToChat(guid: String, filePath: String) -> Result<Void, SendFailure> {
        guard !guid.isEmpty else {
            return .failure(SendFailure(.invalidParams("Chat guid is required"), disposition: .notStarted))
        }
        let preparedFile: PreparedOutgoingFile
        do {
            preparedFile = try prepareTrackedOutgoingFile(sourcePath: filePath)
        } catch let error as SendError {
            return .failure(SendFailure(error, disposition: .notStarted))
        } catch {
            return .failure(SendFailure(.failed(ClientErrorMessages.internalDetail(error, context: "Preparing the attachment")), disposition: .notStarted))
        }

        let handoff = run(
            script: sendFileToChatScript,
            arguments: [guid, preparedFile.fileURL.path],
            missingTargetError: .chatNotFound(guid)
        )
        guard case .success = handoff else {
            removeStagedDirectory(for: preparedFile)
            return handoff
        }
        return waitForTransferCompletion(preparedFile: preparedFile)
    }

    static func prepareTrackedOutgoingFile(
        sourcePath: String,
        existingOutgoingTransferStatuses: (String) throws -> [String] = queryOutgoingTransferStatuses
    ) throws -> PreparedOutgoingFile {
        cleanupOldStagedFilesIfPossible()

        let (validatedPath, sourceHandle) = try openValidatedSource(sourcePath)
        defer { try? sourceHandle.close() }

        let trackingName = (validatedPath as NSString).lastPathComponent
        let existingOutgoingTransferCount = try existingOutgoingTransferStatuses(trackingName).count

        let root = stagingRootDirectory()
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: ownerOnly)
        try FileManager.default.setAttributes(ownerOnly, ofItemAtPath: root.path)   // pre-existing 0755 roots
        guard !SecurePath.hasSymlinkComponent(root.path) else {
            throw SendError.invalidParams("Attachment staging directory is behind a symbolic link.")
        }

        let stagedDirectory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stagedURL = stagedDirectory.appendingPathComponent(trackingName, isDirectory: false)
        try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: false, attributes: ownerOnly)

        let prepared = PreparedOutgoingFile(
            fileURL: stagedURL,
            trackingName: trackingName,
            existingOutgoingTransferCount: existingOutgoingTransferCount
        )
        do {
            try AttachmentSource.copy(sourceHandle, to: stagedURL)
        } catch {
            removeStagedDirectory(for: prepared)
            throw SendError.fileNotFound(trackingName)
        }
        return prepared
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

    /// Lexically absolutize, refuse symlinks anywhere in the path, then open
    /// the file without following links and confirm it is a regular file.
    /// Error text never contains the caller's path, only the basename.
    private static func openValidatedSource(_ filePath: String) throws -> (path: String, handle: FileHandle) {
        let basename = (filePath as NSString).lastPathComponent
        guard let lexical = SecurePath.absoluteLexicalPath(filePath) else {
            throw SendError.invalidParams("Attachment path for '\(basename)' must be absolute (or start with ~/).")
        }
        if SecurePath.hasSymlinkComponent(lexical) {
            throw SendError.invalidParams("Attachment '\(basename)' is or is behind a symbolic link; pass the real path.")
        }
        do {
            return (lexical, try AttachmentSource.openFile(at: lexical))
        } catch AttachmentSource.Failure.symlink {
            throw SendError.invalidParams("Attachment '\(basename)' is or is behind a symbolic link; pass the real path.")
        } catch AttachmentSource.Failure.notRegularFile {
            throw SendError.invalidParams("Attachment '\(basename)' must be a regular file.")
        } catch AttachmentSource.Failure.notAbsolute {
            throw SendError.invalidParams("Attachment path for '\(basename)' must be absolute (or start with ~/).")
        } catch {
            // notFound, notPermitted, other: same client-facing wording as before.
            throw SendError.fileNotFound(basename)
        }
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
                // Status probe is not a send: never map through classifySendStderr
                // (fileNotFound / chatNotFound arms are wrong here).
                let raw = (output.isEmpty ? execution.stderr : output)
                    .replacingOccurrences(of: "\u{2019}", with: "'")
                let firstLine = String(
                    (raw.split(separator: "\n", maxSplits: 1).first ?? "").prefix(300)
                )
                if firstLine.contains("/Users/")
                    || firstLine.contains("/private/")
                    || firstLine.contains("/var/")
                    || firstLine.contains("imessage-max-staging")
                {
                    Log.error("transfer status stderr (scrubbed): \(firstLine)")
                    throw SendError.failed(
                        "Transfer status query failed. Check the server log for details."
                    )
                }
                throw SendError.failed(
                    firstLine.isEmpty ? "transfer status query failed" : firstLine
                )
            }

            if output.isEmpty || output == "missing value" {
                return []
            }

            return output
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    private static func waitForTransferCompletion(preparedFile: PreparedOutgoingFile) -> Result<Void, SendFailure> {
        let timeoutSeconds: TimeInterval = 15
        let pollInterval: TimeInterval = 0.5
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var sawPending = false

        while Date() < deadline {
            do {
                let allStatuses = try queryOutgoingTransferStatuses(trackingName: preparedFile.trackingName)
                let newStatuses = Array(allStatuses.dropFirst(preparedFile.existingOutgoingTransferCount))
                let observation = interpretTransferStatuses(newStatuses)
                switch observation {
                case .finished:
                    removeStagedDirectory(for: preparedFile)
                    return .success(())
                case .failed:
                    removeStagedDirectory(for: preparedFile)
                    return .failure(SendFailure(.transferFailed(preparedFile.trackingName), disposition: .mayHaveCompleted))
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

        if sawPending {
            scheduleDeferredStagedRemoval(preparedFile, after: .seconds(30))
            return .failure(SendFailure(.transferPending(preparedFile.trackingName), disposition: .mayHaveCompleted))
        }
        scheduleDeferredStagedRemoval(preparedFile, after: .seconds(30))
        return .failure(SendFailure(.transferStatusUnknown(preparedFile.trackingName), disposition: .mayHaveCompleted))
    }

    /// Messages may still be reading the staged copy for a few seconds after
    /// a timed-out poll. Delete after a grace delay, not 48 hours later.
    static func scheduleDeferredStagedRemoval(
        _ preparedFile: PreparedOutgoingFile,
        after delay: Duration
    ) {
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + AsyncTimeout.dispatchInterval(for: delay)
        ) {
            removeStagedDirectory(for: preparedFile)
        }
    }

    /// Removes one per-send staging directory. Safe only at terminal
    /// transfer states (finished/failed) or before Messages was handed the
    /// file, never while a transfer may still be reading the copy.
    /// Guarded to the staging root so a bug can never delete anything else.
    static func removeStagedDirectory(for preparedFile: PreparedOutgoingFile) {
        let directory = preparedFile.fileURL.deletingLastPathComponent()
        let rootPath = stagingRootDirectory().standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        guard directoryPath.hasPrefix(rootPath + "/"), directoryPath != rootPath else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }

    static func stagingRootDirectory() -> URL {
        let picturesDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)
        return picturesDirectory.appendingPathComponent("imessage-max-staging", isDirectory: true)
    }

    static func cleanupOldStagedFilesIfPossible() {
        let root = stagingRootDirectory()
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-1 * 60 * 60)
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

    /// Map osascript stderr onto a client-facing SendError.
    ///
    /// AppleScript writes the typographic apostrophe in its errors ("can’t get
    /// chat id", "doesn’t understand"). Matching only the straight form misses
    /// every one of them, and the raw stderr (script line and column numbers
    /// included) falls through to the client. Normalize once up front so the
    /// checks below only have to spell the straight form.
    ///
    /// `sentFileName` is the filename alone. The full argument is the private
    /// staged copy, not the path the caller asked to send (plan 023).
    ///
    /// Internal rather than private so the classification can be tested without
    /// running osascript.
    static func classifySendStderr(
        _ rawStderr: String,
        sentFileName: String,
        missingTargetError: SendError
    ) -> SendError {
        let stderr = rawStderr
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .lowercased()

        if stderr.contains("not allowed") ||
            stderr.contains("not permitted") ||
            stderr.contains("assistive access")
        {
            return .automationPermissionRequired
        }

        if stderr.contains("connection is invalid") ||
            stderr.contains("application isn't running")
        {
            return .messagesAppUnavailable
        }

        if stderr.contains("no such file") ||
            stderr.contains("file") && stderr.contains("wasn't found")
        {
            return .fileNotFound(sentFileName)
        }

        if stderr.contains("can't get participant") ||
            stderr.contains("can't get chat") ||
            stderr.contains("doesn't understand") ||
            stderr.contains("invalid key form")
        {
            return missingTargetError
        }

        // Untrusted, unbounded osascript stderr: keep the first line, clamped.
        // Absolute paths (home, staging) never go to the client. `stderr` is
        // lowercased above, so every literal here must be lowercase too.
        let firstLine = String(
            (stderr.split(separator: "\n", maxSplits: 1).first ?? "").prefix(300)
        )
        if firstLine.contains("/users/")
            || firstLine.contains("/private/")
            || firstLine.contains("/var/")
            || firstLine.contains("imessage-max-staging")
        {
            Log.error("osascript stderr (scrubbed for client): \(firstLine)")
            return .failed("Send failed. Check the server log for details.")
        }
        return .failed(firstLine)
    }

    private static func run(
        script: String,
        arguments: [String],
        missingTargetError: SendError
    ) -> Result<Void, SendFailure> {
        let result = execute(script: script, arguments: arguments, timeoutSeconds: 30)
        switch result {
        case .failure(.timeout):
            return .failure(SendFailure(.timeout, disposition: .mayHaveCompleted))
        case .failure(let error):
            return .failure(SendFailure(error, disposition: .notStarted))
        case .success(let execution):
            if execution.terminationStatus != 0 {
                return .failure(SendFailure(
                    classifySendStderr(
                        execution.stderr,
                        sentFileName: ((arguments.last ?? "") as NSString).lastPathComponent,
                        missingTargetError: missingTargetError
                    ),
                    disposition: .mayHaveCompleted
                ))
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

            // Drain pipes concurrently with the exit wait. Reading only after
            // exit deadlocks when the child fills a ~64KB pipe buffer: the
            // child blocks on write, never exits, and the wait times out.
            // Each queue writes its own property and the group join below
            // establishes the happens-before edge for the reads.
            final class DrainedOutput: @unchecked Sendable {
                var stdout = Data()
                var stderr = Data()
            }
            let drained = DrainedOutput()
            let drainGroup = DispatchGroup()

            drainGroup.enter()
            DispatchQueue.global().async {
                drained.stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                drainGroup.leave()
            }
            drainGroup.enter()
            DispatchQueue.global().async {
                drained.stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                drainGroup.leave()
            }

            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                process.waitUntilExit()
                semaphore.signal()
            }

            let result = semaphore.wait(timeout: .now() + .seconds(timeoutSeconds))
            if result == .timedOut {
                process.terminate()
                // Give SIGTERM a moment, then SIGKILL so the pipes close and the
                // drain threads can exit. osascript ignores SIGTERM while blocked
                // in a Messages Apple event; without this the readers block on an
                // open pipe forever, one pair per timed-out send.
                if drainGroup.wait(timeout: .now() + .seconds(2)) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    _ = drainGroup.wait(timeout: .now() + .seconds(2))
                }
                return .failure(.timeout)
            }
            drainGroup.wait()

            let stdout = String(data: drained.stdout, encoding: .utf8) ?? ""
            let stderr = String(data: drained.stderr, encoding: .utf8) ?? ""

            return .success(
                ScriptExecutionResult(
                    stdout: stdout,
                    stderr: stderr,
                    terminationStatus: process.terminationStatus
                )
            )
        } catch {
            return .failure(.failed(ClientErrorMessages.internalDetail(error, context: "Running AppleScript")))
        }
    }
}
