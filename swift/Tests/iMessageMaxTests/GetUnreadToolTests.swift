import XCTest
@testable import iMessageMax

final class GetUnreadToolTests: XCTestCase {
    func testSummaryReportsMoreWhenTruncated() async throws {
        let fixture = try ToolTestDatabase(name: "unread-more")
        let base = Int64(Date().timeIntervalSinceReferenceDate * 1_000_000_000) - 3_600_000_000_000
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
            XCTFail("expected ToolError")
        } catch let error as ToolError {
            guard case .text(let text, _, _)? = error.content.first else {
                return XCTFail("expected text content")
            }
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            )
            XCTAssertEqual(object["error"] as? String, "chat_not_found")
            XCTAssertEqual(object["message"] as? String, "Chat not found: \(hostile)")
        }
    }

    func testFilteredChatsAreHiddenByDefault() async throws {
        let fixture = try ToolTestDatabase(name: "unread-filtered")
        let now = Int64(Date().timeIntervalSinceReferenceDate * 1_000_000_000)
        let filters = [0, 1, 36]
        for (index, isFiltered) in filters.enumerated() {
            let chatId = index + 1
            try fixture.insertHandle(rowId: chatId, handle: "+1555000000\(chatId)")
            try fixture.insertChat(
                rowId: chatId,
                guid: "unread-filtered-\(chatId)",
                displayName: "Unread Filtered \(chatId)",
                isFiltered: isFiltered
            )
            try fixture.joinChatHandle(chatId: chatId, handleId: chatId)
            try fixture.insertMessage(
                rowId: chatId,
                guid: "unread-filtered-msg-\(chatId)",
                text: "unread \(chatId)",
                date: now + Int64(chatId) * 1_000_000_000,
                isFromMe: false,
                isRead: false,
                handleId: chatId
            )
            try fixture.joinChatMessage(chatId: chatId, messageId: chatId)
        }

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
}
