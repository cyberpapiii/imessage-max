import Foundation
import SQLite3
import XCTest
import MCP
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import iMessageMax

final class ToolTestDatabase {
    let url: URL
    let path: String
    private let db: OpaquePointer

    init(name: String = "tool-fixture") throws {
        self.url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).sqlite")
        self.path = url.path

        var dbPointer: OpaquePointer?
        guard sqlite3_open(path, &dbPointer) == SQLITE_OK, let dbPointer else {
            throw NSError(domain: "ToolTestDatabase", code: 1)
        }
        self.db = dbPointer
        try execute(schemaSQL)
    }

    deinit {
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: url)
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

    func insertChat(rowId: Int, guid: String, displayName: String? = nil, serviceName: String = "iMessage") throws {
        let display = displayName.map { "'\(escape($0))'" } ?? "NULL"
        try execute("""
            INSERT INTO chat (ROWID, guid, display_name, service_name)
            VALUES (\(rowId), '\(escape(guid))', \(display), '\(escape(serviceName))');
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
        isSent: Int = 0
    ) throws {
        let textValue = text.map { "'\(escape($0))'" } ?? "NULL"
        let handleValue = handleId.map(String.init) ?? "NULL"
        let assocGuidValue = associatedMessageGuid.map { "'\(escape($0))'" } ?? "NULL"

        try execute("""
            INSERT INTO message (
                ROWID, guid, text, attributedBody, date, is_from_me, is_read, handle_id, associated_message_type, associated_message_guid, error, is_sent
            ) VALUES (
                \(rowId), '\(escape(guid))', \(textValue), NULL, \(date), \(isFromMe ? 1 : 0), \(isRead ? 1 : 0), \(handleValue), \(associatedMessageType), \(assocGuidValue), \(error), \(isSent)
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
        mimeType: String,
        uti: String,
        totalBytes: Int = 0,
        transferName: String? = nil
    ) throws {
        let transfer = transferName.map { "'\(escape($0))'" } ?? "NULL"
        try execute("""
            INSERT INTO attachment (ROWID, filename, mime_type, uti, total_bytes, transfer_name)
            VALUES (\(rowId), '\(escape(filename))', '\(escape(mimeType))', '\(escape(uti))', \(totalBytes), \(transfer));
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
            service_name TEXT
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
            is_sent INTEGER DEFAULT 0
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
            transfer_name TEXT
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
