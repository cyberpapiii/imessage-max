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

    /// Opens an existing fixture file for writing without creating the schema
    /// or deleting the file on deinit.
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
    ToolCatalog(database: Database(), resolver: ContactResolver(seedCache: [:]))
}

func makeTestSetupPermissions() -> SetupPermissionService {
    SetupPermissionService(contactsRequest: { (true, "authorized") }, automationRequest: { (true, "authorized") })
}

/// Runs a tool call that should fail and returns the JSON error body the
/// client would receive.
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
    /// A resolver that never touches CNContactStore.
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

/// An attributedBody blob in the typedstream shape MessageTextExtractor reads:
/// junk, the class marker, five skipped bytes, a length field, the UTF-8 text.
/// The length defaults to a single byte holding `payload.count`.
func typedstreamBlob(marker: String = "NSString", lengthField: [UInt8]? = nil, payload: [UInt8]) -> Data {
    var bytes: [UInt8] = [0x04, 0x0B]
    bytes += Array(marker.utf8)
    bytes += [0x01, 0x94, 0x84, 0x01, 0x2B]
    bytes += lengthField ?? [UInt8(payload.count)]
    bytes += payload
    return Data(bytes)
}

/// Calls a tool through the catalog the server serves and returns the JSON
/// body a client reads, whether the tool answered or failed.
func callTool(
    _ name: String,
    _ arguments: [String: Value] = [:],
    database: Database,
    resolver: ContactResolver = makeSeededResolver(),
    file: StaticString = #filePath, line: UInt = #line
) async throws -> [String: Any] {
    let catalog = ToolCatalog(database: database, resolver: resolver)
    let handler = try XCTUnwrap(catalog.handler(named: name), "\(name) is not registered", file: file, line: line)
    do {
        return try decodeJSONDictionary(from: try await handler(arguments), file: file, line: line)
    } catch let failure as ToolFailure {
        return try decodeJSONDictionary(from: failure.content, file: file, line: line)
    }
}

/// How many SQL queries `body` ran. Compare runs of different sizes rather
/// than pinning a number: the query plan is the tool's business, a count
/// that grows with the rows is the regression.
func countQueries(_ body: () async throws -> Void) async rethrows -> Int {
    Database.queryCountForTesting = 0
    defer { Database.queryCountForTesting = nil }
    try await body()
    return Database.queryCountForTesting ?? 0
}

/// The `id` of every item in `json[key]`.
func itemIds(_ json: [String: Any], _ key: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
    try decodeJSONArray(json[key], file: file, line: line).compactMap { $0["id"] as? String }
}

/// Follows a tool's cursors until it stops returning one, collecting the
/// `id` of every item under `resultsKey`. Stops after 20 pages.
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

// MARK: - Shared tool fixtures

/// Apple-epoch nanoseconds `offset` whole days after 2020-01-06T10:40:00Z,
/// which is 600,000,000 seconds after the Apple epoch.
func fixtureDay(_ offset: Int) -> Int64 {
    (600_000_000 + Int64(offset) * 86_400) * 1_000_000_000
}

/// One minute in Apple-epoch nanoseconds.
let appleMinute: Int64 = 60_000_000_000

/// Three chats, "Zebra Club 1" to "Zebra Club 3", with `is_filtered` 0, 1
/// and 36. Chat N holds one unread "zebra N" (msg_N) from +1555000000N,
/// newer as N grows.
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

/// Chat 1 with +15550000001: one attributedBody-only row (msg_1) holding
/// "off to Lisbon", then `fillerCount` newer attributedBody-only rows.
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

/// Contacts for `participantsFixture`.
let aliceAndBob = ["+15550000001": "Alice Smith", "+15550000002": "Bob Brown"]

/// Chats 1-12: DMs with Alice (+15550000001), newest last. Chat 20: Alice
/// and Bob, older than all of them. Chat 30: a DM with pat@example.com,
/// the newest.
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

/// Chat 1 is shown and says "volcano trip"; chat 2 is hidden and says
/// "volcano photos" and "volcano again?"; chat 3 is hidden with no match.
/// Every message is from me.
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

/// Chat 1, "iMessage;-;+15550000001", with handle 1 (+15550000001) joined
/// and no messages.
func directChatFixture(name: String = "direct-chat") throws -> ToolTestDatabase {
    let fixture = try ToolTestDatabase(name: name)
    try fixture.insertHandle(rowId: 1, handle: "+15550000001")
    try fixture.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
    try fixture.joinChatHandle(chatId: 1, handleId: 1)
    return fixture
}

// MARK: - HTTP bodies

func decodeJSONString(from buffer: ByteBuffer) throws -> String {
    var body = buffer
    return try XCTUnwrap(body.readString(length: body.readableBytes))
}

func decodeJSON(from buffer: ByteBuffer) throws -> [String: Any] {
    try decodeJSONDictionary(from: decodeJSONString(from: buffer))
}

// MARK: - Repository files

/// The repository root: the nearest ancestor of this file holding icon.png.
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
