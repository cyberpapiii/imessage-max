import XCTest
@testable import iMessageMax

/// Characterization tests for the recent sort's bounded candidate scan.
///
/// The recent sort no longer aggregates every message in the database. It
/// groups a date-ordered prefix of the newest messages into candidate chats and
/// widens that prefix only when the page comes back short. These tests pin the
/// behavior that has to survive that shortcut: the same ordering, no chat lost
/// because it fell outside the prefix, and no chat repeated across pages.
final class ListChatsRecentScanTests: XCTestCase {

    /// Apple epoch nanoseconds for midnight, `offset` days after 2020-01-05.
    private static func day(_ offset: Int) -> Int64 {
        let base: Int64 = 600_000_000  // 2020-01-05T00:00:00Z in Apple seconds
        return (base + Int64(offset) * 86_400) * 1_000_000_000
    }

    private func ids(_ response: ListChatsResponse) -> [String] {
        response.chats.map(\.id)
    }

    private func run(
        fixture: ToolTestDatabase,
        limit: Int = 20,
        isGroup: Bool? = nil,
        cursor: String? = nil
    ) async throws -> ListChatsResponse {
        let result = await ListChatsTool.execute(
            limit: limit,
            isGroup: isGroup,
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

    func testRecentSortOrdersChatsByTheirNewestMessage() async throws {
        let fixture = try ToolTestDatabase()
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")

        for (index, chatId) in [10, 11, 12].enumerated() {
            try fixture.insertChat(rowId: chatId, guid: "chat-\(chatId)", displayName: "Chat \(chatId)")
            try fixture.joinChatHandle(chatId: chatId, handleId: 1)
            let messageId = 100 + index
            try fixture.insertMessage(
                rowId: messageId,
                guid: "msg-\(messageId)",
                text: "hello",
                date: Self.day(index),
                isFromMe: false,
                handleId: 1
            )
            try fixture.joinChatMessage(chatId: chatId, messageId: messageId)
        }

        let response = try await run(fixture: fixture)
        XCTAssertEqual(ids(response), ["chat12", "chat11", "chat10"])
    }

    func testChatOutsideTheCandidatePrefixIsStillFound() async throws {
        // The busy chat owns every message in the first candidate width, so a
        // scan that stopped there would report that no group chat exists.
        let fixture = try ToolTestDatabase()
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertHandle(rowId: 2, handle: "+15550000002")

        try fixture.insertChat(rowId: 10, guid: "chat-10", displayName: "Busy DM")
        try fixture.joinChatHandle(chatId: 10, handleId: 1)
        try fixture.insertChat(rowId: 11, guid: "chat-11", displayName: "Quiet Group")
        try fixture.joinChatHandle(chatId: 11, handleId: 1)
        try fixture.joinChatHandle(chatId: 11, handleId: 2)

        // The group's messages are the oldest in the database, so they sort
        // behind the entire first candidate width of 2000.
        for messageId in 1...3 {
            try fixture.insertMessage(
                rowId: messageId,
                guid: "msg-\(messageId)",
                text: "group",
                date: Self.day(0) + Int64(messageId),
                isFromMe: false,
                handleId: 2
            )
            try fixture.joinChatMessage(chatId: 11, messageId: messageId)
        }
        for messageId in 100..<2_600 {
            try fixture.insertMessage(
                rowId: messageId,
                guid: "msg-\(messageId)",
                text: "dm",
                date: Self.day(1) + Int64(messageId),
                isFromMe: false,
                handleId: 1
            )
            try fixture.joinChatMessage(chatId: 10, messageId: messageId)
        }

        let response = try await run(fixture: fixture, isGroup: true)
        XCTAssertEqual(ids(response), ["chat11"])
    }

    func testPagingDoesNotRepeatAChatWithMessagesOnBothSidesOfTheCursor() async throws {
        // The newest chat also holds a message older than every other chat's.
        // Narrowing the scan by the cursor would truncate that chat's newest
        // date to the old message and hand it back on the second page.
        let fixture = try ToolTestDatabase()
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")

        for chatId in [10, 11, 12, 13] {
            try fixture.insertChat(rowId: chatId, guid: "chat-\(chatId)", displayName: "Chat \(chatId)")
            try fixture.joinChatHandle(chatId: chatId, handleId: 1)
        }

        let messages: [(Int, Int, Int64)] = [
            (1, 10, Self.day(9)),   // newest overall
            (2, 10, Self.day(1)),   // older than every other chat's newest
            (3, 11, Self.day(5)),
            (4, 12, Self.day(3)),
            // Older than the straddling chat's old message, so the page that
            // would repeat chat10 still comes back full and is never widened.
            (5, 13, Self.day(0)),
        ]
        for (messageId, chatId, date) in messages {
            try fixture.insertMessage(
                rowId: messageId,
                guid: "msg-\(messageId)",
                text: "hello",
                date: date,
                isFromMe: false,
                handleId: 1
            )
            try fixture.joinChatMessage(chatId: chatId, messageId: messageId)
        }

        // A single-chat page is what exposes the hazard: each page comes back
        // full, so a scan narrowed by the cursor would never widen and correct
        // itself, and the straddling chat would be handed out a second time
        // once the cursor moved past its older message.
        var seen: [String] = []
        var cursor: String? = nil
        for _ in 0..<10 {
            let page = try await run(fixture: fixture, limit: 1, cursor: cursor)
            seen.append(contentsOf: ids(page))
            guard page.more, let next = page.cursor else { break }
            cursor = next
        }

        XCTAssertEqual(seen, ["chat10", "chat11", "chat12", "chat13"])
    }
}
