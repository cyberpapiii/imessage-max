import Foundation
import IMessageMaxContract
import SQLite3
import XCTest
import MCP
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import NIOCore
@testable import iMessageMax

final class ToolTestDatabase {
    let url: URL
    let path: String
    private let db: OpaquePointer
    private let ownsFile: Bool

    init(name: String = "tool-fixture") throws {
        self.url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).sqlite")
        self.path = url.path
        self.ownsFile = true

        var dbPointer: OpaquePointer?
        guard sqlite3_open(path, &dbPointer) == SQLITE_OK, let dbPointer else {
            throw NSError(domain: "ToolTestDatabase", code: 1)
        }
        self.db = dbPointer
        try execute(schemaSQL)
    }

    init(attachingTo path: String) throws {
        self.url = URL(fileURLWithPath: path)
        self.path = path
        self.ownsFile = false

        var dbPointer: OpaquePointer?
        guard sqlite3_open(path, &dbPointer) == SQLITE_OK, let dbPointer else {
            throw NSError(domain: "ToolTestDatabase", code: 1)
        }
        self.db = dbPointer
    }

    deinit {
        sqlite3_close(db)
        if ownsFile {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "ToolTestDatabase", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    func insertHandle(rowId: Int, handle: String, service: String = "iMessage") throws {
        try execute("""
            INSERT INTO handle (ROWID, id, service)
            VALUES (\(rowId), '\(escape(handle))', '\(escape(service))');
            """)
    }

    func insertChat(rowId: Int, guid: String, displayName: String? = nil, serviceName: String = "iMessage", isFiltered: Int = 0) throws {
        let display = displayName.map { "'\(escape($0))'" } ?? "NULL"
        try execute("""
            INSERT INTO chat (ROWID, guid, display_name, service_name, is_filtered)
            VALUES (\(rowId), '\(escape(guid))', \(display), '\(escape(serviceName))', \(isFiltered));
            """)
    }

    func joinChatHandle(chatId: Int, handleId: Int) throws {
        try execute("""
            INSERT INTO chat_handle_join (chat_id, handle_id)
            VALUES (\(chatId), \(handleId));
            """)
    }

    func insertMessage(
        rowId: Int,
        guid: String,
        text: String? = nil,
        date: Int64,
        isFromMe: Bool,
        isRead: Bool = false,
        handleId: Int? = nil,
        associatedMessageType: Int = 0,
        associatedMessageGuid: String? = nil,
        error: Int = 0,
        isSent: Int = 0,
        attributedBody: Data? = nil,
        itemType: Int = 0,
        groupActionType: Int = 0,
        groupTitle: String? = nil,
        otherHandle: Int = 0,
        associatedMessageEmoji: String? = nil,
        threadOriginatorGuid: String? = nil,
        dateEdited: Int64 = 0,
        balloonBundleId: String? = nil
    ) throws {
        let textValue = text.map { "'\(escape($0))'" } ?? "NULL"
        let handleValue = handleId.map(String.init) ?? "NULL"
        let assocGuidValue = associatedMessageGuid.map { "'\(escape($0))'" } ?? "NULL"
        let groupTitleValue = groupTitle.map { "'\(escape($0))'" } ?? "NULL"
        let assocEmojiValue = associatedMessageEmoji.map { "'\(escape($0))'" } ?? "NULL"
        let threadOriginatorValue = threadOriginatorGuid.map { "'\(escape($0))'" } ?? "NULL"
        let balloonBundleValue = balloonBundleId.map { "'\(escape($0))'" } ?? "NULL"
        let attributedValue: String
        if let attributedBody {
            attributedValue = "X'\(attributedBody.map { String(format: "%02X", $0) }.joined())'"
        } else {
            attributedValue = "NULL"
        }

        try execute("""
            INSERT INTO message (
                ROWID, guid, text, attributedBody, date, is_from_me, is_read, handle_id, associated_message_type, associated_message_guid, error, is_sent, item_type, group_action_type, group_title, other_handle, associated_message_emoji, thread_originator_guid, date_edited, balloon_bundle_id
            ) VALUES (
                \(rowId), '\(escape(guid))', \(textValue), \(attributedValue), \(date), \(isFromMe ? 1 : 0), \(isRead ? 1 : 0), \(handleValue), \(associatedMessageType), \(assocGuidValue), \(error), \(isSent), \(itemType), \(groupActionType), \(groupTitleValue), \(otherHandle), \(assocEmojiValue), \(threadOriginatorValue), \(dateEdited), \(balloonBundleValue)
            );
            """)
    }

    func joinChatMessage(chatId: Int, messageId: Int) throws {
        try execute("""
            INSERT INTO chat_message_join (chat_id, message_id)
            VALUES (\(chatId), \(messageId));
            """)
    }

    func insertAttachment(
        rowId: Int,
        filename: String,
        mimeType: String?,
        uti: String,
        totalBytes: Int = 0,
        transferName: String? = nil,
        hideAttachment: Bool = false
    ) throws {
        let transfer = transferName.map { "'\(escape($0))'" } ?? "NULL"
        let mimeValue = mimeType.map { "'\(escape($0))'" } ?? "NULL"
        try execute("""
            INSERT INTO attachment (ROWID, filename, mime_type, uti, total_bytes, transfer_name, hide_attachment)
            VALUES (\(rowId), '\(escape(filename))', \(mimeValue), '\(escape(uti))', \(totalBytes), \(transfer), \(hideAttachment ? 1 : 0));
            """)
    }

    func joinMessageAttachment(messageId: Int, attachmentId: Int) throws {
        try execute("""
            INSERT INTO message_attachment_join (message_id, attachment_id)
            VALUES (\(messageId), \(attachmentId));
            """)
    }

    func database() -> Database {
        Database(path: path)
    }

    private var schemaSQL: String {
        """
        CREATE TABLE chat (
            ROWID INTEGER PRIMARY KEY,
            guid TEXT,
            display_name TEXT,
            service_name TEXT,
            is_filtered INTEGER DEFAULT 0
        );
        CREATE TABLE handle (
            ROWID INTEGER PRIMARY KEY,
            id TEXT,
            service TEXT
        );
        CREATE TABLE chat_handle_join (
            chat_id INTEGER,
            handle_id INTEGER
        );
        CREATE TABLE message (
            ROWID INTEGER PRIMARY KEY,
            guid TEXT,
            text TEXT,
            attributedBody BLOB,
            date INTEGER,
            is_from_me INTEGER,
            is_read INTEGER DEFAULT 0,
            handle_id INTEGER,
            associated_message_type INTEGER,
            associated_message_guid TEXT,
            error INTEGER DEFAULT 0,
            is_sent INTEGER DEFAULT 0,
            item_type INTEGER DEFAULT 0,
            group_action_type INTEGER DEFAULT 0,
            group_title TEXT,
            other_handle INTEGER DEFAULT 0,
            associated_message_emoji TEXT,
            thread_originator_guid TEXT,
            date_edited INTEGER DEFAULT 0,
            balloon_bundle_id TEXT
        );
        CREATE TABLE chat_message_join (
            chat_id INTEGER,
            message_id INTEGER
        );
        CREATE TABLE attachment (
            ROWID INTEGER PRIMARY KEY,
            filename TEXT,
            mime_type TEXT,
            uti TEXT,
            total_bytes INTEGER,
            transfer_name TEXT,
            hide_attachment INTEGER DEFAULT 0
        );
        CREATE TABLE message_attachment_join (
            message_id INTEGER,
            attachment_id INTEGER
        );
        """
    }
}

func makeSeededResolver() -> ContactResolver {
    ContactResolver(seedCache: [
        "+15550000001": "Alice Smith",
        "+15550000002": "Bob Brown",
        "+15550000003": "Chris Green",
    ])
}

func decodeJSONString(from contents: [Tool.Content], file: StaticString = #filePath, line: UInt = #line) throws -> String {
    guard let first = contents.first else {
        XCTFail("Expected tool content", file: file, line: line)
        return ""
    }
    switch first {
    case .text(let text, _, _):
        return text
    default:
        XCTFail("Expected text tool content", file: file, line: line)
        return ""
    }
}

func decodeJSONDictionary(from contents: [Tool.Content], file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
    let text = try decodeJSONString(from: contents, file: file, line: line)
    let data = Data(text.utf8)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
}

func decodeJSONDictionary(from text: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
    let data = Data(text.utf8)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
}

func decodeJSONArray(_ value: Any?, file: StaticString = #filePath, line: UInt = #line) throws -> [[String: Any]] {
    return try XCTUnwrap(value as? [[String: Any]], file: file, line: line)
}

func makeFixtureImage(name: String = "fixture.jpg", width: Int = 1200, height: Int = 800) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        throw NSError(domain: "ToolTestDatabase", code: 3)
    }

    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw NSError(domain: "ToolTestDatabase", code: 4)
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "ToolTestDatabase", code: 5)
    }

    return url
}

