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

    static func filterUnanswered<Row>(
        db: Database,
        rows: [Row],
        hours: Int,
        limit: Int,
        text: (Row) -> String?,
        date: (Row) -> Int64?,
        chatId: (Row) -> Int64
    ) throws -> [Row] {
        let windowNs = Int64(hours) * 3_600_000_000_000
        let questions = rows.compactMap { row -> (row: Row, chatId: Int64, date: Int64)? in
            guard looksLikeQuestion(text(row)), let messageDate = date(row) else { return nil }
            return (row, chatId(row), messageDate)
        }
        let chunkSize = max(limit, 32)

        var filtered: [Row] = []
        var start = 0
        while start < questions.count && filtered.count < limit {
            let chunk = questions[start..<min(start + chunkSize, questions.count)]
            let sql = """
                WITH q(i, chat_id, d) AS (VALUES \(Array(repeating: "(?, ?, ?)", count: chunk.count).joined(separator: ", ")))
                SELECT q.i FROM q
                WHERE EXISTS (
                  SELECT 1 FROM chat_message_join cmj
                  JOIN message m ON m.ROWID = cmj.message_id
                  WHERE cmj.chat_id = q.chat_id
                    AND m.date > q.d
                    AND m.date <= q.d + ?
                    AND m.is_from_me = 0
                    AND \(SQLFragments.conversational())
                )
                """
            var params: [Any] = []
            for (offset, question) in chunk.enumerated() {
                params += [offset, question.chatId, question.date]
            }
            params.append(windowNs)
            let answered = Set(try db.query(sql, params: params) { Int($0.int(0)) })

            for (offset, question) in chunk.enumerated() where !answered.contains(offset) {
                filtered.append(question.row)
                if filtered.count >= limit { break }
            }
            start += chunkSize
        }
        return filtered
    }
}
