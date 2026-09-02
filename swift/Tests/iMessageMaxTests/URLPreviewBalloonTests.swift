import XCTest
@testable import iMessageMax

final class URLPreviewBalloonTests: XCTestCase {
    private let urlBalloon = BalloonBundle.urlPreview

    /// Chat 1 (DM with +15550000001), one inbound unread link message stored the
    /// way macOS 26 stores it: text NULL, URL in attributedBody, one hidden
    /// pluginPayloadAttachment, balloon_bundle_id set.
    private func makeBalloonFixture() throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "url-balloon")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 1, guid: "iMessage;-;+15550000001", displayName: nil)
        try fixture.joinChatHandle(chatId: 1, handleId: 1)
        let base: Int64 = 1_000_000_000_000
        try fixture.insertMessage(rowId: 700, guid: "m-700", text: "look at this", date: base, isFromMe: false, isRead: true, handleId: 1)
        try fixture.joinChatMessage(chatId: 1, messageId: 700)
        let url = "https://example.com/article"
        let payload = Array(url.utf8)
        try fixture.insertMessage(
            rowId: 701, guid: "m-701", text: nil, date: base + 20_000_000_000,
            isFromMe: false, isRead: false, handleId: 1,
            attributedBody: typedstreamBlob(lengthField: [UInt8(payload.count)], payload: payload),
            balloonBundleId: urlBalloon
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 701)
        try fixture.insertAttachment(
            rowId: 7001, filename: "/Library/Messages/Attachments/aa/01/x.pluginPayloadAttachment",
            mimeType: nil, uti: "dyn.age81a5dzq7y066dbtf0g82peqf4hk2pdrb00n5xy",
            totalBytes: 97_125, transferName: "x.pluginPayloadAttachment", hideAttachment: true
        )
        try fixture.joinMessageAttachment(messageId: 701, attachmentId: 7001)
        return fixture
    }

    private func typedstreamBlob(marker: String = "NSString", lengthField: [UInt8], payload: [UInt8]) -> Data {
        var bytes: [UInt8] = [0x04, 0x0B]
        bytes += Array(marker.utf8)
        bytes += [0x01, 0x94, 0x84, 0x01, 0x2B]
        bytes += lengthField
        bytes += payload
        return Data(bytes)
    }

    func testBalloonRowRendersOnceWithURLAsText() async throws {
        let fixture = try makeBalloonFixture()
        let tool = GetMessagesTool(db: fixture.database(), resolver: makeSeededResolver())
        let response = try decodeJSONDictionary(from: try await tool.execute(args: [
            "chat_id": .string("chat1"),
            "limit": .int(10),
        ]))
        let messages = try decodeJSONArray(response["messages"])
        XCTAssertEqual(messages.count, 2)
        let newest = try XCTUnwrap(messages.first)
        XCTAssertEqual(newest["id"] as? String, "msg_701")
        XCTAssertEqual(newest["text"] as? String, "https://example.com/article")
        XCTAssertEqual(newest["links"] as? [String], ["https://example.com/article"])
    }

    func testBalloonRowCountsOnceInUnread() async throws {
        let fixture = try makeBalloonFixture()
        let tool = GetUnread(database: fixture.database(), contactResolver: makeSeededResolver())
        let summaryAny = try await tool.execute(params: GetUnread.Parameters(since: "all", format: .summary, limit: 10))
        let summary = try XCTUnwrap(summaryAny as? UnreadSummaryResponse)
        XCTAssertEqual(summary.totalUnread, 1)
        XCTAssertEqual(summary.chats.first?.unreadCount, 1)

        let messagesAny = try await tool.execute(params: GetUnread.Parameters(since: "all", format: .messages, limit: 10))
        let messages = try XCTUnwrap(messagesAny as? UnreadMessagesResponse)
        XCTAssertEqual(messages.messages.count, 1)
        XCTAssertEqual(messages.messages.first?.text, "https://example.com/article")
    }

    func testSearchFindsBalloonRowOnce() async throws {
        let fixture = try makeBalloonFixture()
        let json = try decodeSearchResponse(
            await SearchTool.execute(
                query: "example.com",
                db: fixture.database(),
                resolver: makeSeededResolver()
            )
        )
        let results = try decodeJSONArray(json["results"])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?["id"] as? String, "msg_701")
    }

    func testHasLinksReturnsBalloonRow() async throws {
        let fixture = try makeBalloonFixture()
        let tool = GetMessagesTool(db: fixture.database(), resolver: makeSeededResolver())
        let response = try decodeJSONDictionary(from: try await tool.execute(args: [
            "chat_id": .string("chat1"),
            "has": .string("links"),
        ]))
        let messages = try decodeJSONArray(response["messages"])
        XCTAssertEqual(messages.map { $0["id"] as? String }, ["msg_701"])
    }

    func testSearchHasLinkReturnsBalloonRow() async throws {
        let fixture = try makeBalloonFixture()
        let json = try decodeSearchResponse(
            await SearchTool.execute(
                query: "example",
                has: "link",
                db: fixture.database(),
                resolver: makeSeededResolver()
            )
        )
        let results = try decodeJSONArray(json["results"])
        XCTAssertEqual(results.first?["id"] as? String, "msg_701")
    }

    func testHiddenPayloadAttachmentIsNotListedOnMessage() async throws {
        let fixture = try makeBalloonFixture()
        let tool = GetMessagesTool(db: fixture.database(), resolver: makeSeededResolver())
        let response = try decodeJSONDictionary(from: try await tool.execute(args: [
            "chat_id": .string("chat1"),
        ]))
        let messages = try decodeJSONArray(response["messages"])
        let balloon = try XCTUnwrap(messages.first { $0["id"] as? String == "msg_701" })
        XCTAssertNil(balloon["attachments"])
        XCTAssertNil(balloon["media"])
    }

    func testHasAttachmentsIgnoresHiddenPayload() async throws {
        let fixture = try makeBalloonFixture()
        let tool = GetMessagesTool(db: fixture.database(), resolver: makeSeededResolver())
        let response = try decodeJSONDictionary(from: try await tool.execute(args: [
            "chat_id": .string("chat1"),
            "has": .string("attachments"),
        ]))
        let messages = try decodeJSONArray(response["messages"])
        XCTAssertEqual(messages.count, 0)
    }

    func testListAttachmentsSkipsHiddenPayload() async throws {
        let fixture = try makeBalloonFixture()
        let tool = ListAttachments(db: fixture.database(), resolver: makeSeededResolver())
        let result = await tool.execute(chatId: "chat1")
        let response = try result.get()
        XCTAssertEqual(response.messages.count, 0)
    }

    func testVisibleAttachmentOnSameMessageStillListed() async throws {
        let fixture = try makeBalloonFixture()
        let imageURL = try makeFixtureImage(name: "xctest-083-visible.jpg", width: 80, height: 60)
        try fixture.insertAttachment(
            rowId: 7002, filename: imageURL.path,
            mimeType: "image/jpeg", uti: "public.jpeg",
            totalBytes: (try? FileManager.default.attributesOfItem(atPath: imageURL.path)[.size] as? Int) ?? 0,
            transferName: imageURL.lastPathComponent, hideAttachment: false
        )
        try fixture.joinMessageAttachment(messageId: 701, attachmentId: 7002)

        let tool = GetMessagesTool(
            db: fixture.database(),
            resolver: makeSeededResolver(),
            allowedRoots: [FileManager.default.temporaryDirectory.path]
        )
        let response = try decodeJSONDictionary(from: try await tool.execute(args: [
            "chat_id": .string("chat1"),
        ]))
        let messages = try decodeJSONArray(response["messages"])
        let balloon = try XCTUnwrap(messages.first { $0["id"] as? String == "msg_701" })
        XCTAssertNotNil(balloon["media"])
        XCTAssertNil(balloon["attachments"])

        let list = ListAttachments(db: fixture.database(), resolver: makeSeededResolver())
        let listed = try await list.execute(chatId: "chat1").get()
        XCTAssertEqual(listed.messages.count, 1)
        XCTAssertEqual(listed.messages.first?.attachments.first?.id, "att7002")
    }

    func testSearchHasAttachmentIgnoresHiddenPayload() async throws {
        let fixture = try makeBalloonFixture()
        let hidden = try decodeSearchResponse(
            await SearchTool.execute(
                query: "example",
                has: "attachment",
                db: fixture.database(),
                resolver: makeSeededResolver()
            )
        )
        XCTAssertEqual(try decodeJSONArray(hidden["results"]).count, 0)

        try fixture.insertAttachment(
            rowId: 7002, filename: "/tmp/xctest-083-visible.jpg",
            mimeType: "image/jpeg", uti: "public.jpeg",
            totalBytes: 12, hideAttachment: false
        )
        try fixture.joinMessageAttachment(messageId: 701, attachmentId: 7002)
        let visible = try decodeSearchResponse(
            await SearchTool.execute(
                query: "example",
                has: "attachment",
                db: fixture.database(),
                resolver: makeSeededResolver()
            )
        )
        XCTAssertEqual(try decodeJSONArray(visible["results"]).count, 1)
    }
}
