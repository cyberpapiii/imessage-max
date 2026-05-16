import Foundation

struct ChatSummary: Codable {
    let id: String
    let name: String
    let group: Bool?
    let participantCount: Int
    let participantsPreview: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case group
        case participantCount = "participant_count"
        case participantsPreview = "participants_preview"
    }
}

struct ChatReference: Codable {
    let id: String
    let name: String
}

struct LastMessageSummary: Codable {
    let from: String
    let text: String
    let ago: String?
    let ts: String?
}

struct ChatParticipant: Codable {
    let name: String
    let handle: String
}

struct MatchInfo: Codable {
    let type: String
}

struct SharedAttachmentSummary: Codable {
    let id: String
    let type: String
    let name: String?
    let available: Bool
    let sizeHuman: String?

    enum CodingKeys: String, CodingKey {
        case id, type, name, available
        case sizeHuman = "size_human"
    }
}

struct SharedMessageItem: Codable {
    let messageId: String
    let chat: ChatReference
    let from: String
    let messagePreview: String?
    let sharedSummary: String
    let ts: String?
    let ago: String?
    let attachments: [SharedAttachmentSummary]

    enum CodingKeys: String, CodingKey {
        case chat, from, ts, ago, attachments
        case messageId = "message_id"
        case messagePreview = "message_preview"
        case sharedSummary = "shared_summary"
    }
}

struct ChatDetailsIdentity: Codable {
    let guid: String?
    let explicitName: String?
    let isNamed: Bool
    let aliases: [String]

    enum CodingKeys: String, CodingKey {
        case guid
        case explicitName = "explicit_name"
        case isNamed = "is_named"
        case aliases
    }
}

struct ChatDetailsState: Codable {
    let unreadCount: Int
    let awaitingReply: Bool?
    let firstActivity: String?
    let lastActivity: String?

    enum CodingKeys: String, CodingKey {
        case unreadCount = "unread_count"
        case awaitingReply = "awaiting_reply"
        case firstActivity = "first_activity"
        case lastActivity = "last_activity"
    }
}
