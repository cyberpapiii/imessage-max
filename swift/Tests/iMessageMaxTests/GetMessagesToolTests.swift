import XCTest
import MCP
@testable import iMessageMax

final class GetMessagesToolTests: XCTestCase {
    func testExactChatIdReturnsMessagesAndGeneratedChatName() async throws {
        let fixture = try makeGetMessagesFixture()
        let tool = GetMessagesTool(db: fixture.database(), resolver: makeSeededResolver())

        let response = try await decodeGetMessagesResponse(
            await tool.execute(args: ["chat_id": .string("chat20")])
        )

        let chat = try XCTUnwrap(response["chat"] as? [String: Any])
        XCTAssertEqual(chat["id"] as? String, "chat20")
        let generatedName = try XCTUnwrap(chat["name"] as? String)
        XCTAssertEqual(
            Set(generatedName.components(separatedBy: ", ").filter { !$0.isEmpty }),
            ["Alice Smith", "Bob Brown"]
        )

        let messages = try decodeJSONArray(try XCTUnwrap(response["messages"]))
        XCTAssertEqual(messages.count, 4)
    }

    func testParticipantsResolutionPrefersUniqueGroupMatch() async throws {
        let fixture = try makeGetMessagesFixture()
        let tool = GetMessagesTool(db: fixture.database(), resolver: makeSeededResolver())

        let response = try await decodeGetMessagesResponse(
            await tool.execute(args: [
                "participants": .array([.string("Alice"), .string("Bob")]),
                "limit": .int(10),
            ])
        )

        let chat = try XCTUnwrap(response["chat"] as? [String: Any])
        XCTAssertEqual(chat["id"] as? String, "chat20")
    }

    func testParticipantsResolutionReturnsAmbiguousErrorWhenMultipleChatsMatch() async throws {
        let fixture = try makeGetMessagesFixture()
        let tool = GetMessagesTool(db: fixture.database(), resolver: makeSeededResolver())

        do {
            _ = try await tool.execute(args: [
                "participants": .array([.string("Bob")]),
            ])
            XCTFail("Expected ambiguous participant error")
        } catch let error as ToolError {
            let payload = try decodeJSONDictionary(from: error.content)
            XCTAssertEqual(payload["error"] as? String, "ambiguous_participants")
        }
    }

    func testFromPersonContainsAndHasFiltersWorkTogether() async throws {
        let fixture = try makeGetMessagesFixture()
        let tool = GetMessagesTool(db: fixture.database(), resolver: makeSeededResolver())

        let response = try await decodeGetMessagesResponse(
            await tool.execute(args: [
                "chat_id": .string("chat20"),
                "from_person": .string("Bob"),
                "contains": .string("volcano"),
                "limit": .int(10),
            ])
        )

        let messages = try decodeJSONArray(try XCTUnwrap(response["messages"]))
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["id"] as? String, "msg_200")

        let linksResponse = try await decodeGetMessagesResponse(
            await tool.execute(args: [
                "chat_id": .string("chat20"),
                "has": .string("links"),
                "limit": .int(10),
            ])
        )
        let linkMessages = try decodeJSONArray(try XCTUnwrap(linksResponse["messages"]))
        XCTAssertEqual(linkMessages.count, 1)
        XCTAssertEqual(linkMessages.first?["id"] as? String, "msg_201")
    }

    func testReactionsAndAttachmentMediaSummariesAreIncluded() async throws {
        let fixture = try makeGetMessagesFixture()
        let tool = GetMessagesTool(db: fixture.database(), resolver: makeSeededResolver())

        let response = try await decodeGetMessagesResponse(
            await tool.execute(args: [
                "chat_id": .string("chat20"),
                "limit": .int(10),
            ])
        )

        let messages = try decodeJSONArray(try XCTUnwrap(response["messages"]))
        let target = try XCTUnwrap(messages.first(where: { $0["id"] as? String == "msg_201" }))

        let reactions = try XCTUnwrap(target["reactions"] as? [String])
        XCTAssertEqual(reactions, ["❤️ alice"])

        let media = try decodeJSONArray(target["media"])
        XCTAssertEqual(media.count, 1)
        XCTAssertEqual(media.first?["id"] as? String, "att900")
        XCTAssertEqual(media.first?["type"] as? String, "image")
    }

    func testUnansweredAndSessionFiltersWork() async throws {
        let fixture = try makeGetMessagesFixture()
        let tool = GetMessagesTool(db: fixture.database(), resolver: makeSeededResolver())

        let unanswered = try await decodeGetMessagesResponse(
            await tool.execute(args: [
                "chat_id": .string("chat20"),
                "unanswered": .bool(true),
                "limit": .int(10),
            ])
        )

        let unansweredMessages = try decodeJSONArray(try XCTUnwrap(unanswered["messages"]))
        XCTAssertEqual(unansweredMessages.count, 1)
        XCTAssertEqual(unansweredMessages.first?["id"] as? String, "msg_203")

        let fullResponse = try await decodeGetMessagesResponse(
            await tool.execute(args: [
                "chat_id": .string("chat20"),
                "limit": .int(10),
            ])
        )
        let sessions = try decodeJSONArray(try XCTUnwrap(fullResponse["sessions"]))
        XCTAssertEqual(sessions.count, 2)
        let fullMessages = try decodeJSONArray(try XCTUnwrap(fullResponse["messages"]))
        let sessionStartMessage = try XCTUnwrap(fullMessages.first(where: { $0["id"] as? String == "msg_202" }))
        XCTAssertEqual(sessionStartMessage["session_gap_hours"] as? Double, 16.0)

        let sessionFiltered = try await decodeGetMessagesResponse(
            await tool.execute(args: [
                "chat_id": .string("chat20"),
                "session": .string("session_2"),
                "limit": .int(10),
            ])
        )

        let filteredMessages = try decodeJSONArray(try XCTUnwrap(sessionFiltered["messages"]))
        XCTAssertEqual(Set(filteredMessages.compactMap { $0["id"] as? String }), Set(["msg_202", "msg_203"]))
    }

    func testCursorPaginatesMessages() async throws {
        let fixture = try makeGetMessagesFixture()
        let tool = GetMessagesTool(db: fixture.database(), resolver: makeSeededResolver())

        let firstPage = try await decodeGetMessagesResponse(
            await tool.execute(args: [
                "chat_id": .string("chat20"),
                "limit": .int(1),
            ])
        )

        let firstMessages = try decodeJSONArray(try XCTUnwrap(firstPage["messages"]))
        XCTAssertEqual(firstMessages.count, 1)
        XCTAssertEqual(firstMessages.first?["id"] as? String, "msg_203")
        let cursor = try XCTUnwrap(firstPage["cursor"] as? String)

        let secondPage = try await decodeGetMessagesResponse(
            await tool.execute(args: [
                "chat_id": .string("chat20"),
                "limit": .int(1),
                "cursor": .string(cursor),
            ])
        )

        let secondMessages = try decodeJSONArray(try XCTUnwrap(secondPage["messages"]))
        XCTAssertEqual(secondMessages.count, 1)
        XCTAssertEqual(secondMessages.first?["id"] as? String, "msg_202")
    }
}

