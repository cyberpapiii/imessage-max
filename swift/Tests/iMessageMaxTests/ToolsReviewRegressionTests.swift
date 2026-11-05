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
}
