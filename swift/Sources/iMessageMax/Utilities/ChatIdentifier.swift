import Foundation

enum ChatIdentifier {
    /// Accepts "123" and "chat123". Returns nil for anything else.
    static func parseRowId(_ raw: String) -> Int64? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let id = Int64(trimmed) { return id }
        if trimmed.hasPrefix("chat"), let id = Int64(trimmed.dropFirst(4)) { return id }
        return nil
    }

    /// parseRowId, then the GUID-substring fallback that get_messages historically allowed.
    static func resolve(_ raw: String, db: Database) throws -> Int64? {
        if let id = parseRowId(raw) { return id }

        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let rows: [Int64] = try db.query(
            "SELECT ROWID FROM chat WHERE guid LIKE ? ESCAPE '\\'",
            params: ["%\(QueryBuilder.escapeLike(trimmed))%"]
        ) { row in
            row.int(0)
        }

        return rows.first
    }
}
