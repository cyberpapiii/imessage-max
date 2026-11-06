import XCTest
import MCP
@testable import iMessageMax

final class GetMessagesSinceToolTests: XCTestCase {
    private let base: Int64 = 1_000_000_000_000

    private func date(_ rowid: Int) -> Int64 {
        base + Int64(rowid) * 1_000_000_000
    }

    private func makeSinceFixture() throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "messages-since")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertHandle(rowId: 2, handle: "+15550000002")
        try fixture.insertHandle(rowId: 3, handle: "+15550000003")

        try fixture.insertChat(rowId: 1, guid: "iMessage;-;+15550000001", displayName: nil)
        try fixture.joinChatHandle(chatId: 1, handleId: 1)

        try fixture.insertChat(rowId: 2, guid: "iMessage;-;group", displayName: "Weekend")
        try fixture.joinChatHandle(chatId: 2, handleId: 1)
        try fixture.joinChatHandle(chatId: 2, handleId: 2)

        try fixture.insertChat(rowId: 3, guid: "SMS;-;90210", displayName: nil, isFiltered: 1)
        try fixture.joinChatHandle(chatId: 3, handleId: 3)

        try fixture.insertMessage(rowId: 100, guid: "s-100", text: "one", date: date(100), isFromMe: false, handleId: 1)
        try fixture.joinChatMessage(chatId: 1, messageId: 100)
        try fixture.insertMessage(rowId: 101, guid: "s-101", text: "two", date: date(101), isFromMe: true)
        try fixture.joinChatMessage(chatId: 1, messageId: 101)
        try fixture.insertMessage(
            rowId: 102, guid: "s-102", text: nil, date: date(102), isFromMe: false, handleId: 1,
            associatedMessageType: 2000, associatedMessageGuid: "s-100"
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 102)
        try fixture.insertMessage(rowId: 103, guid: "s-103", text: "three", date: date(103), isFromMe: false, handleId: 2)
        try fixture.joinChatMessage(chatId: 2, messageId: 103)
        try fixture.insertMessage(rowId: 104, guid: "s-104", text: "junk", date: date(104), isFromMe: false, handleId: 3)
        try fixture.joinChatMessage(chatId: 3, messageId: 104)
        try fixture.insertMessage(rowId: 105, guid: "s-105", text: "orphan", date: date(105), isFromMe: false, handleId: 1)
        try fixture.insertMessage(rowId: 106, guid: "s-106", text: "four", date: date(106), isFromMe: false, handleId: 1)
        try fixture.joinChatMessage(chatId: 2, messageId: 106)
        try fixture.insertMessage(
            rowId: 107, guid: "s-107", text: "https://example.com", date: date(107), isFromMe: false, handleId: 1,
            balloonBundleId: BalloonBundle.urlPreview
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 107)
        return fixture
    }

    func testReturnsMessagesAfterCursorInRowidOrder() async throws {
        let fixture = try makeSinceFixture()
        let tool = GetMessagesSinceTool(db: fixture.database(), resolver: makeSeededResolver())
        let result = try await tool.execute(args: ["since_rowid": .int(100), "limit": .int(50)])
        let json = try decodeJSONDictionary(from: result)
        let messages = try decodeJSONArray(json["messages"])
        XCTAssertEqual(messages.map { $0["id"] as? String }, ["msg_101", "msg_103", "msg_106", "msg_107"])
        XCTAssertEqual(json["has_more"] as? Bool, false)
    }

    func testLinksAreCappedAtTenLikeGetMessages() async throws {
        let fixture = try makeSinceFixture()
        let text = (1...12).map { "https://l\($0).example.com" }.joined(separator: " ")
        try fixture.insertMessage(rowId: 108, guid: "s-108", text: text, date: date(108), isFromMe: false, handleId: 1)
        try fixture.joinChatMessage(chatId: 1, messageId: 108)
        let tool = GetMessagesSinceTool(db: fixture.database(), resolver: makeSeededResolver())
        let json = try decodeJSONDictionary(from: try await tool.execute(args: ["since_rowid": .int(107)]))
        let message = try XCTUnwrap(try decodeJSONArray(json["messages"]).first)
        XCTAssertEqual((message["links"] as? [String])?.count, 10)
        XCTAssertEqual((message["links"] as? [String])?.last, "https://l10.example.com")
    }

    func testOmittedCursorReturnsCurrentRowidOnly() async throws {
        let fixture = try makeSinceFixture()
        let tool = GetMessagesSinceTool(db: fixture.database(), resolver: makeSeededResolver())
        let json = try decodeJSONDictionary(from: try await tool.execute(args: [:]))
        XCTAssertEqual(try decodeJSONArray(json["messages"]).count, 0)
        XCTAssertEqual(json["next_rowid"] as? Int, 107)
        XCTAssertEqual(json["current_rowid"] as? Int, 107)
        XCTAssertEqual(json["has_more"] as? Bool, false)
    }

    func testReactionRowsAreNeverReturnedButReactionsAreAttached() async throws {
        let fixture = try makeSinceFixture()
        let tool = GetMessagesSinceTool(db: fixture.database(), resolver: makeSeededResolver())
        let json = try decodeJSONDictionary(from: try await tool.execute(args: ["since_rowid": .int(99)]))
        let messages = try decodeJSONArray(json["messages"])
        XCTAssertFalse(messages.contains { $0["id"] as? String == "msg_102" })
        let first = try XCTUnwrap(messages.first { $0["id"] as? String == "msg_100" })
        XCTAssertEqual(first["reactions"] as? [String], ["❤️ Alice Smith"])
    }

    func testFilteredChatRowsAreConsumedAndCounted() async throws {
        let fixture = try makeSinceFixture()
        let tool = GetMessagesSinceTool(db: fixture.database(), resolver: makeSeededResolver())
        let first = try decodeJSONDictionary(from: try await tool.execute(args: [
            "since_rowid": .int(103),
            "limit": .int(1),
        ]))
        XCTAssertEqual(try decodeJSONArray(first["messages"]).map { $0["id"] as? String }, ["msg_106"])
        XCTAssertEqual(first["filtered_hidden"] as? Int, 1)
        XCTAssertEqual(first["has_more"] as? Bool, true)
        XCTAssertEqual(first["next_rowid"] as? Int, 106)

        let second = try decodeJSONDictionary(from: try await tool.execute(args: ["since_rowid": .int(106)]))
        XCTAssertEqual(try decodeJSONArray(second["messages"]).map { $0["id"] as? String }, ["msg_107"])
        XCTAssertEqual(second["has_more"] as? Bool, false)
        XCTAssertEqual(second["next_rowid"] as? Int, 107)
    }

    func testIncludeFilteredReturnsJunkChat() async throws {
        let fixture = try makeSinceFixture()
        let tool = GetMessagesSinceTool(db: fixture.database(), resolver: makeSeededResolver())
        let json = try decodeJSONDictionary(from: try await tool.execute(args: [
            "since_rowid": .int(103),
            "include_filtered": .bool(true),
        ]))
        let messages = try decodeJSONArray(json["messages"])
        let junk = try XCTUnwrap(messages.first { $0["id"] as? String == "msg_104" })
        let chat = try XCTUnwrap(junk["chat"] as? [String: Any])
        XCTAssertEqual(chat["id"] as? String, "chat3")
        XCTAssertEqual(json["filtered_hidden"] as? Int, 0)
    }

    func testNextRowidAdvancesPastConsumedTrailingRows() async throws {
        let fixture = try makeSinceFixture()
        try fixture.insertMessage(
            rowId: 108, guid: "s-108", text: nil, date: date(108), isFromMe: false, handleId: 1,
            associatedMessageType: 2000, associatedMessageGuid: "s-107"
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 108)
        try fixture.insertMessage(rowId: 109, guid: "s-109", text: "more junk", date: date(109), isFromMe: false, handleId: 3)
        try fixture.joinChatMessage(chatId: 3, messageId: 109)

        let tool = GetMessagesSinceTool(db: fixture.database(), resolver: makeSeededResolver())
        let json = try decodeJSONDictionary(from: try await tool.execute(args: ["since_rowid": .int(106)]))
        XCTAssertEqual(try decodeJSONArray(json["messages"]).map { $0["id"] as? String }, ["msg_107"])
        XCTAssertEqual(json["next_rowid"] as? Int, 109)
        XCTAssertEqual(json["has_more"] as? Bool, false)
    }

    func testLimitPlusOneDoesNotConsumeTheOverflowRow() async throws {
        let fixture = try makeSinceFixture()
        let tool = GetMessagesSinceTool(db: fixture.database(), resolver: makeSeededResolver())
        let json = try decodeJSONDictionary(from: try await tool.execute(args: [
            "since_rowid": .int(99),
            "limit": .int(2),
        ]))
        XCTAssertEqual(try decodeJSONArray(json["messages"]).map { $0["id"] as? String }, ["msg_100", "msg_101"])
        XCTAssertEqual(json["has_more"] as? Bool, true)
        XCTAssertEqual(json["next_rowid"] as? Int, 101)
    }

    func testYoungUnresolvedRowStallsTheCursor() async throws {
        let fixture = try makeSinceFixture()
        try fixture.insertMessage(
            rowId: 110, guid: "s-110", text: "young orphan",
            date: AppleTime.fromDate(Date()), isFromMe: false, handleId: 1
        )
        let tool = GetMessagesSinceTool(db: fixture.database(), resolver: makeSeededResolver())
        let json = try decodeJSONDictionary(from: try await tool.execute(args: ["since_rowid": .int(107)]))
        XCTAssertEqual(try decodeJSONArray(json["messages"]).count, 0)
        XCTAssertEqual(json["stalled"] as? Bool, true)
        XCTAssertEqual(json["has_more"] as? Bool, true)
        XCTAssertEqual(json["next_rowid"] as? Int, 107)
    }

    func testOldUnresolvedRowIsSkippedAndConsumed() async throws {
        let fixture = try makeSinceFixture()
        let tool = GetMessagesSinceTool(db: fixture.database(), resolver: makeSeededResolver())
        let json = try decodeJSONDictionary(from: try await tool.execute(args: ["since_rowid": .int(104)]))
        XCTAssertEqual(try decodeJSONArray(json["messages"]).map { $0["id"] as? String }, ["msg_106", "msg_107"])
        XCTAssertEqual(json["next_rowid"] as? Int, 107)
        XCTAssertFalse(try decodeJSONArray(json["messages"]).contains { $0["id"] as? String == "msg_105" })
    }

    func testChatFilterRestrictsAndStillAdvances() async throws {
        let fixture = try makeSinceFixture()
        let tool = GetMessagesSinceTool(db: fixture.database(), resolver: makeSeededResolver())
        let json = try decodeJSONDictionary(from: try await tool.execute(args: [
            "since_rowid": .int(99),
            "chat_id": .string("chat2"),
        ]))
        XCTAssertEqual(try decodeJSONArray(json["messages"]).map { $0["id"] as? String }, ["msg_103", "msg_106"])
        XCTAssertEqual(json["next_rowid"] as? Int, 107)
    }

    func testUnresolvableChatIdIsChatNotFound() async throws {
        let fixture = try makeSinceFixture()
        let tool = GetMessagesSinceTool(db: fixture.database(), resolver: makeSeededResolver())
        do {
            _ = try await tool.execute(args: ["chat_id": .string("nope")])
            XCTFail("expected chat_not_found")
        } catch let error as ToolFailure {
            let payload = try decodeJSONDictionary(from: error.content)
            XCTAssertEqual(payload["error"] as? String, "chat_not_found")
        }
    }

    func testLimitIsClamped() async throws {
        let fixture = try makeSinceFixture()
        let tool = GetMessagesSinceTool(db: fixture.database(), resolver: makeSeededResolver())
        func ids(limit: Int) async throws -> [String?] {
            let json = try decodeJSONDictionary(from: try await tool.execute(args: ["since_rowid": .int(99), "limit": .int(limit)]))
            return try decodeJSONArray(json["messages"]).map { $0["id"] as? String }
        }
        let floor = try await ids(limit: 0)
        XCTAssertEqual(floor, ["msg_100"], "limit 0 clamps up to 1")
        let ceiling = try await ids(limit: 9999)
        XCTAssertEqual(ceiling, ["msg_100", "msg_101", "msg_103", "msg_106", "msg_107"])
    }

    /// Reactions, reply counts, attachments and participants are fetched per
    /// page, not per message.
    func testQueryCountDoesNotGrowWithPageSize() async throws {
        let fixture = try makeSinceFixture()
        let tool = GetMessagesSinceTool(db: fixture.database(), resolver: makeSeededResolver())
        let one = try await countQueries {
            _ = try await tool.execute(args: ["since_rowid": .int(99), "limit": .int(1)])
        }
        let five = try await countQueries {
            _ = try await tool.execute(args: ["since_rowid": .int(99), "limit": .int(5)])
        }
        XCTAssertGreaterThan(one, 0)
        XCTAssertEqual(five, one, "a page of 5 ran \(five) queries, a page of 1 ran \(one)")
    }

    // MARK: - Paging, hidden chats and chat filter

    func testFilteredHiddenCountsHiddenChatsNotMessages() async throws {
        let fixture = try hiddenMatchesFixture()
        let page = try await callTool("get_messages_since", ["since_rowid": 0], database: fixture.database())
        XCTAssertEqual(page["filtered_hidden"] as? Int, 2)
        XCTAssertEqual(try itemIds(page, "messages"), ["msg_1"])
    }

    /// A full page whose last kept row is the last row of the batch read
    /// still reports more, and the next page starts right after it.
    func testFullPageEndingOnABatchsLastRowStillReportsMore() async throws {
        let fixture = try ToolTestDatabase(name: "since-full-batch")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
        try fixture.insertChat(rowId: 2, guid: "SMS;-;spam", isFiltered: 1)
        let base: Int64 = 700_000_000_000_000_000
        // limit 31 reads a first batch of 32 rows; one of them is hidden, so
        // the 31st kept row is the batch's last.
        try fixture.insertMessage(rowId: 1, guid: "h", text: "spam", date: base, isFromMe: false, handleId: 1)
        try fixture.joinChatMessage(chatId: 2, messageId: 1)
        for row in 2...40 {
            try fixture.insertMessage(rowId: row, guid: "g\(row)", text: "m\(row)", date: base + Int64(row), isFromMe: false, handleId: 1)
            try fixture.joinChatMessage(chatId: 1, messageId: row)
        }

        let first = try await callTool("get_messages_since", ["since_rowid": 0, "limit": 31], database: fixture.database())
        XCTAssertEqual(try itemIds(first, "messages").count, 31)
        XCTAssertEqual(first["has_more"] as? Bool, true)
        XCTAssertEqual(first["next_rowid"] as? Int, 32)

        let second = try await callTool("get_messages_since", ["since_rowid": 32, "limit": 31], database: fixture.database())
        XCTAssertEqual(try itemIds(second, "messages"), (33...40).map { "msg_\($0)" })
        XCTAssertEqual(second["has_more"] as? Bool, false)
    }

    /// `chat_id` matches a message joined to that chat even when its home
    /// chat is another; unfiltered, the message is listed under its home chat.
    func testChatFilterMatchesAMessageWhoseHomeChatIsAnother() async throws {
        let fixture = try ToolTestDatabase(name: "since-second-chat")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
        try fixture.insertChat(rowId: 2, guid: "SMS;-;+15550000001", serviceName: "SMS")
        try fixture.insertMessage(rowId: 1, guid: "g1", text: "in both", date: 700_000_000_000_000_000, isFromMe: false, handleId: 1)
        try fixture.joinChatMessage(chatId: 1, messageId: 1)
        try fixture.joinChatMessage(chatId: 2, messageId: 1)

        let filtered = try await callTool("get_messages_since", ["since_rowid": 0, "chat_id": "chat2"], database: fixture.database())
        let messages = try decodeJSONArray(filtered["messages"])
        XCTAssertEqual(messages.compactMap { $0["id"] as? String }, ["msg_1"])
        XCTAssertEqual((messages.first?["chat"] as? [String: Any])?["id"] as? String, "chat2")

        let unfiltered = try await callTool("get_messages_since", ["since_rowid": 0], database: fixture.database())
        let home = try decodeJSONArray(unfiltered["messages"]).first?["chat"] as? [String: Any]
        XCTAssertEqual(home?["id"] as? String, "chat1")
    }

    func testMissingReplyAndEditColumnsDegradeToPlainMessages() async throws {
        let fixture = try makeSinceFixture()
        try fixture.execute("ALTER TABLE message DROP COLUMN thread_originator_guid")
        try fixture.execute("ALTER TABLE message DROP COLUMN date_edited")
        try fixture.execute("ALTER TABLE message DROP COLUMN associated_message_emoji")

        let json = try await callTool("get_messages_since", ["since_rowid": 99, "limit": 50], database: fixture.database())
        let messages = try decodeJSONArray(json["messages"])
        XCTAssertEqual(messages.compactMap { $0["id"] as? String }, ["msg_100", "msg_101", "msg_103", "msg_106", "msg_107"])
        for message in messages {
            XCTAssertNil(message["reply_to"])
            XCTAssertNil(message["reply_count"])
            XCTAssertNil(message["edited"])
        }
        let reacted = try XCTUnwrap(messages.first)
        XCTAssertNotNil(reacted["reactions"], "the tapback still attaches without associated_message_emoji: \(reacted)")
    }
}
