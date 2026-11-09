import Foundation

struct RecipientCandidate: Encodable {
    let name: String
    let handle: String
    let lastContact: String

    enum CodingKeys: String, CodingKey {
        case name, handle
        case lastContact = "last_contact"
    }
}

enum SendStatus: String, Encodable, Sendable {
    case sent
    case confirmed
    case uncertain
    case mismatch
    case failedDelivery = "failed_delivery"
    case pendingConfirmation = "pending_confirmation"
    case partialFailure = "partial_failure"
    case failed
    case ambiguous

    var isError: Bool {
        switch self {
        case .failed, .ambiguous, .failedDelivery, .partialFailure, .mismatch: return true
        case .sent, .confirmed, .uncertain, .pendingConfirmation: return false
        }
    }

    var dispatched: Bool { self != .failed && self != .ambiguous }
}

/// What chat.db showed for the text of a send whose files are still
/// pending, so a pending attachment does not hide the text's result.
enum TextVerification: Equatable {
    case confirmed(guid: String)
    case notFound
}

struct SendResponse: Encodable, Sendable {
    let status: SendStatus
    let timestamp: String?
    let chat: ChatReference?
    let deliveredTo: [String]?
    let chatId: String?
    private(set) var message: String?
    let error: String?
    let candidates: [RecipientCandidate]?
    let verifiedMessageGuid: String?
    let verifiedAt: String?
    let intendedChat: ChatReference?
    let actualChatId: String?
    /// The text's own verification status, set when `status` describes a
    /// file still in transfer.
    let textStatus: SendStatus?
    let disposition: DeliveryDisposition
    let retrySafe: Bool

    enum CodingKeys: String, CodingKey {
        case status
        case timestamp
        case chat
        case deliveredTo = "delivered_to"
        case chatId = "chat_id"
        case message
        case error
        case candidates
        case verifiedMessageGuid = "verified_message_guid"
        case verifiedAt = "verified_at"
        case intendedChat = "intended_chat"
        case actualChatId = "actual_chat_id"
        case textStatus = "text_status"
        case disposition
        case retrySafe = "retry_safe"
    }

    private init(
        _ status: SendStatus,
        disposition: DeliveryDisposition,
        chat: ChatReference? = nil,
        deliveredTo: [String]? = nil,
        message: String? = nil,
        error: String? = nil,
        candidates: [RecipientCandidate]? = nil,
        verifiedMessageGuid: String? = nil,
        intendedChat: ChatReference? = nil,
        actualChatId: String? = nil,
        textStatus: SendStatus? = nil,
        retrySafe: Bool? = nil
    ) {
        let now = TimeUtils.formatISO(Date())
        self.status = status
        self.timestamp = status.dispatched ? now : nil
        self.chat = chat
        self.deliveredTo = deliveredTo
        self.chatId = chat?.id
        self.message = message
        self.error = error
        self.candidates = candidates
        self.verifiedMessageGuid = verifiedMessageGuid
        self.verifiedAt = verifiedMessageGuid == nil ? nil : now
        self.intendedChat = intendedChat
        self.actualChatId = actualChatId
        self.textStatus = textStatus
        self.disposition = disposition
        if let retrySafe {
            self.retrySafe = retrySafe
            return
        }
        switch status {
        case .failedDelivery:
            self.retrySafe = true
        case .partialFailure:
            self.retrySafe = false
        default:
            self.retrySafe = disposition.retrySafe
        }
    }

    func adding(note: String) -> SendResponse {
        var copy = self
        copy.message = Self.sentences(message, note)
        return copy
    }

