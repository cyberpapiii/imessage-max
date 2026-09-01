import Foundation

enum UnansweredHeuristics {
    static func looksLikeQuestion(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }

        if text.contains("?") { return true }

        let textLower = text.lowercased().trimmingCharacters(in: .whitespaces)
        let questionEndings = [
            "what do you think",
            "let me know",
            "thoughts",
            "can you",
            "could you",
            "would you",
            "will you",
            "please",
            "lmk"
        ]

        for ending in questionEndings {
            if textLower.hasSuffix(ending) { return true }
        }

        return false
    }

    static func hasReplyWithinWindow(
        db: Database,
        chatId: Int64,
        messageDate: Int64,
        hours: Int
    ) throws -> Bool {
        // Defensive clamp: one year of hours times 3.6e12 stays far inside Int64.
        let boundedHours = Int64(max(1, min(hours, 24 * 365)))
        let windowNs = boundedHours * 3_600_000_000_000

        let rows = try db.query("""
            SELECT 1 FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            WHERE cmj.chat_id = ?
            AND m.date > ?
            AND m.date <= ?
            AND m.is_from_me = 0
            AND m.associated_message_type = 0
            LIMIT 1
            """,
            params: [chatId, messageDate, messageDate + windowNs]
        ) { _ in true }

        return !rows.isEmpty
    }

    static func filterUnanswered<Row>(
        db: Database,
        rows: [Row],
        hours: Int,
        limit: Int,
        text: (Row) -> String?,
        date: (Row) -> Int64?,
        chatId: (Row) -> Int64
    ) throws -> [Row] {
        var filtered: [Row] = []

        for row in rows {
            guard looksLikeQuestion(text(row)) else { continue }
            guard let messageDate = date(row) else { continue }

            let hasReply = try hasReplyWithinWindow(
                db: db,
                chatId: chatId(row),
                messageDate: messageDate,
                hours: hours
            )
            if !hasReply {
                filtered.append(row)
                if filtered.count >= limit { break }
            }
        }

        return filtered
    }
}
