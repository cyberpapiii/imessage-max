import Foundation

/// The messages just before and after anchor messages in their chat,
/// for get_context and search's include_context.
enum MessageWindow {
    struct Anchor: Hashable {
        let chatId: Int64
        let date: Int64
    }

    struct Context {
        /// Oldest first.
        var before: [MessageRecord] = []
        /// Oldest first.
        var after: [MessageRecord] = []
    }

    /// One statement per chat and 100 anchors: a UNION ALL of per-anchor
    /// `LIMIT` windows, so the cost does not grow with the anchor count.
    static func around(
        _ anchors: [Anchor],
        before: Int,
        after: Int,
        db: Database
    ) throws -> [Anchor: Context] {
        guard before > 0 || after > 0 else {
            return Dictionary(anchors.map { ($0, Context()) }, uniquingKeysWith: { first, _ in first })
        }

        var datesByChat: [Int64: [Int64]] = [:]
        for anchor in anchors where datesByChat[anchor.chatId]?.contains(anchor.date) != true {
            datesByChat[anchor.chatId, default: []].append(anchor.date)
        }

        let schema = try db.schema()
        var result: [Anchor: Context] = [:]
        for (chatId, dates) in datesByChat {
            var start = 0
            while start < dates.count {
                let chunk = Array(dates[start..<min(start + 100, dates.count)])
                let (sql, params) = windowSQL(chatId: chatId, dates: chunk, before: before, after: after, schema: schema)
                let rows = try db.query(sql, params: params) { row in
                    (
                        message: MessageRecord(row),
                        anchorDate: row.int(MessageRecord.columnCount),
                        isBefore: row.int(MessageRecord.columnCount + 1) != 0
                    )
                }
                for row in rows {
                    let anchor = Anchor(chatId: chatId, date: row.anchorDate)
                    if row.isBefore {
                        result[anchor, default: Context()].before.insert(row.message, at: 0)
                    } else {
                        result[anchor, default: Context()].after.append(row.message)
                    }
                }
                start += chunk.count
            }
            for date in dates where result[Anchor(chatId: chatId, date: date)] == nil {
                result[Anchor(chatId: chatId, date: date)] = Context()
            }
        }
        return result
    }

    /// Three bindings per side per anchor; 100 anchors stay far below
    /// SQLite's default variable limit of 32766.
    private static func windowSQL(
        chatId: Int64,
        dates: [Int64],
        before: Int,
        after: Int,
        schema: SchemaCapabilities
    ) -> (String, [Any]) {
        let columns = MessageRecord.selectList(schema)
        let from = """
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            \(MessageRecord.handleJoinsSQL)
            """
        var parts: [String] = []
        var params: [Any] = []
        for date in dates {
            if before > 0 {
                parts.append("""
                    SELECT * FROM (
                      SELECT \(columns), ? AS anchor_date, 1 AS is_before
                      \(from)
                      WHERE cmj.chat_id = ? AND m.date < ? AND \(SQLFragments.notReaction())
                      ORDER BY m.date DESC LIMIT \(before)
                    )
                    """)
                params.append(contentsOf: [date, chatId, date])
            }
            if after > 0 {
                parts.append("""
                    SELECT * FROM (
                      SELECT \(columns), ? AS anchor_date, 0 AS is_before
                      \(from)
                      WHERE cmj.chat_id = ? AND m.date > ? AND \(SQLFragments.notReaction())
                      ORDER BY m.date ASC LIMIT \(after)
                    )
                    """)
                params.append(contentsOf: [date, chatId, date])
            }
        }
        return (parts.joined(separator: "\nUNION ALL\n"), params)
    }
}
