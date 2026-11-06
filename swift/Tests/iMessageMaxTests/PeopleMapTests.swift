import MCP
import XCTest
@testable import iMessageMax

final class PeopleMapTests: XCTestCase {
    func testParticipantRulesSuffixCollisionsWithPositionAndNumberUnnamed() {
        var people = PeopleMap(rules: .participants)
        people.addMe()
        XCTAssertEqual(people.add(handle: "+1", name: "Alice Smith", position: 0), "alice")
        XCTAssertEqual(people.add(handle: "+2", name: nil, position: 1), "unknown1")
        XCTAssertEqual(people.add(handle: "+3", name: "Alice Jones", position: 2), "alice2")
        XCTAssertEqual(people.add(handle: "+4", name: "Me Too", position: 3), "me3")
        XCTAssertEqual(people.add(handle: "+1", name: "Alice Smith", position: 4), "alice")
        XCTAssertEqual(people.people.map(\.key), ["me", "alice", "unknown1", "alice2", "me3"])
    }

    func testSeenRulesCountCollisionsFromTwoAndNumberUnnamedWithP() {
        var people = PeopleMap(rules: .seen)
        XCTAssertEqual(people.add(handle: "+1", name: "Alice Smith"), "alice")
        XCTAssertEqual(people.add(handle: "+2", name: nil), "p1")
        XCTAssertEqual(people.add(handle: "+3", name: "Alice Jones"), "alice2")
        XCTAssertEqual(people.add(handle: "+4", name: "Alice Brown"), "alice3")
        XCTAssertEqual(people.add(handle: "+5", name: nil), "p2")
        people.addMe()
        XCTAssertEqual(people.people.last?.key, "me")
        XCTAssertTrue(people.people.last?.isMe ?? false)
    }

    func testLabelsUseKeysForSendersAndUnknownForStrangeReactors() {
        var people = PeopleMap(rules: .participants)
        people.addMe()
        people.add(handle: "+1", name: "Alice Smith")
        let labels = people.labels(noHandle: "unknown")
        XCTAssertEqual(labels.reactor(nil), "me")
        XCTAssertEqual(labels.reactor("+1"), "alice")
        XCTAssertEqual(labels.reactor("+9"), "unknown")
    }

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

    func testToolsKeepOneKeyPerPersonWhenContactsAreNamedLikeUnnamedKeys() async throws {
        let base = AppleTime.fromDate(Date()) - 60 * appleMinute
        let group = try ToolTestDatabase(name: "people-collide")
        for handle in 1...3 {
            try group.insertHandle(rowId: handle, handle: "+1555000000\(handle)")
            try group.joinChatHandle(chatId: 1, handleId: handle)
            try group.insertMessage(rowId: handle, guid: "C\(handle)", text: "hi \(handle)", date: base + Int64(handle) * appleMinute, isFromMe: false, handleId: handle)
            try group.joinChatMessage(chatId: 1, messageId: handle)
        }
        try group.insertChat(rowId: 1, guid: "iMessage;+;chat-collide")
        let messages = try await callTool(
            "get_messages", ["chat_id": "chat1"], database: group.database(),
            resolver: ContactResolver(seedCache: ["+15550000001": "Unknown A", "+15550000002": "Unknown B"])
        )
        XCTAssertEqual(try XCTUnwrap(messages["people"] as? [String: String]).count, 4)

        let pair = try ToolTestDatabase(name: "people-collide-seen")
        for handle in 1...2 {
            try pair.insertHandle(rowId: handle, handle: "+1555000000\(handle)")
            try pair.joinChatHandle(chatId: 1, handleId: handle)
            try pair.insertMessage(rowId: handle, guid: "S\(handle)", text: "yo \(handle)", date: base + Int64(handle) * appleMinute, isFromMe: false, handleId: handle)
            try pair.joinChatMessage(chatId: 1, messageId: handle)
        }
        try pair.insertChat(rowId: 1, guid: "iMessage;+;chat-seen")
        let context = try await callTool(
            "get_context", ["message_id": "msg_1"], database: pair.database(),
            resolver: ContactResolver(seedCache: ["+15550000001": "P1 Pilot"])
        )
        XCTAssertEqual(Set(try XCTUnwrap(context["people"] as? [String: Any]).keys), ["p1", "p2"])
    }
}
