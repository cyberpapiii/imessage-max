import Foundation
import MCP
import XCTest
@testable import iMessageMax

final class ListedChatTests: XCTestCase {
    func testEveryToolShowsAHiddenChatNamedById() async throws {
        let fixture = try hiddenChatFixture()
        let db = fixture.database()

        let search = try await callTool("search", ["query": "hello", "in_chat": "chat5"], database: db)
        XCTAssertEqual(try itemIds(search, "results"), ["msg_2"])
        XCTAssertEqual(search["filtered_hidden"] as? Int, 0)

        let unread = try await callTool("get_unread", ["format": "messages", "chat_id": "chat5"], database: db)
        XCTAssertEqual(try itemIds(unread, "messages"), ["msg_2"])
        XCTAssertEqual(unread["total_unread"] as? Int, 1)
        XCTAssertEqual(unread["filtered_hidden"] as? Int, 0)

        let summary = try await callTool("get_unread", ["chat_id": "chat5"], database: db)
        XCTAssertEqual(try decodeJSONArray(summary["chats"]).count, 1)
        XCTAssertEqual(summary["filtered_hidden"] as? Int, 0)

        let since = try await callTool("get_messages_since", ["since_rowid": 0, "chat_id": "chat5"], database: db)
        XCTAssertEqual(try itemIds(since, "messages"), ["msg_2"])
        XCTAssertEqual(since["filtered_hidden"] as? Int, 0)

        let messages = try await callTool("get_messages", ["chat_id": "chat5"], database: db)
        XCTAssertEqual(try itemIds(messages, "messages"), ["msg_2"])

        let all = try await callTool("search", ["query": "hello"], database: db)
        XCTAssertEqual(try itemIds(all, "results"), ["msg_1"])
        XCTAssertEqual(all["filtered_hidden"] as? Int, 1)
        let allSince = try await callTool("get_messages_since", ["since_rowid": 0], database: db)
        XCTAssertEqual(try itemIds(allSince, "messages"), ["msg_1"])
        XCTAssertEqual(allSince["filtered_hidden"] as? Int, 1)
    }

    func testAMessageAlsoInAShownChatIsListedThere() async throws {
        let fixture = try ToolTestDatabase(name: "home-hidden")
        let recent = AppleTime.fromDate(Date()) - 60 * appleMinute
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 1, guid: "SMS;-;+15550000001", serviceName: "SMS", isFiltered: 1)
        try fixture.insertChat(rowId: 2, guid: "iMessage;-;+15550000001")
        try fixture.insertMessage(rowId: 1, guid: "g1", text: "hello \u{FFFC}", date: recent, isFromMe: false, handleId: 1)
        try fixture.joinChatMessage(chatId: 1, messageId: 1)
        try fixture.joinChatMessage(chatId: 2, messageId: 1)
        try fixture.insertAttachment(rowId: 1, filename: "/nonexistent/a.pdf", mimeType: "application/pdf", uti: "com.adobe.pdf")
        try fixture.joinMessageAttachment(messageId: 1, attachmentId: 1)
        let db = fixture.database()

        let since = try await callTool("get_messages_since", ["since_rowid": 0], database: db)
        XCTAssertEqual(try itemChatIds(since, "messages"), ["chat2"])
        XCTAssertEqual(since["filtered_hidden"] as? Int, 0)

        for sort in ["recent_first", "largest_first"] {
            let listed = try await callTool("list_attachments", ["sort": .string(sort)], database: db)
            XCTAssertEqual(try itemChatIds(listed, "messages"), ["chat2"], sort)
        }

        let unread = try await callTool("get_unread", ["format": "messages"], database: db)
        XCTAssertEqual(try itemChatIds(unread, "messages"), ["chat2"])

        let search = try await callTool("search", ["query": "hello"], database: db)
        XCTAssertEqual(try itemChatIds(search, "results"), ["chat2"])

        let included = try await callTool("get_messages_since", ["since_rowid": 0, "include_filtered": true], database: db)
        XCTAssertEqual(try itemChatIds(included, "messages"), ["chat1"])
    }

    func testEveryToolListsAMessageInAHiddenAndAShownChatUnderTheShownOne() async throws {
        let imageURL = try makeFixtureImage(name: "listed-chat-\(UUID().uuidString).jpg", width: 200, height: 100)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let fixture = try ToolTestDatabase(name: "hidden-and-shown")
        let recent = AppleTime.fromDate(Date()) - 60 * appleMinute
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 1, guid: "SMS;-;+15550000001", serviceName: "SMS", isFiltered: 1)
        try fixture.insertChat(rowId: 3, guid: "iMessage;-;+15550000001")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)
        try fixture.joinChatHandle(chatId: 3, handleId: 1)
        try fixture.insertMessage(rowId: 1, guid: "g1", text: "hello there", date: recent, isFromMe: false, handleId: 1)
        try fixture.joinChatMessage(chatId: 1, messageId: 1)
        try fixture.joinChatMessage(chatId: 3, messageId: 1)
        try fixture.insertAttachment(rowId: 7, filename: imageURL.path, mimeType: "image/jpeg", uti: "public.jpeg", transferName: "photo.jpg")
        try fixture.joinMessageAttachment(messageId: 1, attachmentId: 7)
        let db = fixture.database()

        let search = try await callTool("search", ["query": "hello"], database: db)
        XCTAssertEqual(try itemChatIds(search, "results"), ["chat3"])
        let unread = try await callTool("get_unread", ["format": "messages"], database: db)
        XCTAssertEqual(try itemChatIds(unread, "messages"), ["chat3"])

        let context = try await callTool("get_context", ["message_id": "msg_1"], database: db)
        XCTAssertEqual((context["chat"] as? [String: Any])?["id"] as? String, "chat3")

        let image = try await GetAttachment(db: db, resolver: makeSeededResolver()).execute(
            attachmentId: "att7",
            variant: "thumb",
            allowedRoots: [FileManager.default.temporaryDirectory.path]
        )
        XCTAssertEqual(image.metadata.chat?.id, "chat3")
    }

    func testFilteredHiddenKeepsEachToolsShape() async throws {
        let fixture = try indexedHiddenChatFixture()
        let db = fixture.database()

        let since = try await callTool("get_messages_since", ["since_rowid": 0], database: db)
        XCTAssertEqual(since["filtered_hidden"] as? Int, 1)
        let sinceAll = try await callTool(
            "get_messages_since", ["since_rowid": 0, "include_filtered": true], database: db
        )
        XCTAssertEqual(sinceAll["filtered_hidden"] as? Int, 0)
        XCTAssertEqual(try itemIds(sinceAll, "messages").count, 40)

        let find = try await callTool("find_chat", ["contains_recent": "zebra"], database: db)
        XCTAssertEqual(find["filtered_hidden"] as? Int, 1)
        let findAll = try await callTool("find_chat", ["contains_recent": "zebra", "include_filtered": true], database: db)
        XCTAssertNil(findAll["filtered_hidden"])

        let chats = try await callTool("list_chats", [:], database: db)
        XCTAssertEqual(chats["filtered_hidden"] as? Int, 1)
        let chatsAll = try await callTool("list_chats", ["include_filtered": true], database: db)
        XCTAssertNil(chatsAll["filtered_hidden"])
    }
}
