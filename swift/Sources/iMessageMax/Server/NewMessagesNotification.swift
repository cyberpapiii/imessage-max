import MCP

struct NewMessagesNotification: MCP.Notification {
    static let name = "notifications/imessage/new_messages"
    struct Parameters: Hashable, Codable, Sendable {
        let max_rowid: Int64
    }
}