private func escape(_ input: String) -> String {
    input.replacingOccurrences(of: "'", with: "''")
}

func makeTestCatalog() -> ToolCatalog {
    ToolCatalog(database: Database(), resolver: ContactResolver(seedCache: [:]), access: makeTestMessagesAccess())
}

/// Never reaches Messages: Automation reads as authorized and launching
/// does nothing, so no test starts Messages or waits for it.
func makeTestMessagesAccess() -> MessagesAccess {
    MessagesAccess(
        memory: AutomationMemory(folder: nil),
        check: { _ in (true, .authorized) },
        launch: { _ in false })
}

func makeTestSetupPermissions() -> SetupPermissionService {
    SetupPermissionService(contactsRequest: { (true, "authorized") }, automationRequest: { (true, "authorized") })
}

func toolFailureBody<T>(
    file: StaticString = #filePath, line: UInt = #line,
    _ call: () async throws -> T
) async throws -> [String: Any] {
    do {
        _ = try await call()
        XCTFail("expected a tool failure", file: file, line: line)
        return [:]
    } catch let failure as ToolFailure {
        return try decodeJSONDictionary(from: failure.content)
    }
}

extension ContactResolver {
    init(
        seedCache: [String: String],
        authorization: (authorized: Bool, status: PermissionStatus) = (true, "authorized")
    ) {
        self.init(
            source: Source(
                authorization: { authorization },
                load: { seedCache },
                requestAccess: { authorization.authorized }
            ),
            refreshInterval: .infinity,
            now: { 0 }
        )
    }
}

