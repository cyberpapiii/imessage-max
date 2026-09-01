import XCTest
import SQLite3
@testable import iMessageMax

final class SendResolverTests: XCTestCase {
    func testResolveChatIdReturnsExactChatTarget() async throws {
        let dbPath = try makeResolverTestDatabase()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let resolver = SendResolver(db: Database(path: dbPath), resolver: ContactResolver())
        let result = await resolver.resolve(chatId: "chat10", to: nil)

        switch result {
        case .failure(let message):
            XCTFail("Unexpected failure: \(message)")
        case .ambiguous:
            XCTFail("Unexpected ambiguity")
        case .success(let resolved):
            guard case .chat(let guid, let chatId) = resolved.target else {
                return XCTFail("Expected exact chat target")
            }
            XCTAssertEqual(guid, "any;+;chat-test-guid")
            XCTAssertEqual(chatId, 10)
            XCTAssertEqual(Set(resolved.deliveredTo), Set(["+1 (555) 555-0123", "+1 (555) 555-0124"]))
        }
    }

    func testResolvePhoneNumberReturnsParticipantTarget() async throws {
        let dbPath = try makeResolverTestDatabase()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let resolver = SendResolver(db: Database(path: dbPath), resolver: ContactResolver())
        let result = await resolver.resolve(chatId: nil, to: "+15555550123")

        switch result {
        case .failure(let message):
            XCTFail("Unexpected failure: \(message)")
        case .ambiguous:
            XCTFail("Unexpected ambiguity")
        case .success(let resolved):
            guard case .participant(let handle, let chatId) = resolved.target else {
                return XCTFail("Expected participant target")
            }
            XCTAssertEqual(handle, "+15555550123")
            XCTAssertEqual(chatId, 11)
            XCTAssertEqual(resolved.deliveredTo, ["+1 (555) 555-0123"])
        }
    }

    func testResolveNameSingleMatchReturnsParticipant() async throws {
        let dbPath = try makeResolverTestDatabase()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let contacts = ContactResolver(seedCache: ["+15555550123": "Nick Jones"])
        let resolver = SendResolver(db: Database(path: dbPath), resolver: contacts)
        let result = await resolver.resolve(chatId: nil, to: "Nick")

        switch result {
        case .failure(let message):
            XCTFail("Unexpected failure: \(message)")
        case .ambiguous:
            XCTFail("Unexpected ambiguity")
        case .success(let resolved):
            guard case .participant(let handle, let chatId) = resolved.target else {
                return XCTFail("Expected participant target")
            }
            XCTAssertEqual(handle, "+15555550123")
            XCTAssertEqual(chatId, 11)
            XCTAssertEqual(resolved.deliveredTo, ["Nick Jones"])
        }
    }

    func testResolveNameMultiMatchReturnsAmbiguousSortedByRecency() async throws {
        let dbPath = try makeResolverTestDatabase()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let contacts = ContactResolver(seedCache: [
            "+15555550123": "Nick Jones",
            "+15555550124": "Andrew Jones",
        ])
        let resolver = SendResolver(db: Database(path: dbPath), resolver: contacts)
        let result = await resolver.resolve(chatId: nil, to: "Jones")

        switch result {
        case .failure(let message):
            XCTFail("Unexpected failure: \(message)")
        case .success:
            XCTFail("Unexpected success")
        case .ambiguous(let candidates):
            XCTAssertEqual(candidates.count, 2)
            // Handle 1 has a message row (date 1000); handle 2 has none.
            // nil-lastContact sorts last per SendResolution.swift's comparator.
            XCTAssertEqual(candidates[0].handle, "+15555550123")
            XCTAssertEqual(candidates[1].handle, "+15555550124")
            XCTAssertEqual(candidates[1].lastContact, "never")
            // Deliberately not asserting candidates[0].lastContact's exact
            // string. It's a relative-time format that drifts with the clock.
        }
    }

    func testResolveNameNoMatchFails() async throws {
        let dbPath = try makeResolverTestDatabase()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let contacts = ContactResolver(seedCache: ["+15555550123": "Nick Jones"])
        let resolver = SendResolver(db: Database(path: dbPath), resolver: contacts)
        let result = await resolver.resolve(chatId: nil, to: "Zelda")

        guard case .failure(let message) = result else {
            return XCTFail("Expected failure for unmatched name")
        }
        // Which of the two appears depends on the machine's real Contacts
        // authorization. It must pass on both authorized dev machines and
        // unauthorized CI, so accept either.
        XCTAssertTrue(
            message.contains("No contact found matching 'Zelda'")
                || message.contains("Cannot search by name without contacts access"),
            "Unexpected failure message: \(message)"
        )
    }

    func testNameResolutionUsesOneLastContactQuery() async throws {
        let fixture = try ToolTestDatabase(name: "send-jo")
        let names = [
            "Jo Smith", "Joanna Lee", "John Park", "Jordan Kim",
            "Joyce Wu", "Joel Ray", "Joseph Ng", "Joy Chen",
        ]
        var seed: [String: String] = [:]
        for (index, name) in names.enumerated() {
            let handle = "+1555100000\(index)"
            seed[handle] = name
            try fixture.insertHandle(rowId: index + 1, handle: handle)
            try fixture.insertMessage(
                rowId: index + 1,
                guid: "jo-msg-\(index)",
                text: "hi",
                date: Int64(index + 1) * 1_000,
                isFromMe: false,
                handleId: index + 1
            )
        }

        let contacts = ContactResolver(seedCache: seed)
        let resolver = SendResolver(db: fixture.database(), resolver: contacts)

        Database.queryCountForTesting = 0
        defer { Database.queryCountForTesting = nil }

        let result = await resolver.resolve(chatId: nil, to: "Jo")
        guard case .ambiguous(let candidates) = result else {
            return XCTFail("Expected ambiguous name resolution")
        }
        XCTAssertEqual(candidates.count, 8)
        let queryCount = try XCTUnwrap(Database.queryCountForTesting)
        XCTAssertLessThanOrEqual(queryCount, 3, "send-by-name ran \(queryCount) queries")
    }
}

private func makeResolverTestDatabase() throws -> String {
    let dbURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("imessage-max-send-resolver-\(UUID().uuidString).sqlite")

    var db: OpaquePointer?
    guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
        XCTFail("Failed to open temp sqlite database")
        return dbURL.path
    }
    defer { sqlite3_close(db) }

    let statements = [
        "CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, display_name TEXT);",
        "CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT);",
        "CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);",
        "CREATE TABLE message (ROWID INTEGER PRIMARY KEY, handle_id INTEGER, date INTEGER);",
        "INSERT INTO handle (ROWID, id) VALUES (1, '+15555550123');",
        "INSERT INTO handle (ROWID, id) VALUES (2, '+15555550124');",
        "INSERT INTO chat (ROWID, guid, display_name) VALUES (10, 'any;+;chat-test-guid', NULL);",
        "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (10, 1);",
        "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (10, 2);",
        "INSERT INTO chat (ROWID, guid, display_name) VALUES (11, 'any;-;+15555550123', NULL);",
        "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (11, 1);",
        "INSERT INTO message (ROWID, handle_id, date) VALUES (1, 1, 1000);"
    ]

    for statement in statements {
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            XCTFail("SQLite setup failed: \(message)")
            break
        }
    }

    return dbURL.path
}
