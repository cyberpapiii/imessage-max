import Foundation
import MCP
import XCTest
@testable import iMessageMax

/// Regression coverage for the still-open product items closed after the thermos sweep:
/// mime `has:` filters, FindChat group/content, most_active + cursors, AsyncTimeout cancel.
final class ProductOpenItemsTests: XCTestCase {

    // MARK: - has:images mime filter

    func testGetMessagesHasImagesFiltersByMimeNotBareJoin() async throws {
        let fixture = try makeHasMediaFixture()
        let tool = GetMessagesTool(db: fixture.database(), resolver: makeSeededResolver())

        let images = try decodeJSONDictionary(from: await tool.execute(args: [
            "chat_id": .string("chat1"),
            "has": .string("images"),
            "limit": .int(20),
        ]))
        let imageMsgs = try decodeJSONArray(try XCTUnwrap(images["messages"]))
        XCTAssertEqual(imageMsgs.map { $0["id"] as? String }, ["msg_2"])

        let attachments = try decodeJSONDictionary(from: await tool.execute(args: [
            "chat_id": .string("chat1"),
            "has": .string("attachments"),
            "limit": .int(20),
        ]))
        let attMsgs = try decodeJSONArray(try XCTUnwrap(attachments["messages"]))
        let ids = Set(attMsgs.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids, ["msg_2", "msg_3"])
    }

    // MARK: - FindChat is_group before LIMIT + attributedBody contains

    func testFindChatIsGroupAppliedInSQLBeforeLimit() async throws {
        let fixture = try makeFindChatGroupFixture()
        let contents = try await FindChatTool.execute(
            arguments: [
                "name": .string("Crew"),
                "is_group": .bool(true),
                "limit": .int(1),
            ],
            database: fixture.database(),
            resolver: makeSeededResolver()
        )
        let payload = try decodeJSONDictionary(from: contents)
        let chats = try decodeJSONArray(try XCTUnwrap(payload["chats"]))
        XCTAssertEqual(chats.count, 1)
        XCTAssertEqual(chats.first?["id"] as? String, "chat2")
        XCTAssertEqual(chats.first?["group"] as? Bool, true)
    }

    func testFindChatContainsRecentMatchesAttributedBody() async throws {
        let fixture = try makeFindChatAttributedFixture()
        let blob = typedstreamBlob(payload: Array("secret volcano hike".utf8))
        // Re-insert message 10 with attributedBody only (nil text).
        try fixture.execute("DELETE FROM message WHERE ROWID = 10;")
        try fixture.execute("DELETE FROM chat_message_join WHERE message_id = 10;")
        try fixture.insertMessage(
            rowId: 10,
            guid: "attr-only",
            text: nil,
            date: 1_000_000_000_000,
            isFromMe: false,
            handleId: 1,
            attributedBody: blob
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 10)

        let contents = try await FindChatTool.execute(
            arguments: [
                "contains_recent": .string("volcano"),
                "limit": .int(5),
            ],
            database: fixture.database(),
            resolver: makeSeededResolver()
        )
        let payload = try decodeJSONDictionary(from: contents)
        let chats = try decodeJSONArray(try XCTUnwrap(payload["chats"]))
        XCTAssertEqual(chats.first?["id"] as? String, "chat1")
    }

    // MARK: - most_active sort + list_chats cursor

    func testListChatsMostActiveOrdersByMessageCount() async throws {
        let fixture = try makeMostActiveFixture()
        let result = await ListChatsTool.execute(
            limit: 10,
            sort: "most_active",
            db: fixture.database(),
            resolver: makeSeededResolver()
        )
        guard case .success(let response) = result else {
            return XCTFail("list_chats failed")
        }
        XCTAssertEqual(response.chats.map(\.id), ["chat2", "chat1"])
    }

    func testListChatsCursorPagesRecent() async throws {
        let fixture = try makeMostActiveFixture()
        let first = await ListChatsTool.execute(
            limit: 1,
            sort: "recent",
            db: fixture.database(),
            resolver: makeSeededResolver()
        )
        guard case .success(let page1) = first else {
            return XCTFail("page1 failed")
        }
        XCTAssertTrue(page1.more)
        XCTAssertNotNil(page1.cursor)
        XCTAssertEqual(page1.chats.count, 1)

        let second = await ListChatsTool.execute(
            limit: 1,
            sort: "recent",
            cursor: page1.cursor,
            db: fixture.database(),
            resolver: makeSeededResolver()
        )
        guard case .success(let page2) = second else {
            return XCTFail("page2 failed")
        }
        XCTAssertEqual(page2.chats.count, 1)
        XCTAssertNotEqual(page1.chats.first?.id, page2.chats.first?.id)
    }

