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
        try resolveChat(raw, db: db).id
    }

    /// `resolve`, with the chat row it found.
    static func resolveChat(_ raw: String, db: Database) throws -> ResolvedChat {
        let select = "SELECT c.ROWID, c.guid, c.display_name FROM chat c"
        let map = { (row: SQLiteRow) in ResolvedChat(id: row.int(0), guid: row.string(1), displayName: row.string(2)) }
        let rows: [ResolvedChat]
        if let id = parseRowId(raw) {
            rows = try db.query("\(select) WHERE c.ROWID = ?", params: [id], map: map)
        } else {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { throw ToolFailure.chatNotFound(raw) }
            rows = try db.query(
                """
                \(select) WHERE c.guid LIKE ? ESCAPE '\\'
                ORDER BY \(SQLFragments.newestChatFirst())
                LIMIT 1
                """,
                params: ["%\(QueryBuilder.escapeLike(trimmed))%"],
                map: map
            )
        }
        guard let chat = rows.first else { throw ToolFailure.chatNotFound(raw) }
        return chat
    }
}

struct ResolvedChat {
    let id: Int64
    let guid: String?
    let displayName: String?
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
