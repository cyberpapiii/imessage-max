import MCP
import XCTest
@testable import iMessageMax

final class ChatIdentifierTests: XCTestCase {

    func testNumericRowId() {
        XCTAssertEqual(ChatIdentifier.parseRowId("123"), 123)
        XCTAssertEqual(ChatIdentifier.parseRowId("20"), 20)
    }

    func testChatPrefix() {
        XCTAssertEqual(ChatIdentifier.parseRowId("chat123"), 123)
        XCTAssertEqual(ChatIdentifier.parseRowId("chat20"), 20)
    }

    func testWhitespace() {
        XCTAssertEqual(ChatIdentifier.parseRowId("  123  "), 123)
        XCTAssertEqual(ChatIdentifier.parseRowId("  chat123  "), 123)
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(ChatIdentifier.parseRowId(""))
        XCTAssertNil(ChatIdentifier.parseRowId("   "))
        XCTAssertNil(ChatIdentifier.parseRowId("abc"))
        XCTAssertNil(ChatIdentifier.parseRowId("chat"))
        XCTAssertNil(ChatIdentifier.parseRowId("chatABC"))
        XCTAssertNil(ChatIdentifier.parseRowId("iMessage;-;chat123"))
    }

    func testSignPrefixReturnsNil() {
        for raw in ["-5", "+5", "chat-5", "chat+5", " -5 "] {
            XCTAssertNil(ChatIdentifier.parseRowId(raw), "parseRowId(\(raw)) must be nil")
        }
    }

    // MARK: - Chat ids in the tools

    /// chat1 and chat2 ("Old Trip", "New Trip") both say "trip hello"; chat2
    /// is the more recent.
    private func twoTripChatsFixture() throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "chat-ids")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 1, guid: "iMessage;+;chat-trip-old", displayName: "Old Trip")
        try fixture.insertChat(rowId: 2, guid: "iMessage;+;chat-trip-new", displayName: "New Trip")
        for chat in 1...2 {
            try fixture.joinChatHandle(chatId: chat, handleId: 1)
            try fixture.insertMessage(rowId: chat, guid: "g\(chat)", text: "trip hello", date: 700_000_000_000_000_000 + Int64(chat), isFromMe: false, handleId: 1)
            try fixture.joinChatMessage(chatId: chat, messageId: chat)
        }
        return fixture
    }

    func testEveryChatIdArgumentAnswersChatNotFoundForAnUnknownChat() async throws {
        let fixture = try twoTripChatsFixture()
        let calls: [(String, [String: Value])] = [
            ("get_messages", ["chat_id": "chat99"]),
            ("get_messages_since", ["since_rowid": 0, "chat_id": "chat99"]),
            ("get_context", ["chat_id": "chat99", "contains": "trip"]),
            ("list_attachments", ["chat_id": "chat99"]),
            ("get_unread", ["chat_id": "chat99"]),
            ("get_chat_details", ["chat_id": "chat99"]),
            ("search", ["query": "trip", "in_chat": "chat99"]),
            ("search", ["query": "trip", "in_chat": "no-such-guid"]),
            ("get_messages_since", ["since_rowid": 0, "chat_id": "no-such-guid"]),
        ]
        for (tool, args) in calls {
            let json = try await callTool(tool, args, database: fixture.database())
            XCTAssertEqual(json["error"] as? String, "chat_not_found", "\(tool) \(args)")
        }
    }

    /// A GUID substring names one chat, the most recently active match, in
    /// search's in_chat and in get_chat_details.
    func testGuidSubstringNamesOneChatInEveryTool() async throws {
        let fixture = try twoTripChatsFixture()
        let search = try await callTool("search", ["query": "trip", "in_chat": "chat-trip"], database: fixture.database())
        let chats = try decodeJSONArray(search["results"]).compactMap { ($0["chat"] as? [String: Any])?["id"] as? String }
        XCTAssertEqual(chats, ["chat2"])

        let details = try await callTool("get_chat_details", ["chat_id": "chat-trip-old"], database: fixture.database())
        XCTAssertEqual((details["chat"] as? [String: Any])?["id"] as? String, "chat1")
    }

    func testGuidSubstringResolvesToTheMostRecentlyActiveChat() async throws {
        let fixture = try ToolTestDatabase(name: "guid-pick")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        let base = AppleTime.fromDate(Date()) - 60 * appleMinute
        for (chat, minute) in [(1, 2), (2, 3), (3, 1)] {
            try fixture.insertChat(rowId: chat, guid: "iMessage;+;shared-guid-\(chat)")
            try fixture.joinChatHandle(chatId: chat, handleId: 1)
            try fixture.insertMessage(rowId: chat, guid: "D\(chat)", text: "m\(chat)", date: base + Int64(minute) * appleMinute, isFromMe: true)
            try fixture.joinChatMessage(chatId: chat, messageId: chat)
        }
        let page = try await callTool("get_messages", ["chat_id": "shared-guid"], database: fixture.database())
        XCTAssertEqual((page["chat"] as? [String: Any])?["id"] as? String, "chat2")
    }

    /// An unreadable database is reported as such, not as chat_not_found.
    func testChatIdLookupDoesNotHideDatabaseErrors() async throws {
        let missing = Database(path: "/nonexistent/\(UUID().uuidString)/chat.db")
        let tool = GetMessagesTool(db: missing, resolver: ContactResolver(seedCache: [:]))
        do {
            _ = try await tool.execute(args: ["chat_id": "iMessage;-;+1555"])
            XCTFail("expected the database error")
        } catch let failure as ToolFailure {
            XCTAssertNotEqual(failure.code, "chat_not_found")
        } catch {
            XCTAssertTrue(error is DatabaseError, "\(error)")
        }
    }
}