    // MARK: - AsyncTimeout cancellation

    func testAsyncTimeoutSleepHonorsCancellation() async {
        let task = Task {
            await AsyncTimeout.sleep(.seconds(30))
        }
        await AsyncTimeout.sleep(.milliseconds(20))
        task.cancel()
        await task.value
        XCTAssertTrue(task.isCancelled)
    }

    // MARK: - Fixtures

    private func makeHasMediaFixture() throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "has-media")
        let imageURL = try makeFixtureImage(name: "has-image.jpg")

        try fixture.insertHandle(rowId: 1, handle: "+15555550123")
        try fixture.insertChat(rowId: 1, guid: "chat-has-media")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)

        let base: Int64 = 5_000_000_000_000
        try fixture.insertMessage(rowId: 1, guid: "m1", text: "plain", date: base, isFromMe: false, handleId: 1)
        try fixture.joinChatMessage(chatId: 1, messageId: 1)

        try fixture.insertMessage(rowId: 2, guid: "m2", text: "photo", date: base + 1, isFromMe: false, handleId: 1)
        try fixture.joinChatMessage(chatId: 1, messageId: 2)
        try fixture.insertAttachment(
            rowId: 10,
            filename: imageURL.path,
            mimeType: "image/jpeg",
            uti: "public.jpeg",
            totalBytes: 100,
            transferName: "has-image.jpg"
        )
        try fixture.joinMessageAttachment(messageId: 2, attachmentId: 10)

        try fixture.insertMessage(rowId: 3, guid: "m3", text: "doc", date: base + 2, isFromMe: false, handleId: 1)
        try fixture.joinChatMessage(chatId: 1, messageId: 3)
        try fixture.insertAttachment(
            rowId: 11,
            filename: "/tmp/notes.pdf",
            mimeType: "application/pdf",
            uti: "com.adobe.pdf",
            totalBytes: 200,
            transferName: "notes.pdf"
        )
        try fixture.joinMessageAttachment(messageId: 3, attachmentId: 11)

        return fixture
    }

    private func makeFindChatGroupFixture() throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "find-chat-group")
        try fixture.insertHandle(rowId: 1, handle: "+15555550123")
        try fixture.insertHandle(rowId: 2, handle: "+15555550124")

        // DM named similarly — would steal LIMIT 1 if is_group applied after.
        try fixture.insertChat(rowId: 1, guid: "dm", displayName: "Crew Notes")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)

        try fixture.insertChat(rowId: 2, guid: "group", displayName: "Crew Trip")
        try fixture.joinChatHandle(chatId: 2, handleId: 1)
        try fixture.joinChatHandle(chatId: 2, handleId: 2)

        return fixture
    }

    private func makeFindChatAttributedFixture() throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "find-chat-attr")
        try fixture.insertHandle(rowId: 1, handle: "+15555550123")
        try fixture.insertChat(rowId: 1, guid: "attr-chat", displayName: "Hike")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)
        try fixture.insertMessage(
            rowId: 10,
            guid: "placeholder",
            text: "placeholder",
            date: 1_000_000_000_000,
            isFromMe: false,
            handleId: 1
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 10)
        return fixture
    }

    private func makeMostActiveFixture() throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "most-active")
        try fixture.insertHandle(rowId: 1, handle: "+15555550123")
        try fixture.insertHandle(rowId: 2, handle: "+15555550124")

        try fixture.insertChat(rowId: 1, guid: "quiet", displayName: "Quiet")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)

        try fixture.insertChat(rowId: 2, guid: "busy", displayName: "Busy")
        try fixture.joinChatHandle(chatId: 2, handleId: 2)

        let base: Int64 = 6_000_000_000_000
        // Quiet: 1 message, more recent
        try fixture.insertMessage(rowId: 1, guid: "q1", text: "hi", date: base + 100, isFromMe: false, handleId: 1)
        try fixture.joinChatMessage(chatId: 1, messageId: 1)

        // Busy: 3 older messages → most_active first; recent sort puts Quiet first
        for i in 0..<3 {
            let id = 10 + i
            try fixture.insertMessage(
                rowId: id,
                guid: "b\(i)",
                text: "msg\(i)",
                date: base + Int64(i),
                isFromMe: false,
                handleId: 2
            )
            try fixture.joinChatMessage(chatId: 2, messageId: id)
        }
        return fixture
    }

    private func typedstreamBlob(payload: [UInt8]) -> Data {
        var bytes: [UInt8] = [0x04, 0x0B]
        bytes += Array("NSString".utf8)
        bytes += [0x01, 0x94, 0x84, 0x01, 0x2B]
        bytes += [UInt8(payload.count)]
        bytes += payload
        return Data(bytes)
    }
}
