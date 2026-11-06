import MCP
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

    func testChatsWithNoMessagesPageWithACursor() async throws {
        let fixture = try ToolTestDatabase(name: "list-chats-null-tail")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
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
        XCTAssertEqual(page.more, page.cursor != nil,
                       "more=\(page.more) cursor=\(String(describing: page.cursor))")
        XCTAssertTrue(page.more)
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
        let fixture = try filteredChatsFixture()

        let hidden = try await ListChatsTool.execute(
            limit: 10,
            sort: "recent",
            db: fixture.database(),
            resolver: ContactResolver(seedCache: [:])
        )
        XCTAssertEqual(hidden.chats.map(\.id), ["chat1"])
        XCTAssertEqual(hidden.filteredHidden, 2)
        XCTAssertEqual(hidden.totalChats, 1)

        let shown = try await ListChatsTool.execute(
            limit: 10,
            sort: "recent",
            includeFiltered: true,
            db: fixture.database(),
            resolver: ContactResolver(seedCache: [:])
        )
        XCTAssertEqual(Set(shown.chats.map(\.id)), Set(["chat1", "chat2", "chat3"]))
        XCTAssertNil(shown.filteredHidden)
    }

    func testLastMessagePreviewSkipsHiddenAttachments() async throws {
        let fixture = try directChatFixture(name: "hidden-attachment")
        try fixture.insertMessage(rowId: 1, guid: "IMG", text: "\u{FFFC}", date: AppleTime.fromDate(Date()) - appleMinute, isFromMe: false, handleId: 1)
        try fixture.joinChatMessage(chatId: 1, messageId: 1)
        for id in 1...2 {
            try fixture.insertAttachment(
                rowId: id, filename: "~/Library/Messages/Attachments/\(id).jpeg", mimeType: "image/jpeg",
                uti: "public.jpeg", totalBytes: 10, transferName: "\(id).jpeg", hideAttachment: id == 2
            )
            try fixture.joinMessageAttachment(messageId: 1, attachmentId: id)
        }

        let page = try await callTool("list_chats", [:], database: fixture.database())
        let chat = try XCTUnwrap(try decodeJSONArray(page["chats"]).first)
        XCTAssertEqual((chat["last_message"] as? [String: Any])?["text"] as? String, "[Photo]")
    }

    func testPagesReachChatsWithNoMessages() async throws {
        let fixture = try ToolTestDatabase(name: "list-empty-chats")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        for chat in 1...5 {
            try fixture.insertChat(rowId: chat, guid: "iMessage;+;c\(chat)", displayName: "Chat \(chat)")
            try fixture.joinChatHandle(chatId: chat, handleId: 1)
        }
        for chat in 1...2 {
            try fixture.insertMessage(rowId: chat, guid: "g\(chat)", text: "hi", date: 700_000_000_000_000_000 + Int64(chat), isFromMe: false, handleId: 1)
            try fixture.joinChatMessage(chatId: chat, messageId: chat)
        }
        for sort in ["recent", "most_active"] {
            var seen: [String] = []
            var cursor: String?
            for _ in 0..<6 {
                var args: [String: Value] = ["sort": .string(sort), "limit": 2]
                if let cursor { args["cursor"] = .string(cursor) }
                let json = try await callTool("list_chats", args, database: fixture.database())
                let page = try itemIds(json, "chats")
                XCTAssertFalse(page.isEmpty, "\(sort): an empty page after more:true")
                seen += page
                cursor = json["cursor"] as? String
                XCTAssertEqual(json["more"] as? Bool, cursor != nil)
                if cursor == nil { break }
            }
            XCTAssertEqual(seen, ["chat2", "chat1", "chat5", "chat4", "chat3"], sort)
        }
    }
}
