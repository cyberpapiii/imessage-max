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

    /// parseRowId, then the GUID-substring fallback get_messages allows.
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
