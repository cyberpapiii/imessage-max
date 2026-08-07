import Foundation

/// Keyset cursor for message timelines ordered by `(date, messageId)`.
struct TimelineCursor: Equatable {
    let date: Int64
    let messageId: Int64

    static func encode(date: Int64?, messageId: Int64) -> String? {
        guard let date else { return nil }
        return "\(date):\(messageId)"
    }

    static func decode(_ raw: String) -> TimelineCursor? {
        let parts = raw.split(separator: ":")
        guard parts.count == 2,
              let date = Int64(parts[0]),
              let messageId = Int64(parts[1]) else {
            return nil
        }
        return TimelineCursor(date: date, messageId: messageId)
    }

    /// SQL fragment for descending timelines (`ORDER BY date DESC, id DESC`).
    var olderThanSQL: String {
        "(m.date < ? OR (m.date = ? AND m.ROWID < ?))"
    }

    var olderThanParams: [Any] {
        [date, date, messageId]
    }

    /// SQL fragment for ascending timelines (`ORDER BY date ASC, id ASC`).
    var newerThanSQL: String {
        "(m.date > ? OR (m.date = ? AND m.ROWID > ?))"
    }

    var newerThanParams: [Any] {
        [date, date, messageId]
    }
}

/// Keyset cursor for chat lists.
///
/// - recent: `primary:chatId` where primary is last_message_date
/// - most_active: `primary:secondary:chatId` (message_count, last_message_date)
/// - alphabetical: `n:name:chatId` (name may contain colons; split from the ends)
struct ChatListCursor: Equatable {
    let primary: Int64
    let secondary: Int64?
    let chatId: Int64

    static func encode(primary: Int64?, secondary: Int64?, chatId: Int64) -> String? {
        guard let primary else { return nil }
        if let secondary {
            return "\(primary):\(secondary):\(chatId)"
        }
        return "\(primary):\(chatId)"
    }

    static func decode(_ raw: String) -> ChatListCursor? {
        if raw.hasPrefix("n:") { return nil }
        let parts = raw.split(separator: ":")
        if parts.count == 2,
           let primary = Int64(parts[0]),
           let chatId = Int64(parts[1]) {
            return ChatListCursor(primary: primary, secondary: nil, chatId: chatId)
        }
        if parts.count == 3,
           let primary = Int64(parts[0]),
           let secondary = Int64(parts[1]),
           let chatId = Int64(parts[2]) {
            return ChatListCursor(primary: primary, secondary: secondary, chatId: chatId)
        }
        return nil
    }

    static func encodeName(name: String, chatId: Int64) -> String {
        "n:\(name):\(chatId)"
    }

    static func decodeName(_ raw: String) -> (name: String, chatId: Int64)? {
        guard raw.hasPrefix("n:") else { return nil }
        let body = String(raw.dropFirst(2))
        guard let colon = body.lastIndex(of: ":") else { return nil }
        let name = String(body[..<colon])
        let idPart = String(body[body.index(after: colon)...])
        guard let chatId = Int64(idPart) else { return nil }
        return (name, chatId)
    }
}
