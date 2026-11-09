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
    let edit: MessageEdit

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
            schema.dateRetractedSQL,
            schema.summaryInfoSQL,
        ].joined(separator: ", ")
    }

    static let columnCount: Int32 = 15

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
        edit = MessageEdit(
            dateEdited: row.optionalInt(12) ?? 0,
            dateRetracted: row.optionalInt(13) ?? 0,
            summaryInfo: row.blob(14),
            hasText: !(text ?? "").isEmpty
        )
    }
}

/// What the sender did to a message after sending it.
enum MessageEdit: Equatable {
    case none
    case edited
    case unsent

    /// `message_summary_info` is a plain plist. Its `rp` array lists the
    /// parts of the message the sender unsent, and Messages clears the text
    /// of an unsent part, so a row with `rp` entries and no text left was
    /// unsent. This check comes before `date_edited`, which an unsent row
    /// may carry too.
    init(dateEdited: Int64, dateRetracted: Int64, summaryInfo: Data?, hasText: Bool) {
        if dateRetracted != 0 || (!hasText && Self.hasUnsentParts(summaryInfo)) {
            self = .unsent
        } else {
            self = dateEdited != 0 ? .edited : .none
        }
    }

    private static func hasUnsentParts(_ summaryInfo: Data?) -> Bool {
        guard let summaryInfo,
              let plist = try? PropertyListSerialization.propertyList(from: summaryInfo, format: nil) as? [String: Any],
              let unsent = plist["rp"] as? [Any]
        else { return false }
        return !unsent.isEmpty
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
