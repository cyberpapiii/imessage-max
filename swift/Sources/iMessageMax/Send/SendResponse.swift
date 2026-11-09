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
            self.retrySafe = true
        case .partialFailure:
            self.retrySafe = false
        default:
            self.retrySafe = disposition.retrySafe
        }
    }

    static func sent(deliveredTo: [String], chat: ChatReference?) -> SendResponse {
        SendResponse(.sent, disposition: .completed, chat: chat, deliveredTo: deliveredTo)
    }

    static func confirmed(guid: String, deliveredTo: [String], chat: ChatReference?) -> SendResponse {
        SendResponse(.confirmed, disposition: .completed, chat: chat, deliveredTo: deliveredTo, verifiedMessageGuid: guid)
    }

    static func uncertain(deliveredTo: [String], chat: ChatReference?) -> SendResponse {
        let followUp = "Use get_messages on \(chat?.id ?? "the intended chat") to confirm."
        return SendResponse(
            .uncertain, disposition: .completed, chat: chat, deliveredTo: deliveredTo,
            message: "Messages.app accepted the send, but it did not appear in chat.db within the polling window. The message was probably sent. \(followUp)"
        )
    }

    static func mismatch(intendedChat: ChatReference?, actualChatId: Int64, deliveredTo: [String]) -> SendResponse {
        SendResponse(
            .mismatch, disposition: .completed, deliveredTo: deliveredTo,
            message: "The message appeared in a different chat than the intended one. This is a routing mismatch. Do not treat it as confirmed.",
            intendedChat: intendedChat,
            actualChatId: ChatIdentifier.format(actualChatId)
        )
    }

    static func failedDelivery(guid: String, errorCode: Int, deliveredTo: [String], chat: ChatReference?) -> SendResponse {
        SendResponse(
            .failedDelivery, disposition: .completed, chat: chat, deliveredTo: deliveredTo,
            message: "Messages.app accepted the send, but chat.db recorded a delivery failure (error \(errorCode)). The message was NOT delivered. Do not tell the user it was sent. Check that the destination can receive iMessages, and consider resending.",
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
            message: "PARTIAL SEND: the tool dispatched \(sentDescriptions.joined(separator: ", ")) to Messages.app before \(failedDescription) failed, and did not verify them. Do NOT resend the payloads that were already dispatched. Retry only the failed one.",
            error: error
        )
    }

    static func error(_ message: String, disposition: DeliveryDisposition = .notStarted) -> SendResponse {
        SendResponse(.failed, disposition: disposition, error: message)
    }

    static func ambiguous(candidates: [RecipientCandidate], reason: AmbiguityReason = .multipleMatches) -> SendResponse {
        let message: String
        switch reason {
        case .multipleMatches:
            message = "Multiple contacts match. Please specify using a phone number, email, or chat_id."
        case .notInMessages:
            message = "The matching contact's number or email has no conversation in Messages, so nothing proves it reaches the person you meant. Nothing was sent. Check the number with the user. To message someone new, start the conversation in Messages first."
        }
        return SendResponse(.ambiguous, disposition: .notStarted, message: message, candidates: candidates)
    }
}
