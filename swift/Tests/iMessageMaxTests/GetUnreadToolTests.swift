import MCP
import XCTest
@testable import iMessageMax

final class GetUnreadToolTests: XCTestCase {
    func testSummaryReportsMoreWhenTruncated() async throws {
        let fixture = try ToolTestDatabase(name: "unread-more")
        let base = AppleTime.fromDate(Date().addingTimeInterval(-3600))
        let sec: Int64 = 1_000_000_000

        for index in 1...6 {
            try fixture.insertHandle(rowId: index, handle: "+1555000000\(index)")
            try fixture.insertChat(rowId: index, guid: "unread-chat-\(index)", displayName: "Chat \(index)")
            try fixture.joinChatHandle(chatId: index, handleId: index)
            try fixture.insertMessage(
                rowId: index,
                guid: "unread-msg-\(index)",
                text: "unread \(index)",
                date: base + Int64(index) * sec,
                isFromMe: false,
                isRead: false,
                handleId: index
            )
            try fixture.joinChatMessage(chatId: index, messageId: index)
        }

        let tool = GetUnread(database: fixture.database(), contactResolver: makeSeededResolver())
        let responseAny = try await tool.execute(
            params: GetUnread.Parameters(since: "all", format: .summary, limit: 5)
        )
        let response = try XCTUnwrap(responseAny as? UnreadSummaryResponse)
        XCTAssertEqual(response.chats.count, 5)
        XCTAssertTrue(response.more)
    }

