// Sources/iMessageMax/Database/SchemaCapabilities.swift
import Foundation
import SQLite3

/// Which optional chat.db columns exist on this machine. Probed once per
/// `Database` instance from SQLite table_info. Consult the flags when
/// building SQL; never read a guarded column unconditionally.
struct SchemaCapabilities: Sendable, Equatable {
    /// Every optional column, as `<table>.<column>`.
    enum Column: String, CaseIterable, Sendable {
        case messageThreadOriginatorGuid = "message.thread_originator_guid"
        case messageThreadOriginatorPart = "message.thread_originator_part"
        case messageDateEdited = "message.date_edited"
        case messageAssociatedMessageEmoji = "message.associated_message_emoji"
        case messageDateRead = "message.date_read"
        case messageIsDelivered = "message.is_delivered"
        case messageIsAudioMessage = "message.is_audio_message"
        case messageBalloonBundleId = "message.balloon_bundle_id"
        case messagePayloadData = "message.payload_data"
        case messageDestinationCallerId = "message.destination_caller_id"
        case messageScheduleType = "message.schedule_type"
        case messageItemType = "message.item_type"
        case messageGroupActionType = "message.group_action_type"
        case messageGroupTitle = "message.group_title"
        case messageOtherHandle = "message.other_handle"
        case chatIsFiltered = "chat.is_filtered"
        case chatMessageJoinMessageDate = "chat_message_join.message_date"
        case attachmentUserInfo = "attachment.user_info"
        case attachmentHideAttachment = "attachment.hide_attachment"

        var table: String { String(rawValue.prefix { $0 != "." }) }
        var name: String { String(rawValue.drop { $0 != "." }.dropFirst()) }
    }

    private let present: Set<Column>

    /// The macOS 15 floor the code was written against: everything present.
    static let assumed = SchemaCapabilities(present: Set(Column.allCases))

    private init(present: Set<Column>) {
        self.present = present
    }

    /// Probe an open connection. Throws `DatabaseError.queryFailed` if a
    /// PRAGMA cannot be prepared (a missing table reads as an empty set,
    /// not an error, so every flag for that table is false).
    init(probing conn: OpaquePointer) throws {
        var columnsByTable: [String: Set<String>] = [:]
        for table in Set(Column.allCases.map(\.table)) {
            columnsByTable[table] = try Self.tableColumns(conn, table: table)
        }
        present = Set(Column.allCases.filter { columnsByTable[$0.table]?.contains($0.name) == true })
    }

    func has(_ column: Column) -> Bool { present.contains(column) }

    /// A copy without `columns`, for tests that simulate an older schema.
    func without(_ columns: Column...) -> SchemaCapabilities {
        SchemaCapabilities(present: present.subtracting(columns))
    }

    var messageThreadOriginatorGuid: Bool { has(.messageThreadOriginatorGuid) }

    /// `"<table>.<column>": present`, for `diagnose`'s `database.features`.
    var features: [String: Bool] {
        Dictionary(uniqueKeysWithValues: Column.allCases.map { ($0.rawValue, has($0)) })
    }

    // MARK: SQL fragments. Same alias in the same position, so the
    // index-based row mappers do not move.

    var threadOriginatorGuidSQL: String {
        has(.messageThreadOriginatorGuid) ? "m.thread_originator_guid" : "NULL AS thread_originator_guid"
    }
    var dateEditedSQL: String {
        has(.messageDateEdited) ? "m.date_edited" : "0 AS date_edited"
    }
    var associatedMessageEmojiSQL: String {
        has(.messageAssociatedMessageEmoji) ? "m.associated_message_emoji" : "NULL AS associated_message_emoji"
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
