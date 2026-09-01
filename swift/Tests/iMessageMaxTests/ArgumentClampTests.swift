import Foundation
import MCP
import XCTest
@testable import iMessageMax

/// Regression tests for plan 042. Each method feeds a tool the argument that
/// used to trap the whole launchd service (Int64 overflow in a multiply or a
/// Date conversion, or `prefix` on a negative count) and asserts the call
/// returns a normal, decodable response instead.
final class ArgumentClampTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ToolHandlerRegistry.shared.resetForTesting()
    }

    override func tearDown() {
        ToolHandlerRegistry.shared.resetForTesting()
        super.tearDown()
    }

    // MARK: - Fixture

    /// Two handles, a DM and a group chat, plus one outgoing question in the
    /// DM with no reply so the `unanswered` paths have a row to inspect.
    private func makeFixture() throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "argument-clamp")

        try fixture.insertHandle(rowId: 1, handle: "+15550000001")  // Alice
        try fixture.insertHandle(rowId: 2, handle: "+15550000002")  // Bob

        // Chat 1: DM with Alice (one participant)
        try fixture.insertChat(rowId: 1, guid: "iMessage;-;alice-clamp-guid")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)

        // Chat 2: group chat with Alice and Bob
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
            rowId: 2, guid: "msg-clamp-2", text: "hello from the group",
            date: now - hourNs, isFromMe: false, handleId: 2
        )
        try fixture.joinChatMessage(chatId: 2, messageId: 2)

        return fixture
    }

    private func makeServer() -> Server {
        Server(
            name: Version.name,
            version: Version.current,
            title: Version.title,
            instructions: Version.instructions,
            capabilities: Version.serverCapabilities
        )
    }

    /// Runs a tool through its registered handler (the closure that parses the
    /// raw argument dictionary) and returns the JSON body whether the tool
    /// answered normally or threw a structured `ToolError`.
    private func callRegistered(_ name: String, arguments: [String: Value]) async throws -> [String: Any] {
        let handler = try XCTUnwrap(ToolHandlerRegistry.shared.getHandler(for: name), "\(name) should be registered")
        do {
            return try decodeJSONDictionary(from: try await handler(arguments))
        } catch let error as ToolError {
            return try decodeJSONDictionary(from: error.content)
        }
    }

    // MARK: - search

    func testSearchWithHugeUnansweredHoursReturns() async throws {
        let fixture = try makeFixture()
        SearchTool.register(on: makeServer(), db: fixture.database(), resolver: makeSeededResolver())

        let json = try await callRegistered("search", arguments: [
            "query": .string("hello"),
            "unanswered": .bool(true),
            "unanswered_hours": .int(Int.max),
        ])

        XCTAssertNotEqual(json["error"] as? String, "internal_error", "search must clamp unanswered_hours, not fail: \(json)")
        XCTAssertNotNil(json["results"], "search should answer normally with a clamped window: \(json)")
    }

    // MARK: - get_messages

    func testGetMessagesWithNegativeLimitReturns() async throws {
        let fixture = try makeFixture()
        let tool = GetMessagesTool(db: fixture.database(), resolver: makeSeededResolver())

        let contents = try await tool.execute(args: [
            "chat_id": .string("chat1"),
            "limit": .int(-5),
        ])

        let json = try decodeJSONDictionary(from: contents)
        let messages = try decodeJSONArray(json["messages"])
        XCTAssertLessThanOrEqual(messages.count, 1, "a negative limit clamps to 1, not to SQLite's unbounded LIMIT")
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
        XCTAssertEqual(messages.count, 1, "a capped relative bound still includes every message in the chat: \(json)")
    }

    // MARK: - find_chat

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
