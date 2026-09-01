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
}
