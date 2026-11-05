import XCTest
import MCP
@testable import iMessageMax

/// Regressions for the read-tool review fixes.
final class ToolsReviewRegressionTests: XCTestCase {
    private let minute: Int64 = 60_000_000_000

    private func now() -> Int64 { Int64(Date().timeIntervalSinceReferenceDate) * 1_000_000_000 }

    private func call(
        _ name: String,
        _ args: [String: Value],
        db: ToolTestDatabase,
        contacts: [String: String] = [:]
    ) async throws -> [String: Any] {
        let catalog = ToolCatalog(database: db.database(), resolver: ContactResolver(seedCache: contacts))
        let handler = try XCTUnwrap(catalog.handler(named: name))
        return try decodeJSONDictionary(from: try await handler(args))
    }

    // MARK: - People keys never collide

    func testUnnamedKeySkipsAKeyAContactAlreadyHolds() {
        var people = PeopleMap(rules: .participants)
        people.addMe()
        XCTAssertEqual(people.add(handle: "+1", name: "Unknown A", position: 0), "unknown")
        XCTAssertEqual(people.add(handle: "+2", name: "Unknown B", position: 1), "unknown1")
        XCTAssertEqual(people.add(handle: "+3", name: nil, position: 2), "unknown2")
        XCTAssertEqual(Set(people.people.map(\.key)).count, people.people.count)
    }

    func testPositionSuffixSkipsAKeyAlreadyTaken() {
        var people = PeopleMap(rules: .participants)
        XCTAssertEqual(people.add(handle: "+1", name: nil, position: 0), "unknown1")
        XCTAssertEqual(people.add(handle: "+2", name: "Unknown A", position: 1), "unknown")
        XCTAssertEqual(people.add(handle: "+3", name: "Unknown B", position: 1), "unknown2")
    }

    func testSeenUnnamedKeySkipsAContactKey() {
        var people = PeopleMap(rules: .seen)
        XCTAssertEqual(people.add(handle: "+1", name: "P1 Pilot"), "p1")
        XCTAssertEqual(people.add(handle: "+2", name: nil), "p2")
    }

    /// Trapped in Dictionary(uniqueKeysWithValues:) before the fix.
    func testGetMessagesAndGetContextSurviveContactsNamedLikeUnnamedKeys() async throws {
        let db = try ToolTestDatabase(name: "people-collide")
        try db.insertHandle(rowId: 1, handle: "+15550000001")
        try db.insertHandle(rowId: 2, handle: "+15550000002")
        try db.insertHandle(rowId: 3, handle: "+15550000003")
        try db.insertChat(rowId: 1, guid: "iMessage;+;chat-collide")
        for h in 1...3 { try db.joinChatHandle(chatId: 1, handleId: h) }
        let base = now() - 60 * minute
        for (i, h) in [1, 2, 3].enumerated() {
            try db.insertMessage(rowId: i + 1, guid: "C\(i)", text: "hi \(i)", date: base + Int64(i) * minute, isFromMe: false, handleId: h)
            try db.joinChatMessage(chatId: 1, messageId: i + 1)
        }
        // +15550000003 has no contact, so it takes the unnamed key.
        let contacts = ["+15550000001": "Unknown A", "+15550000002": "Unknown B"]

        let messages = try await call("get_messages", ["chat_id": "chat1"], db: db, contacts: contacts)
        let people = try XCTUnwrap(messages["people"] as? [String: String])
        XCTAssertEqual(people.count, 4)

        let db2 = try ToolTestDatabase(name: "people-collide-seen")
        try db2.insertHandle(rowId: 1, handle: "+15550000001")
        try db2.insertHandle(rowId: 2, handle: "+15550000002")
        try db2.insertChat(rowId: 1, guid: "iMessage;+;chat-seen")
        for h in 1...2 { try db2.joinChatHandle(chatId: 1, handleId: h) }
        for (i, h) in [1, 2].enumerated() {
            try db2.insertMessage(rowId: i + 1, guid: "S\(i)", text: "yo \(i)", date: base + Int64(i) * minute, isFromMe: false, handleId: h)
            try db2.joinChatMessage(chatId: 1, messageId: i + 1)
        }
        let context = try await call("get_context", ["message_id": "msg_1"], db: db2, contacts: ["+15550000001": "P1 Pilot"])
        let seen = try XCTUnwrap(context["people"] as? [String: Any])
        XCTAssertEqual(Set(seen.keys), ["p1", "p2"])
    }

    // MARK: - Paging past rows Swift drops

    /// Follows cursors until the tool stops returning one.
    private func pages(
        _ name: String,
        _ args: [String: Value],
        resultsKey: String,
        db: ToolTestDatabase
    ) async throws -> (ids: [String], pages: Int) {
        var ids: [String] = []
        var cursor: String?
        var count = 0
        repeat {
            var pageArgs = args
            if let cursor { pageArgs["cursor"] = .string(cursor) }
            let page = try await call(name, pageArgs, db: db)
            ids += try decodeJSONArray(page[resultsKey]).compactMap { $0["id"] as? String }
            cursor = page["cursor"] as? String
            XCTAssertEqual(page["more"] as? Bool, cursor != nil)
            count += 1
        } while cursor != nil && count < 20
        return (ids, count)
    }

    /// The blob holds the class name "NSString", so every attributedBody
    /// row passes the SQL prefilter for "string" and Swift drops them all.
    func testSearchReachesAMatchBehindAFullFetchOfPrefilterFalsePositives() async throws {
        let db = try ToolTestDatabase(name: "search-paging")
        try db.insertHandle(rowId: 1, handle: "+15550000001")
        try db.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
        try db.joinChatHandle(chatId: 1, handleId: 1)
        let base = now() - 1_000 * minute
        try db.insertMessage(rowId: 1, guid: "M1", text: "tie the string here", date: base, isFromMe: false, handleId: 1)
        try db.joinChatMessage(chatId: 1, messageId: 1)
        try db.execute("BEGIN")
        for i in 2...601 {
            try db.insertMessage(
                rowId: i, guid: "M\(i)", date: base + Int64(i) * minute, isFromMe: false, handleId: 1,
                attributedBody: typedstreamBlob(payload: Array("filler \(i)".utf8))
            )
            try db.joinChatMessage(chatId: 1, messageId: i)
        }
        try db.execute("COMMIT")

        for args: [String: Value] in [["query": "string", "limit": 1], ["query": "strng", "fuzzy": true, "limit": 1]] {
            let found = try await pages("search", args, resultsKey: "results", db: db)
            XCTAssertEqual(found.ids, ["msg_1"], "\(args)")
            XCTAssertGreaterThan(found.pages, 1)
        }
    }

    func testUnansweredGetMessagesPagesPastNonQuestions() async throws {
        let db = try ToolTestDatabase(name: "unanswered-paging")
        try db.insertHandle(rowId: 1, handle: "+15550000001")
        try db.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
        try db.joinChatHandle(chatId: 1, handleId: 1)
        let base = now() - 1_000 * minute
        try db.insertMessage(rowId: 1, guid: "Q", text: "are you coming?", date: base, isFromMe: true)
        try db.joinChatMessage(chatId: 1, messageId: 1)
        for i in 2...5 {
            try db.insertMessage(rowId: i, guid: "N\(i)", text: "note \(i)", date: base + Int64(i) * minute, isFromMe: true)
            try db.joinChatMessage(chatId: 1, messageId: i)
        }

        let found = try await pages(
            "get_messages", ["chat_id": "chat1", "unanswered": true, "limit": 1], resultsKey: "messages", db: db
        )
        XCTAssertEqual(found.ids, ["msg_1"])
    }
}
