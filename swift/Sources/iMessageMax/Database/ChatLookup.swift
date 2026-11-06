import Foundation

/// The chat a chat id argument names: the chat with that row id (`123`,
/// `chat123`), else the most recently active chat whose GUID contains the
/// text. A text that names no chat throws `NotFound`, which the tool layer
/// answers as `chat_not_found`.
enum ChatLookup {
    struct NotFound: Error {
        /// The argument as the caller passed it.
        let chatId: String
    }

    static func find(_ raw: String, db: Database) throws -> ResolvedChat {
        let select = "SELECT c.ROWID, c.guid, c.display_name FROM chat c"
        let map = { (row: SQLiteRow) in ResolvedChat(id: row.int(0), guid: row.string(1), displayName: row.string(2)) }
        let rows: [ResolvedChat]
        if let id = ChatIdentifier.parseRowId(raw) {
            rows = try db.query("\(select) WHERE c.ROWID = ?", params: [id], map: map)
        } else {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { throw NotFound(chatId: raw) }
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
        guard let chat = rows.first else { throw NotFound(chatId: raw) }
        return chat
    }
}

struct ResolvedChat {
    let id: Int64
    let guid: String?
    let displayName: String?
}
