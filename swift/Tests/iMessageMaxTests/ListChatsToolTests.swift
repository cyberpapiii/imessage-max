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

    func testLastMessagePreviewDescribesGroupEvents() async throws {
        let fixture = try ToolTestDatabase(name: "list-chats-group-events")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertHandle(rowId: 2, handle: "+15550000002")

        try fixture.insertChat(rowId: 10, guid: "list-rename", displayName: "Rename Chat")
        try fixture.joinChatHandle(chatId: 10, handleId: 1)
        try fixture.joinChatHandle(chatId: 10, handleId: 2)
        try fixture.insertMessage(
            rowId: 100,
            guid: "list-rename-msg",
            text: nil,
            date: 2_000_000_000_000,
            isFromMe: false,
            handleId: 1,
            itemType: 2,
            groupActionType: 0,
            groupTitle: "Trip"
        )
        try fixture.joinChatMessage(chatId: 10, messageId: 100)

        try fixture.insertChat(rowId: 11, guid: "list-added", displayName: "Added Chat")
        try fixture.joinChatHandle(chatId: 11, handleId: 1)
        try fixture.joinChatHandle(chatId: 11, handleId: 2)
        try fixture.insertMessage(
            rowId: 101,
            guid: "list-added-msg",
            text: nil,
            date: 1_000_000_000_000,
            isFromMe: false,
            handleId: 1,
            itemType: 1,
            groupActionType: 0,
            otherHandle: 2
        )
        try fixture.joinChatMessage(chatId: 11, messageId: 101)

        let result = await ListChatsTool.execute(
            limit: 5,
            sort: "recent",
            cursor: nil,
            db: fixture.database(),
            resolver: ContactResolver(seedCache: [:])
        )
        guard case .success(let page) = result else {
            return XCTFail("list_chats failed: \(result)")
        }

        let renameChat = try XCTUnwrap(page.chats.first(where: { $0.id == "chat10" }))
        XCTAssertEqual(renameChat.lastMessage?.text, "renamed the group to Trip")
        XCTAssertEqual(renameChat.lastMessage?.from, PhoneUtils.formatDisplay("+15550000001"))

        let addedChat = try XCTUnwrap(page.chats.first(where: { $0.id == "chat11" }))
        XCTAssertEqual(
            addedChat.lastMessage?.text,
            "added \(PhoneUtils.formatDisplay("+15550000002"))"
        )
    }

    func testFilteredChatsAreHiddenByDefault() async throws {
        let fixture = try ToolTestDatabase(name: "list-chats-filtered")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        let now = Int64(Date().timeIntervalSinceReferenceDate * 1_000_000_000)
        let filters = [0, 1, 36]
        for (index, isFiltered) in filters.enumerated() {
            let chatId = index + 1
            try fixture.insertChat(
                rowId: chatId,
                guid: "filtered-chat-\(chatId)",
                displayName: "Filtered \(chatId)",
                isFiltered: isFiltered
            )
            try fixture.joinChatHandle(chatId: chatId, handleId: 1)
            try fixture.insertMessage(
                rowId: chatId,
                guid: "filtered-msg-\(chatId)",
                text: "hello \(chatId)",
                date: now + Int64(chatId) * 1_000_000_000,
                isFromMe: false,
                handleId: 1
            )
            try fixture.joinChatMessage(chatId: chatId, messageId: chatId)
        }

        let hidden = await ListChatsTool.execute(
            limit: 10,
            sort: "recent",
            db: fixture.database(),
            resolver: ContactResolver(seedCache: [:])
        )
        guard case .success(let defaultResponse) = hidden else {
            return XCTFail("list_chats failed: \(hidden)")
        }
        XCTAssertEqual(defaultResponse.chats.map(\.id), ["chat1"])
        XCTAssertEqual(defaultResponse.filteredHidden, 2)
        XCTAssertEqual(defaultResponse.totalChats, 1)

        let shown = await ListChatsTool.execute(
            limit: 10,
            sort: "recent",
            includeFiltered: true,
            db: fixture.database(),
            resolver: ContactResolver(seedCache: [:])
        )
        guard case .success(let included) = shown else {
            return XCTFail("list_chats include_filtered failed: \(shown)")
        }
        XCTAssertEqual(Set(included.chats.map(\.id)), Set(["chat1", "chat2", "chat3"]))
        XCTAssertNil(included.filteredHidden)
    }
}
