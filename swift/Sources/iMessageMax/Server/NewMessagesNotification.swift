import MCP

/// Server-initiated, one per watcher poll that saw growth. Carries the new
/// MAX(ROWID) so a client can call get_messages_since with its stored cursor.
struct NewMessagesNotification: MCP.Notification {
    static let name = "notifications/imessage/new_messages"
    struct Parameters: Hashable, Codable, Sendable {
        let max_rowid: Int64
    }
}
