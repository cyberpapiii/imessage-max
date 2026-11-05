import Foundation

/// What a page of messages carries beyond its own rows: tapbacks, reply
/// links and attachments. Each kind is one batched query for the whole page.
struct MessageAnnotations {
    struct Reaction {
        let type: Int
        let fromHandle: String?
        let emoji: String?
        let date: Int64
    }

    struct Attachment {
        let id: Int64
        let filename: String?
        let mimeType: String?
        let uti: String?
        let totalBytes: Int?
    }

    struct Include: OptionSet {
        let rawValue: Int
        static let reactions = Include(rawValue: 1 << 0)
        static let replies = Include(rawValue: 1 << 1)
        static let attachments = Include(rawValue: 1 << 2)
    }

    /// Keyed by the reacted-to message's guid, in chat.db order.
    var reactions: [String: [Reaction]] = [:]
    var replyToIdByGuid: [String: String] = [:]
    var replyCountByGuid: [String: Int] = [:]
    var attachments: [Int64: [Attachment]] = [:]

    static let none = MessageAnnotations()

    static func load(
        for records: [MessageRecord],
        include: Include,
        db: Database
    ) throws -> MessageAnnotations {
        var loaded = MessageAnnotations()
        guard !records.isEmpty else { return loaded }
        let guids = uniqueGuids(records)
        if include.contains(.reactions) {
            loaded.reactions = try reactionsByGuid(db: db, messageGuids: guids)
        }
        if include.contains(.replies) {
            try loaded.loadReplies(db: db, records: records, pageGuids: guids)
        }
        if include.contains(.attachments) {
            loaded.attachments = try attachmentsByMessage(db: db, messageIds: records.map(\.id))
        }
        return loaded
    }

    func replyTo(_ record: MessageRecord) -> String? {
        record.threadOriginatorGuid.flatMap { replyToIdByGuid[$0] }
    }

    func replyCount(_ record: MessageRecord) -> Int? {
        replyCountByGuid[record.guid]
    }

    private static func uniqueGuids(_ records: [MessageRecord]) -> [String] {
        var seen: Set<String> = []
        return records.map(\.guid).filter { seen.insert($0).inserted }
    }

    static func reactionsByGuid(db: Database, messageGuids: [String]) throws -> [String: [Reaction]] {
        guard !messageGuids.isEmpty else { return [:] }

        let placeholders = SQLFragments.placeholders(messageGuids.count)
        let schema = try db.schema()
        let sql = """
            SELECT m.associated_message_guid, m.associated_message_type, h.id,
                   \(schema.associatedMessageEmojiSQL), m.date
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.associated_message_type >= 2000
            AND (
                m.associated_message_guid IN (\(placeholders))
                OR substr(m.associated_message_guid, instr(m.associated_message_guid, '/') + 1)
                   IN (\(placeholders))
            )
            """

        var map: [String: [Reaction]] = [:]
        let rows = try db.query(sql, params: messageGuids + messageGuids) { row in
            (
                guid: row.string(0) ?? "",
                reaction: Reaction(
                    type: Int(row.int(1)),
                    fromHandle: row.string(2),
                    emoji: row.string(3),
                    date: row.optionalInt(4) ?? 0
                )
            )
        }
        for row in rows {
            let originalGuid = row.guid.hasPrefix("p:") || row.guid.hasPrefix("bp:")
                ? String(row.guid.split(separator: "/").last ?? "")
                : row.guid
            map[originalGuid, default: []].append(row.reaction)
        }
        return map
    }

    /// Originator ROWIDs not already on the page, then reply counts via
    /// GROUP BY: two queries per page, never one per row.
    private mutating func loadReplies(db: Database, records: [MessageRecord], pageGuids: [String]) throws {
        guard try db.schema().messageThreadOriginatorGuid else { return }
        for record in records {
            replyToIdByGuid[record.guid] = MessageIdentifier.format(record.id)
        }

        let originators = Set(records.compactMap(\.threadOriginatorGuid).filter { !$0.isEmpty })
        let missing = Array(originators.subtracting(replyToIdByGuid.keys))
        if !missing.isEmpty {
            let rows = try db.query(
                "SELECT guid, ROWID FROM message WHERE guid IN (\(SQLFragments.placeholders(missing.count)))",
                params: missing
            ) { row in
                (guid: row.string(0) ?? "", id: row.int(1))
            }
            for row in rows {
                replyToIdByGuid[row.guid] = MessageIdentifier.format(row.id)
            }
        }

        let rows = try db.query(
            """
            SELECT thread_originator_guid, COUNT(*)
            FROM message
            WHERE thread_originator_guid IN (\(SQLFragments.placeholders(pageGuids.count)))
            GROUP BY 1
            """,
            params: pageGuids
        ) { row in
            (guid: row.string(0) ?? "", count: Int(row.int(1)))
        }
        for row in rows where row.count > 0 {
            replyCountByGuid[row.guid] = row.count
        }
    }

    private static func attachmentsByMessage(db: Database, messageIds: [Int64]) throws -> [Int64: [Attachment]] {
        let sql = """
            SELECT maj.message_id, a.ROWID, a.filename, a.mime_type, a.uti, a.total_bytes
            FROM attachment a
            JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
            WHERE maj.message_id IN (\(SQLFragments.placeholders(messageIds.count)))
              AND COALESCE(a.hide_attachment, 0) = 0
            """
        var map: [Int64: [Attachment]] = [:]
        let rows = try db.query(sql, params: messageIds) { row in
            (
                messageId: row.int(0),
                attachment: Attachment(
                    id: row.int(1),
                    filename: row.string(2),
                    mimeType: row.string(3),
                    uti: row.string(4),
                    totalBytes: row.optionalInt(5).map { Int($0) }
                )
            )
        }
        for row in rows {
            map[row.messageId, default: []].append(row.attachment)
        }
        return map
    }
}
