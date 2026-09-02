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

    func testInvalidChatIdIsInvalidInput() async throws {
        let fixture = try makeSinceFixture()
        let tool = GetMessagesSinceTool(db: fixture.database(), resolver: makeSeededResolver())
        do {
            _ = try await tool.execute(args: ["chat_id": .string("nope")])
            XCTFail("expected invalid_input")
        } catch let error as ToolError {
            let payload = try decodeJSONDictionary(from: error.content)
            XCTAssertEqual(payload["error"] as? String, "invalid_input")
        }
    }

    func testLimitIsClamped() {
        XCTAssertEqual(GetMessagesSinceTool.clampLimit(0), 1)
        XCTAssertEqual(GetMessagesSinceTool.clampLimit(9999), 500)
        XCTAssertEqual(GetMessagesSinceTool.clampLimit(nil), 100)
    }

    func testQueryCountIsBounded() async throws {
        let fixture = try makeSinceFixture()
        let tool = GetMessagesSinceTool(db: fixture.database(), resolver: makeSeededResolver())
        Database.queryCountForTesting = 0
        defer { Database.queryCountForTesting = nil }
        _ = try await tool.execute(args: ["since_rowid": .int(99), "limit": .int(5)])
        let count = try XCTUnwrap(Database.queryCountForTesting)
        // MAX(ROWID) + scan + reactions + reply counts + attachments + participants.
        XCTAssertEqual(count, 6, "unexpected query count \(count)")
    }
}
