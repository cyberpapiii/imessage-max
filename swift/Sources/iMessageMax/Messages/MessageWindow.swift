import Foundation

/// The messages just before and after anchor messages in their chat,
/// for get_context and search's include_context.
enum MessageWindow {
    /// Windows are cut on `(date, ROWID)` like every other timeline, so a
    /// message sharing the anchor's timestamp still lands on one side.
    struct Anchor: Hashable {
        let chatId: Int64
        let date: Int64
        let messageId: Int64

        init(chatId: Int64, message: MessageRecord) {
            self.chatId = chatId
            date = message.date ?? 0
            messageId = message.id
        }

        fileprivate init(chatId: Int64, date: Int64, messageId: Int64) {
            self.chatId = chatId
            self.date = date
            self.messageId = messageId
        }

        fileprivate var cursor: TimelineCursor { TimelineCursor(date: date, messageId: messageId) }
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

        var anchorsByChat: [Int64: [Anchor]] = [:]
        for anchor in Set(anchors) {
            anchorsByChat[anchor.chatId, default: []].append(anchor)
        }

        let schema = try db.schema()
        var result: [Anchor: Context] = [:]
        for (chatId, chatAnchors) in anchorsByChat {
            var start = 0
            while start < chatAnchors.count {
                let chunk = Array(chatAnchors[start..<min(start + 100, chatAnchors.count)])
                let (sql, params) = windowSQL(chatId: chatId, anchors: chunk, before: before, after: after, schema: schema)
                let rows = try db.query(sql, params: params) { row in
                    (
                        message: MessageRecord(row),
                        anchorDate: row.int(MessageRecord.columnCount),
                        anchorId: row.int(MessageRecord.columnCount + 1),
                        isBefore: row.int(MessageRecord.columnCount + 2) != 0
                    )
                }
                for row in rows {
                    let anchor = Anchor(chatId: chatId, date: row.anchorDate, messageId: row.anchorId)
                    if row.isBefore {
                        result[anchor, default: Context()].before.insert(row.message, at: 0)
                    } else {
                        result[anchor, default: Context()].after.append(row.message)
                    }
                }
                start += chunk.count
            }
            for anchor in chatAnchors where result[anchor] == nil {
                result[anchor] = Context()
            }
        }
        return result
    }

    /// Five bindings per side per anchor; 100 anchors stay far below
    /// SQLite's default variable limit of 32766.
    private static func windowSQL(
        chatId: Int64,
        anchors: [Anchor],
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
        for anchor in anchors {
            let older = anchor.cursor.predicate(descending: true)
            let newer = anchor.cursor.predicate(descending: false)
            if before > 0 {
                parts.append("""
                    SELECT * FROM (
                      SELECT \(columns), ? AS anchor_date, ? AS anchor_id, 1 AS is_before
                      \(from)
                      WHERE cmj.chat_id = ? AND \(older.sql) AND \(SQLFragments.notReaction())
                      ORDER BY m.date DESC, m.ROWID DESC LIMIT \(before)
                    )
                    """)
                params += [anchor.date, anchor.messageId, chatId] + older.params
            }
            if after > 0 {
                parts.append("""
                    SELECT * FROM (
                      SELECT \(columns), ? AS anchor_date, ? AS anchor_id, 0 AS is_before
                      \(from)
                      WHERE cmj.chat_id = ? AND \(newer.sql) AND \(SQLFragments.notReaction())
                      ORDER BY m.date ASC, m.ROWID ASC LIMIT \(after)
                    )
                    """)
                params += [anchor.date, anchor.messageId, chatId] + newer.params
            }
        }
        return (parts.joined(separator: "\nUNION ALL\n"), params)
    }
}