    func testChatNotFoundErrorIsValidJSON() async throws {
        let fixture = try ToolTestDatabase(name: "unread-badid")
        let tool = GetUnread(database: fixture.database(), contactResolver: makeSeededResolver())
        let hostile = "abc\"\\def"
        do {
            _ = try await tool.execute(
                params: GetUnread.Parameters(chatId: hostile, since: "all", format: .summary, limit: 5)
            )
            XCTFail("expected ToolFailure")
        } catch let error as ToolFailure {
            guard case .text(let text, _, _)? = error.content.first else {
                return XCTFail("expected text content")
            }
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            )
            XCTAssertEqual(object["error"] as? String, "chat_not_found")
            XCTAssertEqual(object["message"] as? String, ClientErrorMessages.chatNotFound(hostile))
        }
    }

    func testFilteredChatsAreHiddenByDefault() async throws {
        let fixture = try filteredChatsFixture()

        let tool = GetUnread(database: fixture.database(), contactResolver: makeSeededResolver())

        let summaryHiddenAny = try await tool.execute(
            params: GetUnread.Parameters(since: "all", format: .summary, limit: 5)
        )
        let summaryHidden = try XCTUnwrap(summaryHiddenAny as? UnreadSummaryResponse)
        XCTAssertEqual(summaryHidden.chats.count, 1)
        XCTAssertEqual(summaryHidden.totalUnread, 1)
        XCTAssertEqual(summaryHidden.chatsWithUnread, 1)
        XCTAssertEqual(summaryHidden.filteredHidden, 2)

        let summaryShownAny = try await tool.execute(
            params: GetUnread.Parameters(since: "all", format: .summary, limit: 5, includeFiltered: true)
        )
        let summaryShown = try XCTUnwrap(summaryShownAny as? UnreadSummaryResponse)
        XCTAssertEqual(summaryShown.chats.count, 3)
        XCTAssertEqual(summaryShown.totalUnread, 3)
        XCTAssertNil(summaryShown.filteredHidden)

        let messagesHiddenAny = try await tool.execute(
            params: GetUnread.Parameters(since: "all", format: .messages, limit: 5)
        )
        let messagesHidden = try XCTUnwrap(messagesHiddenAny as? UnreadMessagesResponse)
        XCTAssertEqual(messagesHidden.messages.count, 1)
        XCTAssertEqual(messagesHidden.totalUnread, 1)
        XCTAssertEqual(messagesHidden.chatsWithUnread, 1)
        XCTAssertEqual(messagesHidden.filteredHidden, 2)

        let messagesShownAny = try await tool.execute(
            params: GetUnread.Parameters(since: "all", format: .messages, limit: 5, includeFiltered: true)
        )
        let messagesShown = try XCTUnwrap(messagesShownAny as? UnreadMessagesResponse)
        XCTAssertEqual(messagesShown.messages.count, 3)
        XCTAssertEqual(messagesShown.totalUnread, 3)
        XCTAssertNil(messagesShown.filteredHidden)
    }

    func testTotalsCountEveryChatNotJustThePage() async throws {
        let fixture = try ToolTestDatabase(name: "unread-totals")
        let base = AppleTime.fromDate(Date()) - 60 * appleMinute
        var row = 0
        for (chat, unread) in [(1, 3), (2, 2), (3, 1)] {
            try fixture.insertHandle(rowId: chat, handle: "+1555000000\(chat)")
            try fixture.insertChat(rowId: chat, guid: "iMessage;-;\(chat)")
            try fixture.joinChatHandle(chatId: chat, handleId: chat)
            for _ in 0..<unread {
                row += 1
                try fixture.insertMessage(rowId: row, guid: "U\(row)", text: "u\(row)", date: base + Int64(row) * appleMinute, isFromMe: false, handleId: chat)
                try fixture.joinChatMessage(chatId: chat, messageId: row)
            }
        }

        let summary = try await callTool("get_unread", ["format": "summary", "limit": 1], database: fixture.database())
        let messages = try await callTool("get_unread", ["format": "messages", "limit": 1], database: fixture.database())
        XCTAssertEqual(try decodeJSONArray(summary["chats"]).count, 1)
        for page in [summary, messages] {
            XCTAssertEqual(page["total_unread"] as? Int, 6)
            XCTAssertEqual(page["chats_with_unread"] as? Int, 3)
            XCTAssertEqual(page["more"] as? Bool, true)
        }
    }

    func testMessagesPageWithACursorToTheNewest() async throws {
        let fixture = try directChatFixture(name: "unread-cursor")
        let recent = AppleTime.fromDate(Date().addingTimeInterval(-3600))
        for row in 1...5 {
            try fixture.insertMessage(rowId: row, guid: "g\(row)", text: "u\(row)", date: recent + Int64(row), isFromMe: false, handleId: 1)
            try fixture.joinChatMessage(chatId: 1, messageId: row)
        }

        var seen: [String] = []
        var cursor: String?
        for page in 0..<3 {
            var args: [String: Value] = ["format": "messages", "limit": 2]
            if let cursor { args["cursor"] = .string(cursor) }
            let json = try await callTool("get_unread", args, database: fixture.database())
            seen += try itemIds(json, "messages")
            cursor = json["cursor"] as? String
            XCTAssertEqual(json["more"] as? Bool, cursor != nil)
            XCTAssertEqual(json["total_unread"] as? Int, 5, "every page reports the whole total")
            XCTAssertEqual(cursor == nil, page == 2)
        }
        XCTAssertEqual(seen, (1...5).map { "msg_\($0)" })
    }

    func testMessagesListAMessageInTwoChatsOnceAcrossPages() async throws {
        let fixture = try messageInTwoChatsFixture()
        for limit in 1...3 {
            let seen = try await collectPages(
                "get_unread", ["format": "messages", "limit": .int(limit)], resultsKey: "messages", database: fixture.database()
            )
            XCTAssertEqual(seen.ids, ["msg_1", "msg_2", "msg_3"], "limit \(limit)")
        }
        let one = try await callTool("get_unread", ["format": "messages"], database: fixture.database())
        XCTAssertEqual(try itemChatIds(one, "messages"), ["chat1", "chat1", "chat1"])
    }

    func testFilteredHiddenIsCountedOnTheFirstPageOnly() async throws {
        let fixture = try hiddenChatFixture()
        let newest = AppleTime.fromDate(Date()) - 60 * appleMinute + 2
        try fixture.insertMessage(rowId: 3, guid: "g3", text: "again", date: newest, isFromMe: false, handleId: 1)
        try fixture.joinChatMessage(chatId: 1, messageId: 3)

        let first = try await callTool("get_unread", ["format": "messages", "limit": 1], database: fixture.database())
        XCTAssertEqual(first["filtered_hidden"] as? Int, 1)
        let cursor = try XCTUnwrap(first["cursor"] as? String)
        let second = try await callTool(
            "get_unread", ["format": "messages", "limit": 1, "cursor": .string(cursor)], database: fixture.database()
        )
        XCTAssertEqual(try itemIds(second, "messages"), ["msg_3"])
        XCTAssertNil(second["filtered_hidden"])
    }

    func testSummaryCountsAMessageInTwoChatsOnce() async throws {
        let fixture = try messageInTwoChatsFixture()
        let db = fixture.database()

        let summary = try await callTool("get_unread", [:], database: db)
        XCTAssertEqual(try itemChatIds(summary, "chats"), ["chat1"])
        let chats = try decodeJSONArray(summary["chats"])
        XCTAssertEqual(chats.first?["unread_count"] as? Int, 3)
        XCTAssertEqual(summary["total_unread"] as? Int, 3)
        XCTAssertEqual(summary["chats_with_unread"] as? Int, 1)

        let messages = try await callTool("get_unread", ["format": "messages"], database: db)
        XCTAssertEqual(try itemChatIds(messages, "messages"), ["chat1", "chat1", "chat1"])
        XCTAssertEqual(messages["total_unread"] as? Int, 3)
        XCTAssertEqual(messages["chats_with_unread"] as? Int, 1)

        let second = try await callTool("get_unread", ["chat_id": "chat2"], database: db)
        XCTAssertEqual(try decodeJSONArray(second["chats"]).first?["unread_count"] as? Int, 1)
        XCTAssertEqual(second["total_unread"] as? Int, 1)
        XCTAssertEqual(second["chats_with_unread"] as? Int, 1)
    }
}
