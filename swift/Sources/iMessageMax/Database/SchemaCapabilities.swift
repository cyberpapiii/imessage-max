// Sources/iMessageMax/Database/SchemaCapabilities.swift
import Foundation
import SQLite3

/// Which optional chat.db columns exist on this machine. Probed once per
/// `Database` instance from SQLite table_info (plan 081, after imsg's
/// MessageStoreSchema). Consult the flags when building SQL; never read a
/// guarded column unconditionally.
struct SchemaCapabilities: Sendable, Equatable {
    // message
    let messageThreadOriginatorGuid: Bool
    let messageThreadOriginatorPart: Bool
    let messageDateEdited: Bool
    let messageAssociatedMessageEmoji: Bool
    let messageDateRead: Bool
    let messageIsDelivered: Bool
    let messageIsAudioMessage: Bool
    let messageBalloonBundleId: Bool
    let messagePayloadData: Bool
    let messageDestinationCallerId: Bool
    let messageScheduleType: Bool
    let messageItemType: Bool
    let messageGroupActionType: Bool
    let messageGroupTitle: Bool
    let messageOtherHandle: Bool
    // chat
    let chatIsFiltered: Bool
    // chat_message_join
    let chatMessageJoinMessageDate: Bool
    // attachment
    let attachmentUserInfo: Bool
    let attachmentHideAttachment: Bool

    /// The macOS 15 floor the code was written against: everything present.
    static let assumed = SchemaCapabilities(
        messageThreadOriginatorGuid: true,
        messageThreadOriginatorPart: true,
        messageDateEdited: true,
        messageAssociatedMessageEmoji: true,
        messageDateRead: true,
        messageIsDelivered: true,
        messageIsAudioMessage: true,
        messageBalloonBundleId: true,
        messagePayloadData: true,
        messageDestinationCallerId: true,
        messageScheduleType: true,
        messageItemType: true,
        messageGroupActionType: true,
        messageGroupTitle: true,
        messageOtherHandle: true,
        chatIsFiltered: true,
        chatMessageJoinMessageDate: true,
        attachmentUserInfo: true,
        attachmentHideAttachment: true
    )

    /// Probe an open connection. Throws `DatabaseError.queryFailed` if a
    /// PRAGMA cannot be prepared (a missing table reads as an empty set,
    /// not an error, so every flag for that table is false).
    init(probing conn: OpaquePointer) throws {
        let message = try Self.tableColumns(conn, table: "message")
        let chat = try Self.tableColumns(conn, table: "chat")
        let cmj = try Self.tableColumns(conn, table: "chat_message_join")
        let attachment = try Self.tableColumns(conn, table: "attachment")
        messageThreadOriginatorGuid = message.contains("thread_originator_guid")
        messageThreadOriginatorPart = message.contains("thread_originator_part")
        messageDateEdited = message.contains("date_edited")
        messageAssociatedMessageEmoji = message.contains("associated_message_emoji")
        messageDateRead = message.contains("date_read")
        messageIsDelivered = message.contains("is_delivered")
        messageIsAudioMessage = message.contains("is_audio_message")
        messageBalloonBundleId = message.contains("balloon_bundle_id")
        messagePayloadData = message.contains("payload_data")
        messageDestinationCallerId = message.contains("destination_caller_id")
        messageScheduleType = message.contains("schedule_type")
        messageItemType = message.contains("item_type")
        messageGroupActionType = message.contains("group_action_type")
        messageGroupTitle = message.contains("group_title")
        messageOtherHandle = message.contains("other_handle")
        chatIsFiltered = chat.contains("is_filtered")
        chatMessageJoinMessageDate = cmj.contains("message_date")
        attachmentUserInfo = attachment.contains("user_info")
        attachmentHideAttachment = attachment.contains("hide_attachment")
    }

    /// Test-only: copy `base`, overriding the flags that are passed.
    init(
        base: SchemaCapabilities,
        messageThreadOriginatorGuid: Bool? = nil,
        messageDateEdited: Bool? = nil,
        messageAssociatedMessageEmoji: Bool? = nil,
        chatIsFiltered: Bool? = nil
    ) {
        self.messageThreadOriginatorGuid = messageThreadOriginatorGuid ?? base.messageThreadOriginatorGuid
        self.messageThreadOriginatorPart = base.messageThreadOriginatorPart
        self.messageDateEdited = messageDateEdited ?? base.messageDateEdited
        self.messageAssociatedMessageEmoji = messageAssociatedMessageEmoji ?? base.messageAssociatedMessageEmoji
        self.messageDateRead = base.messageDateRead
        self.messageIsDelivered = base.messageIsDelivered
        self.messageIsAudioMessage = base.messageIsAudioMessage
        self.messageBalloonBundleId = base.messageBalloonBundleId
        self.messagePayloadData = base.messagePayloadData
        self.messageDestinationCallerId = base.messageDestinationCallerId
        self.messageScheduleType = base.messageScheduleType
        self.messageItemType = base.messageItemType
        self.messageGroupActionType = base.messageGroupActionType
        self.messageGroupTitle = base.messageGroupTitle
        self.messageOtherHandle = base.messageOtherHandle
        self.chatIsFiltered = chatIsFiltered ?? base.chatIsFiltered
        self.chatMessageJoinMessageDate = base.chatMessageJoinMessageDate
        self.attachmentUserInfo = base.attachmentUserInfo
        self.attachmentHideAttachment = base.attachmentHideAttachment
    }