    /// Joins the sentences of a message, skipping the missing ones.
    private static func sentences(_ parts: String?...) -> String? {
        let present = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: " ")
    }

    private static func followUp(_ chat: ChatReference?) -> String {
        "Use get_messages on \(chat?.id ?? "the intended chat") to confirm."
    }

    /// Said after a send that Messages did not acknowledge, where chat.db did
    /// not show the message either.
    private static let mayHaveBeenSent =
        "The message may still have been sent, so do not resend it blindly."

    static func sent(deliveredTo: [String], chat: ChatReference?) -> SendResponse {
        SendResponse(.sent, disposition: .completed, chat: chat, deliveredTo: deliveredTo)
    }

    /// `transportError` is set when Messages reported an error or timed out
    /// after the send began, and chat.db shows the message anyway.
    static func confirmed(
        guid: String, deliveredTo: [String], chat: ChatReference?,
        transportError: String? = nil
    ) -> SendResponse {
        let message = transportError.map {
            "Messages.app did not acknowledge the send (\($0)), but chat.db shows the message, so it was sent. Do not resend it."
        }
        return SendResponse(
            .confirmed, disposition: .completed, chat: chat, deliveredTo: deliveredTo,
            message: message, verifiedMessageGuid: guid
        )
    }

    /// With `transportError`, Messages failed or timed out after the send
    /// began and chat.db has no row yet, so the message may have gone out:
    /// disposition is `may_have_completed`, never a failure that invites a retry.
    static func uncertain(
        deliveredTo: [String], chat: ChatReference?,
        transportError: String? = nil
    ) -> SendResponse {
        guard let transportError else {
            return SendResponse(
                .uncertain, disposition: .completed, chat: chat, deliveredTo: deliveredTo,
                message: "Messages.app accepted the send, but it did not appear in chat.db within the polling window. The message was probably sent. \(followUp(chat))"
            )
        }
        return SendResponse(
            .uncertain, disposition: .mayHaveCompleted, chat: chat, deliveredTo: deliveredTo,
            message: "Messages.app did not acknowledge the send, and the message did not appear in chat.db within the verification window. \(mayHaveBeenSent) \(followUp(chat)) Resend only if it is still missing.",
            error: transportError
        )
    }

    static func mismatch(
        intendedChat: ChatReference?, actualChatId: Int64, deliveredTo: [String],
        note: String? = nil
    ) -> SendResponse {
        SendResponse(
            .mismatch, disposition: .completed, deliveredTo: deliveredTo,
            message: sentences(
                "The message appeared in a different chat than the intended one. This is a routing mismatch. Do not treat it as confirmed.",
                note
            ),
            intendedChat: intendedChat,
            actualChatId: ChatIdentifier.format(actualChatId)
        )
    }

    /// `otherPayloadsDispatched`: files went out with the text, so retrying
    /// the whole call would send them again.
    static func failedDelivery(
        guid: String, errorCode: Int, deliveredTo: [String], chat: ChatReference?,
        otherPayloadsDispatched: Bool = false, note: String? = nil
    ) -> SendResponse {
        let resend = otherPayloadsDispatched
            ? "The files in this call were dispatched separately. To retry, resend only the text."
            : "Check that the destination can receive iMessages, and consider resending."
        return SendResponse(
            .failedDelivery, disposition: .completed, chat: chat, deliveredTo: deliveredTo,
            message: sentences(
                "Messages.app accepted the send, but chat.db recorded a delivery failure (error \(errorCode)). The message was NOT delivered. Do not tell the user it was sent.",
                resend,
                note
            ),
            verifiedMessageGuid: guid,
            retrySafe: !otherPayloadsDispatched
        )
    }

    /// A file transfer is still pending. `text` is the verification of a text
    /// sent after the files, which this result reports beside the file's state.
    static func pending(
        _ message: String, deliveredTo: [String], chat: ChatReference?,
        text: TextVerification? = nil, textTransportError: String? = nil
    ) -> SendResponse {
        switch text {
        case nil:
            return SendResponse(.pendingConfirmation, disposition: .mayHaveCompleted, chat: chat, deliveredTo: deliveredTo, message: message)
        case .confirmed(let guid)?:
            return SendResponse(
                .pendingConfirmation, disposition: .mayHaveCompleted, chat: chat, deliveredTo: deliveredTo,
                message: sentences(message, "The text message was confirmed in chat.db, so do not resend it."),
                verifiedMessageGuid: guid,
                textStatus: .confirmed
            )
        case .notFound?:
            let textNote = textTransportError == nil
                ? "The text message did not appear in chat.db within the polling window. It was probably sent. \(followUp(chat))"
                : "Messages.app did not acknowledge the text message, and it did not appear in chat.db within the verification window. \(mayHaveBeenSent) \(followUp(chat))"
            return SendResponse(
                .pendingConfirmation, disposition: .mayHaveCompleted, chat: chat, deliveredTo: deliveredTo,
                message: sentences(message, textNote),
                error: textTransportError,
                textStatus: .uncertain
            )
        }
    }

    static func partialFailure(
        sentDescriptions: [String], failedDescription: String, error: String,
        deliveredTo: [String], chat: ChatReference?,
        disposition: DeliveryDisposition
    ) -> SendResponse {
        let retry = disposition == .mayHaveCompleted
            ? "\(failedDescription.prefix(1).uppercased() + failedDescription.dropFirst()) may have been sent too. Check with get_messages before retrying it."
            : "Retry only the failed one."
        return SendResponse(
            .partialFailure, disposition: disposition, chat: chat, deliveredTo: deliveredTo,
            message: "PARTIAL SEND: the tool dispatched \(sentDescriptions.joined(separator: ", ")) to Messages.app before \(failedDescription) failed, and did not verify them. Do NOT resend the payloads that were already dispatched. \(retry)",
            error: error
        )
    }

    /// A failure after the send began (`may_have_completed`) says so in
    /// `message`, so the error text alone never reads as an invitation to retry.
    static func error(_ message: String, disposition: DeliveryDisposition = .notStarted) -> SendResponse {
        let caution = disposition == .mayHaveCompleted
            ? "The send began before it failed. \(mayHaveBeenSent) Check the chat with get_messages first."
            : nil
        return SendResponse(.failed, disposition: disposition, message: caution, error: message)
    }

    static func ambiguous(candidates: [RecipientCandidate]) -> SendResponse {
        SendResponse(
            .ambiguous, disposition: .notStarted,
            message: "More than one number or email in Contacts matches. Nothing was sent. Pass one candidate's handle as to, or a chat_id.",
            candidates: candidates
        )
    }
}
