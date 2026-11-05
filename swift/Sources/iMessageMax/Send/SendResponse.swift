import Foundation

/// Candidate for disambiguation when multiple contacts match
struct RecipientCandidate: Encodable {
    let name: String
    let handle: String
    let lastContact: String

    enum CodingKeys: String, CodingKey {
        case name, handle
        case lastContact = "last_contact"
    }
}

/// The send tool's `status` field. The tool description documents this
/// vocabulary to clients, so the raw values are a contract.
enum SendStatus: String, Encodable, Sendable {
    /// Transport accepted; verification could not run (DB unreadable) or
    /// does not apply (file-only send).
    case sent
    /// DB re-read found the outbound row in the intended chat with error = 0.
    case confirmed
    /// Transport accepted but no row appeared within the polling window.
    case uncertain
    /// Row found in a different chat than intended.
    case mismatch
    /// Row found in the intended chat with error ≠ 0.
    case failedDelivery = "failed_delivery"
    case pendingConfirmation = "pending_confirmation"
    case partialFailure = "partial_failure"
    case failed
    case ambiguous

    /// Reported to the client as a tool error.
    var isError: Bool {
        switch self {
        case .failed, .ambiguous, .failedDelivery, .partialFailure, .mismatch: return true
        case .sent, .confirmed, .uncertain, .pendingConfirmation: return false
        }
    }

    /// Something was handed to Messages.app, so the response is timestamped.
    var dispatched: Bool { self != .failed && self != .ambiguous }
}

struct SendResponse: Encodable, Sendable {
    let status: SendStatus
    let timestamp: String?
    let chat: ChatReference?
    let deliveredTo: [String]?
    let chatId: String?
    let message: String?
    let error: String?
    let candidates: [RecipientCandidate]?
    let verifiedMessageGuid: String?
    let verifiedAt: String?
    let intendedChat: ChatReference?
    let actualChatId: String?
    let disposition: DeliveryDisposition
    /// True only when a retry cannot duplicate a message.
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
        actualChatId: String? = nil
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
        self.disposition = disposition
        switch status {
        case .failedDelivery:
            // chat.db recorded the row as failed, so a resend cannot duplicate it.
            self.retrySafe = true
        case .partialFailure:
            // Earlier payloads already went out; a blind retry would resend them.
            self.retrySafe = false
        default:
            self.retrySafe = disposition.retrySafe
        }
    }

    // Returned only when verification cannot run (DB unreadable).
    static func sent(deliveredTo: [String], chat: ChatReference?) -> SendResponse {
        SendResponse(.sent, disposition: .completed, chat: chat, deliveredTo: deliveredTo)
    }

    static func confirmed(guid: String, deliveredTo: [String], chat: ChatReference?) -> SendResponse {
        SendResponse(.confirmed, disposition: .completed, chat: chat, deliveredTo: deliveredTo, verifiedMessageGuid: guid)
    }

    static func uncertain(deliveredTo: [String], chat: ChatReference?) -> SendResponse {
        let id = chat?.id
        let name = chat?.name ?? id ?? "the intended chat"
        let followUp = id.map { "Use get_messages on \($0) to confirm." }
            ?? "Use get_messages on \(name) to confirm."
        return SendResponse(
            .uncertain, disposition: .completed, chat: chat, deliveredTo: deliveredTo,
            message: "Send accepted by Messages.app but could not be verified in chat.db within the polling window. The message was probably sent. \(followUp)"
        )
    }

    static func mismatch(intendedChat: ChatReference?, actualChatId: Int64, deliveredTo: [String]) -> SendResponse {
        SendResponse(
            .mismatch, disposition: .completed, deliveredTo: deliveredTo,
            message: "Message was found in a different chat than intended. This is a routing mismatch. Do not treat as confirmed.",
            intendedChat: intendedChat,
            actualChatId: ChatIdentifier.format(actualChatId)
        )
    }

    static func failedDelivery(guid: String, errorCode: Int, deliveredTo: [String], chat: ChatReference?) -> SendResponse {
        SendResponse(
            .failedDelivery, disposition: .completed, chat: chat, deliveredTo: deliveredTo,
            message: "Messages.app accepted the send but chat.db recorded a delivery failure (error \(errorCode)). The message was NOT delivered. Do not tell the user it was sent; check the destination can receive iMessages and consider resending.",
            verifiedMessageGuid: guid
        )
    }

    static func pending(_ message: String, deliveredTo: [String], chat: ChatReference?) -> SendResponse {
        SendResponse(.pendingConfirmation, disposition: .mayHaveCompleted, chat: chat, deliveredTo: deliveredTo, message: message)
    }

    static func partialFailure(
        sentDescriptions: [String], failedDescription: String, error: String,
        deliveredTo: [String], chat: ChatReference?,
        disposition: DeliveryDisposition
    ) -> SendResponse {
        SendResponse(
            .partialFailure, disposition: disposition, chat: chat, deliveredTo: deliveredTo,
            message: "PARTIAL SEND: \(sentDescriptions.joined(separator: ", ")) already dispatched to Messages.app (not verified) before \(failedDescription) failed. Do NOT resend the already-dispatched payload(s); retry only the failed one.",
            error: error
        )
    }

    static func error(_ message: String, disposition: DeliveryDisposition = .notStarted) -> SendResponse {
        SendResponse(.failed, disposition: disposition, error: message)
    }

    static func ambiguous(candidates: [RecipientCandidate]) -> SendResponse {
        SendResponse(
            .ambiguous, disposition: .notStarted,
            message: "Multiple contacts match. Please specify using a phone number, email, or chat_id.",
            candidates: candidates
        )
    }
}
