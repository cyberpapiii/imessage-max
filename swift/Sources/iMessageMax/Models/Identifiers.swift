import Foundation

/// The ids tools hand out and accept back. Each format pairs with its parse.
enum ChatIdentifier {
    static func format(_ rowId: some BinaryInteger) -> String { "chat\(rowId)" }

    /// Accepts unsigned decimal `123` and `chat123`. Returns nil for anything else.
    static func parseRowId(_ raw: String) -> Int64? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.hasPrefix("chat") ? trimmed.dropFirst(4) : Substring(trimmed)
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        return Int64(digits)
    }

    /// The chat a tool's chat id argument names: the chat with that row id
    /// (`123`, `chat123`), else the most recently active chat whose GUID
    /// contains the text. Every tool that takes a chat id resolves it here,
    /// and one that names no chat is `chat_not_found`.
    static func resolve(_ raw: String, db: Database) throws -> Int64 {
        if let id = parseRowId(raw) {
            let exists = try db.query("SELECT 1 FROM chat WHERE ROWID = ?", params: [id]) { _ in true }
            guard !exists.isEmpty else { throw ToolFailure.chatNotFound(raw) }
            return id
        }

        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ToolFailure.chatNotFound(raw) }

        let rows: [Int64] = try db.query(
            """
            SELECT c.ROWID FROM chat c WHERE c.guid LIKE ? ESCAPE '\\'
            ORDER BY \(SQLFragments.newestChatFirst())
            LIMIT 1
            """,
            params: ["%\(QueryBuilder.escapeLike(trimmed))%"]
        ) { row in
            row.int(0)
        }

        guard let id = rows.first else { throw ToolFailure.chatNotFound(raw) }
        return id
    }
}

enum MessageIdentifier {
    static func format(_ rowId: some BinaryInteger) -> String { "msg_\(rowId)" }

    /// Accepts `msg_123`, `msg123` and `123`.
    static func parse(_ raw: String) -> Int64? {
        if raw.hasPrefix("msg_") { return Int64(raw.dropFirst(4)) }
        if raw.hasPrefix("msg") { return Int64(raw.dropFirst(3)) }
        return Int64(raw)
    }
}

enum AttachmentIdentifier {
    static func format(_ rowId: some BinaryInteger) -> String { "att\(rowId)" }

    /// Accepts `att123` and `123`.
    static func parse(_ raw: String) -> Int? {
        Int(raw.hasPrefix("att") ? raw.dropFirst(3) : Substring(raw))
    }
}
