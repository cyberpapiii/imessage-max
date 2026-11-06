import Foundation
import MCP
import XCTest
@testable import iMessageMax

final class ArgumentClampTests: XCTestCase {

    private func makeFixture() throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "argument-clamp")

        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertHandle(rowId: 2, handle: "+15550000002")

        try fixture.insertChat(rowId: 1, guid: "iMessage;-;alice-clamp-guid")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)

        try fixture.insertChat(rowId: 2, guid: "iMessage;+;group-clamp-guid", displayName: "Group Chat")
        try fixture.joinChatHandle(chatId: 2, handleId: 1)
        try fixture.joinChatHandle(chatId: 2, handleId: 2)

        let now = AppleTime.fromDate(Date())
        let hourNs: Int64 = 3_600_000_000_000
        try fixture.insertMessage(
            rowId: 1, guid: "msg-clamp-1", text: "hello, are you around?",
            date: now - 2 * hourNs, isFromMe: true
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 1)
        try fixture.insertMessage(
            rowId: 3, guid: "msg-clamp-3", text: "still there?",
            date: now - hourNs, isFromMe: true
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 3)
        try fixture.insertMessage(
            rowId: 2, guid: "msg-clamp-2", text: "hello from the group",
            date: now - hourNs, isFromMe: false, handleId: 2
        )
        try fixture.joinChatMessage(chatId: 2, messageId: 2)

        return fixture
    }

    func testSearchWithHugeUnansweredHoursReturns() async throws {
        let fixture = try makeFixture()
        let json = try await callTool("search", [
            "query": .string("hello"),
            "unanswered": .bool(true),
            "unanswered_hours": .int(Int.max),
        ], database: fixture.database())

        XCTAssertNotEqual(json["error"] as? String, "internal_error", "search must clamp unanswered_hours, not fail: \(json)")
        XCTAssertNotNil(json["results"], "search should answer normally with a clamped window: \(json)")
    }

    func testGetMessagesWithNegativeLimitReturns() async throws {
        let fixture = try makeFixture()
        let tool = GetMessagesTool(db: fixture.database(), resolver: makeSeededResolver())

        let contents = try await tool.execute(args: [
            "chat_id": .string("chat1"),
            "limit": .int(-5),
        ])

        let json = try decodeJSONDictionary(from: contents)
        let messages = try decodeJSONArray(json["messages"])
        XCTAssertEqual(messages.count, 1, "a negative limit clamps to 1, not to SQLite's unbounded LIMIT")
    }

    func testGetMessagesWithHugeUnansweredHoursReturns() async throws {
        let fixture = try makeFixture()
        let tool = GetMessagesTool(db: fixture.database(), resolver: makeSeededResolver())

        let contents = try await tool.execute(args: [
            "chat_id": .string("chat1"),
            "unanswered": .bool(true),
            "unanswered_hours": .int(Int.max),
        ])

        let json = try decodeJSONDictionary(from: contents)
        XCTAssertNotNil(json["messages"], "get_messages should answer normally with a clamped window: \(json)")
    }

    func testSinceWithHugeRelativeValueDoesNotDropFilterOrTrap() async throws {
        let fixture = try makeFixture()
        let tool = GetMessagesTool(db: fixture.database(), resolver: makeSeededResolver())

        let contents = try await tool.execute(args: [
            "chat_id": .string("chat1"),
            "since": .string("999999999h"),
        ])

        let json = try decodeJSONDictionary(from: contents)
        let messages = try decodeJSONArray(json["messages"])
        XCTAssertEqual(messages.count, 2, "a capped relative bound still includes every message in the chat: \(json)")
    }

    func testFindChatWithNegativeLimitReturns() async throws {
        let fixture = try makeFixture()

        let contents = try await FindChatTool.execute(
            arguments: [
                "participants": .array([.string("+15550000001")]),
                "limit": .int(-1),
            ],
            database: fixture.database(),
            resolver: makeSeededResolver()
        )

        let json = try decodeJSONDictionary(from: contents)
        XCTAssertNotNil(json["chats"], "find_chat should answer normally with a clamped limit: \(json)")
    }

    func testFindChatWithHugeLimitReturns() async throws {
        let fixture = try makeFixture()

        let contents = try await FindChatTool.execute(
            arguments: [
                "participants": .array([.string("+15550000001")]),
                "limit": .int(Int.max),
            ],
            database: fixture.database(),
            resolver: makeSeededResolver()
        )

        let json = try decodeJSONDictionary(from: contents)
        XCTAssertNotNil(json["chats"], "find_chat should answer normally with a clamped limit: \(json)")
    }
}
