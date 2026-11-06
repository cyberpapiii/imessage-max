import Foundation

/// The AppleScript that hands one payload to Messages.app, and the one-line
/// result protocol it prints back.
///
/// Every dynamic value (handle, chat guid, message text, file path) travels
/// through `argv`: `system attribute` corrupts non-ASCII input from the
/// environment, so argv is what keeps Unicode intact end to end.
///
/// The script prints one line:
///   IMESSAGE_MAX_RESULT <tab> ok|failure <tab> <DeliveryDisposition> <tab> errno <tab> message
/// The message is last because it may itself contain tabs.
enum SendScript {
    enum TargetKind { case participant, chat }
    enum PayloadKind { case text, file }

    static let resultMarker = "IMESSAGE_MAX_RESULT"
    private static let okOutcome = "ok"
    private static let failureOutcome = "failure"
    private static let preDispatchPhase = "pre_dispatch"
    private static let dispatchStartedPhase = "dispatch_started"

    static func source(_ target: TargetKind, _ payload: PayloadKind) -> String {
        let targetVariable: String
        let resolveTarget: [String]
        let targetReference: String
        switch target {
        case .participant:
            targetVariable = "recipientId"
            resolveTarget = [
                "set targetService to 1st account whose service type = iMessage",
                "set targetBuddy to participant recipientId of targetService",
            ]
            targetReference = "targetBuddy"
        case .chat:
            targetVariable = "chatGuid"
            resolveTarget = ["set targetChat to chat id chatGuid"]
            targetReference = "targetChat"
        }

        let payloadVariable: String
        let preparePayload: [String]
        let payloadReference: String
        switch payload {
        case .text:
            payloadVariable = "messageText"
            preparePayload = []
            payloadReference = "messageText"
        case .file:
            payloadVariable = "filePath"
            preparePayload = ["set attachmentFile to POSIX file filePath"]
            payloadReference = "attachmentFile"
        }

        func resultLine(_ outcome: String, _ disposition: DeliveryDisposition, _ errno: String, _ message: String) -> String {
            "return \"\(resultMarker)\" & tab & \"\(outcome)\" & tab & \"\(disposition.rawValue)\" & tab & \(errno) & tab & \(message)"
        }

        var lines: [String] = []
        func add(_ depth: Int, _ text: String) {
            lines.append(String(repeating: " ", count: 4 * depth) + text)
        }
        add(0, "on run argv")
        add(1, "set \(targetVariable) to item 1 of argv")
        add(1, "set \(payloadVariable) to item 2 of argv")
        preparePayload.forEach { add(1, $0) }
        // dispatchPhase flips just before `send`, so an error raised while
        // resolving the target is known not to have reached Messages.
        add(1, "set dispatchPhase to \"\(preDispatchPhase)\"")
        add(1, "try")
        add(2, "tell application \"Messages\"")
        resolveTarget.forEach { add(3, $0) }
        add(3, "set dispatchPhase to \"\(dispatchStartedPhase)\"")
        add(3, "send \(payloadReference) to \(targetReference)")
        add(2, "end tell")
        add(2, resultLine(okOutcome, .completed, "\"0\"", "\"\""))
        add(1, "on error errorMessage number errorNumber")
        add(2, "if dispatchPhase is \"\(preDispatchPhase)\" then")
        add(3, resultLine(failureOutcome, .notStarted, "errorNumber", "errorMessage"))
        add(2, "end if")
        add(2, resultLine(failureOutcome, .mayHaveCompleted, "errorNumber", "errorMessage"))
        add(1, "end try")
        add(0, "end run")
        return lines.joined(separator: "\n")
    }

    /// Turns the raw osascript output of a send script into a typed result.
    static func interpretResult(
        stdout: String,
        stderr: String,
        terminationStatus: Int32,
        sentFileName: String,
        missingTargetError: SendError
    ) -> Result<Void, SendFailure> {
        let markerLine = stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .last { $0.hasPrefix(resultMarker + "\t") }

        guard let markerLine else {
            if terminationStatus != 0 {
                return .failure(SendFailure(
                    classifyStderr(stderr, sentFileName: sentFileName, missingTargetError: missingTargetError),
                    disposition: .mayHaveCompleted
                ))
            }
            return .failure(SendFailure(
                .failed("Messages returned no structured send result"),
                disposition: .mayHaveCompleted
            ))
        }

        let fields = markerLine.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5 else {
            return .failure(SendFailure(.failed("Messages returned a malformed send result"), disposition: .mayHaveCompleted))
        }
        if fields[1] == okOutcome, fields[2] == DeliveryDisposition.completed.rawValue {
            return .success(())
        }
        // Anything but an explicit not_started, including an unexpected
        // "completed" on a failure line, may have reached Messages.
        let disposition: DeliveryDisposition =
            fields[2] == DeliveryDisposition.notStarted.rawValue ? .notStarted : .mayHaveCompleted
        let error = classifyStderr(fields[4], sentFileName: sentFileName, missingTargetError: missingTargetError)
        return .failure(SendFailure(error, disposition: disposition))
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
    /// staged copy, not the path the caller asked to send.
    static func classifyStderr(
        _ rawStderr: String,
        sentFileName: String,
        missingTargetError: SendError
    ) -> SendError {
        let stderr = Osascript.normalizingApostrophes(rawStderr).lowercased()

        if stderr.contains("not allowed") ||
            stderr.contains("not permitted") ||
            stderr.contains("not authorized") ||
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

        guard let line = Osascript.clientSafeFirstLine(rawStderr, logLabel: "osascript stderr (scrubbed for client)") else {
            return .failed("Send failed. Check the server log for details.")
        }
        return .failed(line)
    }
}