func typedstreamBlob(marker: String = "NSString", lengthField: [UInt8]? = nil, payload: [UInt8]) -> Data {
    var bytes: [UInt8] = [0x04, 0x0B]
    bytes += Array(marker.utf8)
    bytes += [0x01, 0x94, 0x84, 0x01, 0x2B]
    bytes += lengthField ?? [UInt8(payload.count)]
    bytes += payload
    return Data(bytes)
}

func callTool(
    _ name: String,
    _ arguments: [String: Value] = [:],
    database: Database,
    resolver: ContactResolver = makeSeededResolver(),
    file: StaticString = #filePath, line: UInt = #line
) async throws -> [String: Any] {
    let catalog = ToolCatalog(database: database, resolver: resolver, access: makeTestMessagesAccess())
    let handler = try XCTUnwrap(catalog.handler(named: name), "\(name) is not registered", file: file, line: line)
    do {
        return try decodeJSONDictionary(from: try await handler(arguments), file: file, line: line)
    } catch let failure as ToolFailure {
        return try decodeJSONDictionary(from: failure.content, file: file, line: line)
    }
}

func countQueries(_ body: () async throws -> Void) async rethrows -> Int {
    Database.queryCountForTesting = 0
    defer { Database.queryCountForTesting = nil }
    try await body()
    return Database.queryCountForTesting ?? 0
}

func itemIds(_ json: [String: Any], _ key: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
    try decodeJSONArray(json[key], file: file, line: line).compactMap { $0["id"] as? String }
}

func itemChatIds(_ json: [String: Any], _ key: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String?] {
    try decodeJSONArray(json[key], file: file, line: line).map { ($0["chat"] as? [String: Any])?["id"] as? String }
}

func collectPages(
    _ name: String,
    _ arguments: [String: Value],
    resultsKey: String,
    database: Database,
    file: StaticString = #filePath, line: UInt = #line
) async throws -> (ids: [String], pages: Int) {
    var ids: [String] = []
    var cursor: String?
    var pages = 0
    repeat {
        var pageArguments = arguments
        if let cursor { pageArguments["cursor"] = .string(cursor) }
        let page = try await callTool(name, pageArguments, database: database, file: file, line: line)
        ids += try decodeJSONArray(page[resultsKey], file: file, line: line).compactMap { $0["id"] as? String }
        cursor = page["cursor"] as? String
        XCTAssertEqual(page["more"] as? Bool, cursor != nil, "more must agree with the cursor", file: file, line: line)
        pages += 1
    } while cursor != nil && pages < 20
    return (ids, pages)
}

/// Apple-epoch nanoseconds `offset` whole days after 2020-01-06T10:40:00Z,
/// which is 600,000,000 seconds after the Apple epoch.
func fixtureDay(_ offset: Int) -> Int64 {
    (600_000_000 + Int64(offset) * 86_400) * 1_000_000_000
}

let appleMinute: Int64 = 60_000_000_000

