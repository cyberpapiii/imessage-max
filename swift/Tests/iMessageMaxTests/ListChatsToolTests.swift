import XCTest
@testable import iMessageMax

final class ListChatsToolTests: XCTestCase {
    func testCursorPageSkipsTotalsQuery() async throws {
        let fixture = try ToolTestDatabase(name: "list-chats-totals")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        for chatId in 1...3 {
            try fixture.insertChat(rowId: chatId, guid: "list-chat-\(chatId)", displayName: "Chat \(chatId)")
            try fixture.joinChatHandle(chatId: chatId, handleId: 1)
            try fixture.insertMessage(
                rowId: chatId,
                guid: "list-msg-\(chatId)",
                text: "hello \(chatId)",
                date: Int64(chatId) * 1_000_000_000,
                isFromMe: false,
                handleId: 1
            )
            try fixture.joinChatMessage(chatId: chatId, messageId: chatId)
        }

        func run(cursor: String?) async throws -> ListChatsResponse {
            let result = await ListChatsTool.execute(
                limit: 1,
                sort: "recent",
                cursor: cursor,
                db: fixture.database(),
                resolver: ContactResolver(seedCache: [:])
            )
            switch result {
            case .success(let response):
                return response
            case .failure(let error):
                XCTFail("list_chats failed: \(error)")
                throw XCTSkip("list_chats failed")
            }
        }

        Database.queryCountForTesting = 0
        let first = try await run(cursor: nil)
        let firstCount = try XCTUnwrap(Database.queryCountForTesting)
        XCTAssertNotNil(first.totalChats)
        XCTAssertNotNil(first.cursor)

        Database.queryCountForTesting = 0
        defer { Database.queryCountForTesting = nil }
        let second = try await run(cursor: first.cursor)
        let secondCount = try XCTUnwrap(Database.queryCountForTesting)
        XCTAssertNil(second.totalChats)
        XCTAssertNil(second.totalGroups)
        XCTAssertNil(second.totalDms)
        XCTAssertLessThanOrEqual(secondCount, firstCount - 1, "cursor page \(secondCount) first page \(firstCount)")
    }

    func testMoreIsFalseWhenNoCursorCanBeIssued() async throws {
        let fixture = try ToolTestDatabase(name: "list-chats-null-tail")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        // Three chats, no messages: every last_message_date is NULL, so the
        // keyset cursor cannot address the next page.
        for chatId in 1...3 {
            try fixture.insertChat(rowId: chatId, guid: "null-tail-\(chatId)", displayName: "Chat \(chatId)")
            try fixture.joinChatHandle(chatId: chatId, handleId: 1)
        }

        let result = await ListChatsTool.execute(
            limit: 1,
            sort: "recent",
            db: fixture.database(),
            resolver: ContactResolver(seedCache: [:])
        )
        guard case .success(let page) = result else {
            return XCTFail("list_chats failed: \(result)")
        }
        XCTAssertEqual(page.chats.count, 1)
        // The contract: more and cursor agree. At 639529e this is
        // more == true, cursor == nil.
        XCTAssertEqual(page.more, page.cursor != nil,
                       "more=\(page.more) cursor=\(String(describing: page.cursor))")
    }
}