private func decodeGetMessagesResponse(_ contents: [Tool.Content]) async throws -> [String: Any] {
    return try decodeJSONDictionary(from: contents)
}

func makeGetMessagesFixture() throws -> ToolTestDatabase {
    let fixture = try ToolTestDatabase(name: "get-messages")
    let imageURL = try makeFixtureImage(name: "message-image.jpg")

    try fixture.insertHandle(rowId: 1, handle: "+15550000001")
    try fixture.insertHandle(rowId: 2, handle: "+15550000002")

    try fixture.insertChat(rowId: 10, guid: "chat-alice-guid", displayName: "Alice DM")
    try fixture.joinChatHandle(chatId: 10, handleId: 1)

    try fixture.insertChat(rowId: 20, guid: "chat-group-guid", displayName: nil)
    try fixture.joinChatHandle(chatId: 20, handleId: 1)
    try fixture.joinChatHandle(chatId: 20, handleId: 2)

    try fixture.insertChat(rowId: 30, guid: "chat-bob-guid", displayName: "Bob DM")
    try fixture.joinChatHandle(chatId: 30, handleId: 2)

    let base: Int64 = 1_000_000_000_000
    let minute: Int64 = 60 * 1_000_000_000
    let sixteenHours: Int64 = 16 * 60 * 60 * 1_000_000_000

    try fixture.insertMessage(rowId: 100, guid: "gm100", text: "alpha intro", date: base, isFromMe: false, handleId: 1)
    try fixture.joinChatMessage(chatId: 10, messageId: 100)

    try fixture.insertMessage(rowId: 200, guid: "gm200", text: "trip to costa rica volcano", date: base + minute, isFromMe: false, handleId: 2)
    try fixture.joinChatMessage(chatId: 20, messageId: 200)

    try fixture.insertMessage(rowId: 201, guid: "gm201", text: "volcano photos? http://example.com", date: base + (2 * minute), isFromMe: true)
    try fixture.joinChatMessage(chatId: 20, messageId: 201)

    try fixture.insertAttachment(
        rowId: 900,
        filename: imageURL.path,
        mimeType: "image/jpeg",
        uti: "public.jpeg",
        totalBytes: (try? FileManager.default.attributesOfItem(atPath: imageURL.path)[.size] as? Int) ?? 0,
        transferName: imageURL.lastPathComponent
    )
    try fixture.joinMessageAttachment(messageId: 201, attachmentId: 900)

    try fixture.insertMessage(rowId: 400, guid: "reaction-love", text: nil, date: base + (3 * minute), isFromMe: false, handleId: 1, associatedMessageType: 2000, associatedMessageGuid: "gm201")
    try fixture.joinChatMessage(chatId: 20, messageId: 400)

    try fixture.insertMessage(rowId: 202, guid: "gm202", text: "packing list", date: base + sixteenHours, isFromMe: false, handleId: 1)
    try fixture.joinChatMessage(chatId: 20, messageId: 202)

    try fixture.insertMessage(rowId: 203, guid: "gm203", text: "let me know if this plan works?", date: base + sixteenHours + minute, isFromMe: true)
    try fixture.joinChatMessage(chatId: 20, messageId: 203)

    try fixture.insertMessage(rowId: 300, guid: "gm300", text: "trip planning notes", date: base + (4 * minute), isFromMe: false, handleId: 2)
    try fixture.joinChatMessage(chatId: 30, messageId: 300)

    return fixture
}