func filteredChatsFixture() throws -> ToolTestDatabase {
    let fixture = try ToolTestDatabase(name: "filtered-chats")
    let now = AppleTime.fromDate(Date())
    for (index, isFiltered) in [0, 1, 36].enumerated() {
        let chat = index + 1
        try fixture.insertHandle(rowId: chat, handle: "+1555000000\(chat)")
        try fixture.insertChat(rowId: chat, guid: "filtered-\(chat)", displayName: "Zebra Club \(chat)", isFiltered: isFiltered)
        try fixture.joinChatHandle(chatId: chat, handleId: chat)
        try fixture.insertMessage(
            rowId: chat, guid: "filtered-msg-\(chat)", text: "zebra \(chat)",
            date: now + Int64(chat) * 1_000_000_000, isFromMe: false, handleId: chat
        )
        try fixture.joinChatMessage(chatId: chat, messageId: chat)
    }
    return fixture
}

func blobTextFixture(fillerCount: Int) throws -> ToolTestDatabase {
    let fixture = try ToolTestDatabase(name: "blob-text")
    try fixture.insertHandle(rowId: 1, handle: "+15550000001")
    try fixture.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
    try fixture.joinChatHandle(chatId: 1, handleId: 1)
    let base = AppleTime.fromDate(Date()) - Int64(fillerCount + 10) * appleMinute
    try fixture.execute("BEGIN")
    try fixture.insertMessage(
        rowId: 1, guid: "HIT", date: base, isFromMe: false, handleId: 1,
        attributedBody: typedstreamBlob(payload: Array("off to Lisbon".utf8))
    )
    try fixture.joinChatMessage(chatId: 1, messageId: 1)
    for row in 2...(fillerCount + 1) {
        try fixture.insertMessage(
            rowId: row, guid: "F\(row)", date: base + Int64(row) * appleMinute, isFromMe: false, handleId: 1,
            attributedBody: typedstreamBlob(payload: Array("filler \(row)".utf8))
        )
        try fixture.joinChatMessage(chatId: 1, messageId: row)
    }
    try fixture.execute("COMMIT")
    return fixture
}

let aliceAndBob = ["+15550000001": "Alice Smith", "+15550000002": "Bob Brown"]

func participantsFixture() throws -> ToolTestDatabase {
    let fixture = try ToolTestDatabase(name: "participants")
    try fixture.insertHandle(rowId: 1, handle: "+15550000001")
    try fixture.insertHandle(rowId: 2, handle: "+15550000002")
    try fixture.insertHandle(rowId: 3, handle: "pat@example.com")
    let base = AppleTime.fromDate(Date()) - 100 * appleMinute
    var row = 0
    func say(_ chat: Int, atMinute minute: Int64, handle: Int) throws {
        row += 1
        try fixture.insertMessage(rowId: row, guid: "P\(row)", text: "hello \(row)", date: base + minute * appleMinute, isFromMe: false, handleId: handle)
        try fixture.joinChatMessage(chatId: chat, messageId: row)
    }
    try fixture.insertChat(rowId: 20, guid: "iMessage;+;alice-bob")
    try fixture.joinChatHandle(chatId: 20, handleId: 1)
    try fixture.joinChatHandle(chatId: 20, handleId: 2)
    try say(20, atMinute: 0, handle: 2)
    for chat in 1...12 {
        try fixture.insertChat(rowId: chat, guid: "iMessage;-;alice\(chat)")
        try fixture.joinChatHandle(chatId: chat, handleId: 1)
        try say(chat, atMinute: Int64(chat), handle: 1)
    }
    try fixture.insertChat(rowId: 30, guid: "iMessage;-;pat@example.com")
    try fixture.joinChatHandle(chatId: 30, handleId: 3)
    try say(30, atMinute: 50, handle: 3)
    return fixture
}

func hiddenMatchesFixture() throws -> ToolTestDatabase {
    let fixture = try ToolTestDatabase(name: "hidden-matches")
    let base = AppleTime.fromDate(Date()) - 60 * appleMinute
    let texts = [1: ["volcano trip"], 2: ["volcano photos", "volcano again?"], 3: ["nothing here", "still nothing"]]
    var row = 0
    for chat in 1...3 {
        try fixture.insertHandle(rowId: chat, handle: "+1555000000\(chat)")
        try fixture.insertChat(rowId: chat, guid: "iMessage;-;\(chat)", isFiltered: chat == 1 ? 0 : 1)
        try fixture.joinChatHandle(chatId: chat, handleId: chat)
        for text in texts[chat] ?? [] {
            row += 1
            try fixture.insertMessage(rowId: row, guid: "H\(row)", text: text, date: base + Int64(row) * appleMinute, isFromMe: true)
            try fixture.joinChatMessage(chatId: chat, messageId: row)
        }
    }
    return fixture
}

