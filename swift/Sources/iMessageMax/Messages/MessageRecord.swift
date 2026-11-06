import Foundation

/// One `message` row as every tool reads it. `text` is already extracted,
/// because Messages.app often leaves `message.text` empty and keeps the text
/// only in the `attributedBody` typedstream.
struct MessageRecord {
    let id: Int64
    let guid: String
    let text: String?
    let date: Int64?
    let isFromMe: Bool
    let senderHandle: String?
    let itemType: Int
    let groupActionType: Int
    let groupTitle: String?
    /// The `handle.id` that `message.other_handle` points to. It names the
    /// person a group event added or removed.
    let otherHandle: String?
    let threadOriginatorGuid: String?
    let isEdited: Bool

    static func selectList(_ schema: SchemaCapabilities) -> String {
        [
            "m.ROWID AS msg_id",
            "m.guid",
            "m.text",
            "m.attributedBody",
            "m.date",
            "m.is_from_me",
            "h.id AS sender_handle",
            "m.item_type",
            "m.group_action_type",
            "m.group_title",
            "oh.id AS other_handle_id",
            schema.threadOriginatorGuidSQL,
            schema.dateEditedSQL,
        ].joined(separator: ", ")
    }

    static let columnCount: Int32 = 13

    static let senderJoin = "handle h ON m.handle_id = h.ROWID"
    static let otherHandleJoin = "handle oh ON m.other_handle = oh.ROWID"
    static let handleJoinsSQL = "LEFT JOIN \(senderJoin)\nLEFT JOIN \(otherHandleJoin)"

    init(_ row: SQLiteRow) {
        id = row.int(0)
        guid = row.string(1) ?? ""
        text = MessageTextExtractor.extract(text: row.string(2), attributedBody: row.blob(3))
        date = row.optionalInt(4)
        isFromMe = row.int(5) != 0
        senderHandle = row.string(6)
        itemType = Int(row.int(7))
        groupActionType = Int(row.int(8))
        groupTitle = row.string(9)
        otherHandle = row.string(10)
        threadOriginatorGuid = row.string(11)
        isEdited = (row.optionalInt(12) ?? 0) != 0
    }
}

struct MessageInChat {
    let message: MessageRecord
    let chatId: Int64
    let chatName: String?

    static let chatColumns = "c.ROWID AS chat_id, c.display_name AS chat_name"

    init(_ row: SQLiteRow) {
        message = MessageRecord(row)
        chatId = row.int(MessageRecord.columnCount)
        chatName = row.string(MessageRecord.columnCount + 1)
    }
}

extension QueryBuilder {
    @discardableResult
    func selectMessages(_ schema: SchemaCapabilities, _ extra: String...) -> QueryBuilder {
        select(([MessageRecord.selectList(schema)] + extra).joined(separator: ", "))
    }

    @discardableResult
    func joinMessageHandles() -> QueryBuilder {
        leftJoin(MessageRecord.senderJoin).leftJoin(MessageRecord.otherHandleJoin)
    }
}
