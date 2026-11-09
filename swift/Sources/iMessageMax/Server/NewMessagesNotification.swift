import MCP

struct NewMessagesNotification: MCP.Notification {
    static let name = "notifications/imessage/new_messages"
    struct Parameters: Hashable, Codable, Sendable {
        let max_rowid: Int64
        /// true when every new row is late-synced history; omitted otherwise.
        var late: Bool? = nil
    }
}
