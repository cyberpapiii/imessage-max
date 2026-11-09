import Foundation

/// Every dynamic value (handle, chat guid, message text, file path) reaches
/// the script through `argv`. Reading it from the environment with
/// `system attribute` corrupts non-ASCII input, and argv keeps Unicode intact.
enum SendScript {
    enum TargetKind { case participant, chat }
    enum PayloadKind { case text, file }

    static let resultMarker = "IMESSAGE_MAX_RESULT"
    private static let okOutcome = "ok"
    private static let failureOutcome = "failure"
    private static let preDispatchPhase = "pre_dispatch"
    private static let dispatchStartedPhase = "dispatch_started"

    /// Picks the account a participant send goes through, in this order: an
    /// iMessage account that is turned on and connected, one that is turned
    /// on, and, for a phone number only, an SMS account that is turned on and
    /// connected (Text Message Forwarding). With none, the script stops before
    /// anything reaches Messages with `ErrorNumber.noSendingAccount`. Before,
    /// it took the first iMessage account even when it was turned off, and a
    /// Mac with none reported the recipient as missing (-1728).
    static let participantAccountLines = [
        "set haveService to false",
        "try",
        "    set targetService to 1st account whose service type = iMessage and enabled is true and connection status is connected",
        "    set haveService to true",
        "end try",
        "if not haveService then",
        "    try",
        "        set targetService to 1st account whose service type = iMessage and enabled is true",
        "        set haveService to true",
        "    end try",
        "end if",
        "if not haveService and recipientId does not contain \"@\" then",
        "    try",
        "        set targetService to 1st account whose service type = SMS and enabled is true and connection status is connected",
        "        set haveService to true",
        "    end try",
        "end if",
        "if not haveService then error \"No iMessage account is turned on in Messages.\" number \(ErrorNumber.noSendingAccount)",
    ]

    static func source(_ target: TargetKind, _ payload: PayloadKind) -> String {
        let targetVariable: String
        let resolveTarget: [String]
        let targetReference: String
        switch target {
        case .participant:
            targetVariable = "recipientId"
            resolveTarget = participantAccountLines + [
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
        let disposition: DeliveryDisposition =
            fields[2] == DeliveryDisposition.notStarted.rawValue ? .notStarted : .mayHaveCompleted
        let error = classifyStderr(
            fields[4], errorNumber: Int(fields[3].trimmingCharacters(in: .whitespaces)),
            sentFileName: sentFileName, missingTargetError: missingTargetError)
        return .failure(SendFailure(error, disposition: disposition))
    }

    /// AppleScript error numbers. The message text is localized (and differs
    /// even between en_US and en_GB), so the number decides wherever it is known.
    enum ErrorNumber {
        /// errAEEventNotPermitted, errAEEventWouldRequireUserConsent
        static let permission: Set<Int> = [-1743, -1744]
        /// errAENoSuchObject ("Can't get …"), errAECoercionFail
        static let missingTarget: Set<Int> = [-1728, -1700]
        /// procNotFound, connectionInvalid
        static let unavailable: Set<Int> = [-600, -609]
        /// fnfErr
        static let fileNotFound: Set<Int> = [-43]
        /// The send script's own number for "no account can send": no
        /// iMessage account is turned on, and no SMS account fits. Positive,
        /// so it is outside the ranges Apple's errors use.
        static let noSendingAccount = 28_100
    }

    /// Classifies a failed script by its AppleScript error number: the
    /// marker's errno field, or the "(-1728)" osascript puts at the end of
    /// an execution error. English text decides only when the number is
    /// missing or not one of `ErrorNumber`'s. A bare "not permitted" is not
    /// an Automation refusal: it is how a POSIX EPERM reads.
    static func classifyStderr(
        _ rawStderr: String,
        errorNumber: Int? = nil,
        sentFileName: String,
        missingTargetError: SendError
    ) -> SendError {
        let stderr = Osascript.normalizingApostrophes(rawStderr).lowercased()

        switch errorNumber ?? trailingErrorNumber(rawStderr) {
        case ErrorNumber.noSendingAccount?:
            return .noSendingAccount
        case let number? where ErrorNumber.permission.contains(number):
            return .automationPermissionRequired
        case let number? where ErrorNumber.unavailable.contains(number):
            return .messagesAppUnavailable
        case let number? where ErrorNumber.fileNotFound.contains(number):
            return .fileNotFound(sentFileName)
        case let number? where ErrorNumber.missingTarget.contains(number):
            // "Can't get file …" is about the attachment, not the target.
            let namesTheFile = !sentFileName.isEmpty && stderr.contains(sentFileName.lowercased())
            return namesTheFile ? unclassified(rawStderr) : missingTargetError
        default:
            break
        }

        if stderr.contains("not allowed") ||
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

        return unclassified(rawStderr)
    }

    private static func unclassified(_ rawStderr: String) -> SendError {
        guard let line = Osascript.clientSafeFirstLine(rawStderr, logLabel: "osascript stderr (scrubbed for client)") else {
            return .failed("Send failed. Check the server log for details.")
        }
        return .failed(line)
    }

    /// The number osascript appends to an execution error: "… (-1728)".
    static func trailingErrorNumber(_ rawStderr: String) -> Int? {
        let line = rawStderr.split(separator: "\n", omittingEmptySubsequences: true).first ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else { return nil }
        let inner = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        guard inner.first == "-", inner.count > 1, inner.dropFirst().allSatisfy(\.isASCII), inner.dropFirst().allSatisfy(\.isNumber) else {
            return nil
        }
        return Int(inner)
    }
}
