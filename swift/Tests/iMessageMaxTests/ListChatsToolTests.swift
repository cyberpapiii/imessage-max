import XCTest
@testable import iMessageMax

final class ListChatsToolTests: XCTestCase {
    func testCursorPageOmitsTotals() async throws {
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
            let result = try await ListChatsTool.execute(
                limit: 1,
                sort: "recent",
                cursor: cursor,
                db: fixture.database(),
                resolver: ContactResolver(seedCache: [:])
            )
            return result
        }

        let first = try await run(cursor: nil)
        XCTAssertNotNil(first.totalChats)
        XCTAssertNotNil(first.cursor)

        let second = try await run(cursor: first.cursor)
        XCTAssertEqual(second.chats.count, 1)
        XCTAssertNil(second.totalChats)
        XCTAssertNil(second.totalGroups)
        XCTAssertNil(second.totalDms)
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

        let result = try await ListChatsTool.execute(
            limit: 1,
            sort: "recent",
            db: fixture.database(),
            resolver: ContactResolver(seedCache: [:])
        )
        let page = result
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

        let result = try await ListChatsTool.execute(
            limit: 5,
            sort: "recent",
            cursor: nil,
            db: fixture.database(),
            resolver: ContactResolver(seedCache: [:])
        )
        let page = result

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

        let hidden = try await ListChatsTool.execute(
            limit: 10,
            sort: "recent",
            db: fixture.database(),
            resolver: ContactResolver(seedCache: [:])
        )
        let defaultResponse = hidden
        XCTAssertEqual(defaultResponse.chats.map(\.id), ["chat1"])
        XCTAssertEqual(defaultResponse.filteredHidden, 2)
        XCTAssertEqual(defaultResponse.totalChats, 1)

        let shown = try await ListChatsTool.execute(
            limit: 10,
            sort: "recent",
            includeFiltered: true,
            db: fixture.database(),
            resolver: ContactResolver(seedCache: [:])
        )
        let included = shown
        XCTAssertEqual(Set(included.chats.map(\.id)), Set(["chat1", "chat2", "chat3"]))
        XCTAssertNil(included.filteredHidden)
    }
}