    private init(
        messageThreadOriginatorGuid: Bool,
        messageThreadOriginatorPart: Bool,
        messageDateEdited: Bool,
        messageAssociatedMessageEmoji: Bool,
        messageDateRead: Bool,
        messageIsDelivered: Bool,
        messageIsAudioMessage: Bool,
        messageBalloonBundleId: Bool,
        messagePayloadData: Bool,
        messageDestinationCallerId: Bool,
        messageScheduleType: Bool,
        messageItemType: Bool,
        messageGroupActionType: Bool,
        messageGroupTitle: Bool,
        messageOtherHandle: Bool,
        chatIsFiltered: Bool,
        chatMessageJoinMessageDate: Bool,
        attachmentUserInfo: Bool,
        attachmentHideAttachment: Bool
    ) {
        self.messageThreadOriginatorGuid = messageThreadOriginatorGuid
        self.messageThreadOriginatorPart = messageThreadOriginatorPart
        self.messageDateEdited = messageDateEdited
        self.messageAssociatedMessageEmoji = messageAssociatedMessageEmoji
        self.messageDateRead = messageDateRead
        self.messageIsDelivered = messageIsDelivered
        self.messageIsAudioMessage = messageIsAudioMessage
        self.messageBalloonBundleId = messageBalloonBundleId
        self.messagePayloadData = messagePayloadData
        self.messageDestinationCallerId = messageDestinationCallerId
        self.messageScheduleType = messageScheduleType
        self.messageItemType = messageItemType
        self.messageGroupActionType = messageGroupActionType
        self.messageGroupTitle = messageGroupTitle
        self.messageOtherHandle = messageOtherHandle
        self.chatIsFiltered = chatIsFiltered
        self.chatMessageJoinMessageDate = chatMessageJoinMessageDate
        self.attachmentUserInfo = attachmentUserInfo
        self.attachmentHideAttachment = attachmentHideAttachment
    }

    /// `"<table>.<column>": present`, for `diagnose`'s `database.features`.
    var features: [String: Bool] { [
        "message.thread_originator_guid": messageThreadOriginatorGuid,
        "message.thread_originator_part": messageThreadOriginatorPart,
        "message.date_edited": messageDateEdited,
        "message.associated_message_emoji": messageAssociatedMessageEmoji,
        "message.date_read": messageDateRead,
        "message.is_delivered": messageIsDelivered,
        "message.is_audio_message": messageIsAudioMessage,
        "message.balloon_bundle_id": messageBalloonBundleId,
        "message.payload_data": messagePayloadData,
        "message.destination_caller_id": messageDestinationCallerId,
        "message.schedule_type": messageScheduleType,
        "message.item_type": messageItemType,
        "message.group_action_type": messageGroupActionType,
        "message.group_title": messageGroupTitle,
        "message.other_handle": messageOtherHandle,
        "chat.is_filtered": chatIsFiltered,
        "chat_message_join.message_date": chatMessageJoinMessageDate,
        "attachment.user_info": attachmentUserInfo,
        "attachment.hide_attachment": attachmentHideAttachment,
    ] }

    // MARK: SQL fragments. Same alias in the same position, so the
    // index-based row mappers do not move.

    var threadOriginatorGuidSQL: String {
        messageThreadOriginatorGuid ? "m.thread_originator_guid" : "NULL AS thread_originator_guid"
    }
    var dateEditedSQL: String {
        messageDateEdited ? "m.date_edited" : "0 AS date_edited"
    }
    var associatedMessageEmojiSQL: String {
        messageAssociatedMessageEmoji ? "m.associated_message_emoji" : "NULL AS associated_message_emoji"
    }
    /// The `has_replies` EXISTS subquery, or a literal 0.
    var hasRepliesSQL: String {
        messageThreadOriginatorGuid
            ? """
              EXISTS (
                  SELECT 1 FROM message r
                  WHERE r.thread_originator_guid = m.guid
              ) AS has_replies
              """
            : "0 AS has_replies"
    }

    private static func tableColumns(_ conn: OpaquePointer, table: String) throws -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(conn)))
        }
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1) {
                names.insert(String(cString: c).lowercased())
            }
        }
        return names
    }
}