func messageInTwoChatsFixture() throws -> ToolTestDatabase {
    let fixture = try ToolTestDatabase(name: "two-chats")
    let recent = AppleTime.fromDate(Date()) - 60 * appleMinute
    try fixture.insertHandle(rowId: 1, handle: "+15550000001")
    try fixture.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
    try fixture.insertChat(rowId: 2, guid: "SMS;-;+15550000001", serviceName: "SMS")
    for row in 1...3 {
        try fixture.insertMessage(rowId: row, guid: "g\(row)", text: "hello \(row)", date: recent + Int64(row), isFromMe: false, handleId: 1)
        try fixture.joinChatMessage(chatId: 1, messageId: row)
    }
    try fixture.joinChatMessage(chatId: 2, messageId: 2)
    return fixture
}

func hiddenChatFixture() throws -> ToolTestDatabase {
    let fixture = try ToolTestDatabase(name: "named-hidden")
    let recent = AppleTime.fromDate(Date()) - 60 * appleMinute
    try fixture.insertHandle(rowId: 1, handle: "+15550000001")
    try fixture.insertHandle(rowId: 2, handle: "spam@example.com")
    try fixture.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
    try fixture.insertChat(rowId: 5, guid: "iMessage;-;spam@example.com", isFiltered: 1)
    try fixture.insertMessage(rowId: 1, guid: "g1", text: "hello friend", date: recent, isFromMe: false, handleId: 1)
    try fixture.joinChatMessage(chatId: 1, messageId: 1)
    try fixture.insertMessage(rowId: 2, guid: "g2", text: "hello prize", date: recent + 1, isFromMe: false, handleId: 2)
    try fixture.joinChatMessage(chatId: 5, messageId: 2)
    return fixture
}

func indexedHiddenChatFixture() throws -> ToolTestDatabase {
    let fixture = try ToolTestDatabase(name: "named-chat-plan")
    let recent = AppleTime.fromDate(Date()) - 60 * appleMinute
    try fixture.execute("""
        CREATE UNIQUE INDEX cmj_pk ON chat_message_join(chat_id, message_id);
        CREATE INDEX chat_message_join_idx_message_id_only ON chat_message_join(message_id);
        CREATE INDEX message_idx_date ON message(date);
        CREATE INDEX message_idx_is_read ON message(is_read, is_from_me);
        CREATE INDEX message_idx_handle ON message(handle_id, date);
        CREATE UNIQUE INDEX chj_pk ON chat_handle_join(chat_id, handle_id);
        CREATE UNIQUE INDEX maj_pk ON message_attachment_join(message_id, attachment_id);
        CREATE INDEX maj_attachment ON message_attachment_join(attachment_id);
        """)
    try fixture.insertHandle(rowId: 1, handle: "+15550000001")
    try fixture.insertHandle(rowId: 2, handle: "spam@example.com")
    try fixture.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
    try fixture.insertChat(rowId: 5, guid: "iMessage;-;spam@example.com", isFiltered: 1)
    try fixture.joinChatHandle(chatId: 1, handleId: 1)
    try fixture.joinChatHandle(chatId: 5, handleId: 2)
    for row in 1...40 {
        let chat = row % 4 == 0 ? 5 : 1
        try fixture.insertMessage(
            rowId: row, guid: "g\(row)", text: "hello zebra \(row)",
            date: recent + Int64(row), isFromMe: false, handleId: chat == 5 ? 2 : 1
        )
        try fixture.joinChatMessage(chatId: chat, messageId: row)
    }
    try fixture.insertAttachment(rowId: 1, filename: "~/Library/Messages/Attachments/a.jpg", mimeType: "image/jpeg", uti: "public.jpeg", totalBytes: 10)
    try fixture.joinMessageAttachment(messageId: 4, attachmentId: 1)
    return fixture
}

func directChatFixture(name: String = "direct-chat") throws -> ToolTestDatabase {
    let fixture = try ToolTestDatabase(name: name)
    try fixture.insertHandle(rowId: 1, handle: "+15550000001")
    try fixture.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
    try fixture.joinChatHandle(chatId: 1, handleId: 1)
    return fixture
}

func decodeJSONString(from buffer: ByteBuffer) throws -> String {
    var body = buffer
    return try XCTUnwrap(body.readString(length: body.readableBytes))
}

func decodeJSON(from buffer: ByteBuffer) throws -> [String: Any] {
    try decodeJSONDictionary(from: decodeJSONString(from: buffer))
}

func findRepoRoot(from fileURL: URL = URL(fileURLWithPath: #filePath)) throws -> URL {
    var directory = fileURL.deletingLastPathComponent()
    while directory.path != "/" {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("icon.png").path) {
            return directory
        }
        directory.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}

func jsonObject(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
