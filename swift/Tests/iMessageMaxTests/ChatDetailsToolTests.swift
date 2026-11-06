import XCTest
import MCP
@testable import iMessageMax

final class ChatDetailsToolTests: XCTestCase {
    func testGetChatDetailsReturnsThreadFactsWithoutMessages() async throws {
        let fixture = try makeChatDetailsFixture()
        let resolver = makeChatDetailsResolver()

        let contents = try await GetChatDetailsTool.execute(
            arguments: ["chat_id": .string("chat900")],
            database: fixture.database(),
            resolver: resolver
        )

        let response = try decodeJSONDictionary(from: contents)
        XCTAssertNotNil(response["chat"])
        XCTAssertNotNil(response["participants"])
        XCTAssertNotNil(response["identity"])
        XCTAssertNotNil(response["state"])
        XCTAssertNotNil(response["last_message"])
        XCTAssertNotNil(response["shared"])
        XCTAssertNil(response["messages"])

        let participants = try decodeJSONArray(response["participants"])
        XCTAssertEqual(participants.count, 3)
        XCTAssertEqual(participants[0]["name"] as? String, "Alex Smith (1111)")
        XCTAssertEqual(participants[0]["handle"] as? String, "+15550001111")
        XCTAssertNil(participants[0]["service"])
    }

    /// A well-formed id with no chat row is the caller's mistake, not an
    /// internal error: chat_not_found with a next step, not query_failed.
    func testMissingChatIsChatNotFoundWithANextStep() async throws {
        let fixture = try makeChatDetailsFixture()

        do {
            _ = try await GetChatDetailsTool.execute(
                arguments: ["chat_id": .string("chat999999")],
                database: fixture.database(),
                resolver: makeChatDetailsResolver()
            )
            XCTFail("expected ToolFailure")
        } catch let error as ToolFailure {
            guard case .text(let text, _, _)? = error.content.first else {
                return XCTFail("expected text content")
            }
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            )
            XCTAssertEqual(object["error"] as? String, "chat_not_found")
            XCTAssertEqual(object["message"] as? String, ClientErrorMessages.chatNotFound("chat999999"))
        }
    }

    // MARK: - State

    /// unread_count counts unread messages from others, not mine, read ones
    /// or tapbacks; first and last activity span the chat's messages and
    /// ignore tapbacks.
    func testStateCountsUnreadAndSpansActivity() async throws {
        let fixture = try directChatFixture(name: "chat-details-state")
        let hour: Int64 = 60 * appleMinute
        let rows: [(date: Int64, fromMe: Bool, read: Bool, reaction: Bool)] = [
            (fixtureDay(0), false, true, false),
            (fixtureDay(1), false, false, false),
            (fixtureDay(1) + hour, true, false, false),
            (fixtureDay(1) + 2 * hour, false, false, false),
            (fixtureDay(2), false, false, true),
        ]
        for (index, row) in rows.enumerated() {
            try fixture.insertMessage(
                rowId: index + 1, guid: "s\(index)", text: row.reaction ? nil : "m\(index)", date: row.date,
                isFromMe: row.fromMe, isRead: row.read, handleId: row.fromMe ? nil : 1,
                associatedMessageType: row.reaction ? 2000 : 0, associatedMessageGuid: row.reaction ? "s0" : nil
            )
            try fixture.joinChatMessage(chatId: 1, messageId: index + 1)
        }

        let details = try await callTool("get_chat_details", ["chat_id": "chat1"], database: fixture.database())
        let state = try XCTUnwrap(details["state"] as? [String: Any], "\(details)")
        XCTAssertEqual(state["unread_count"] as? Int, 2)
        XCTAssertEqual(state["first_activity"] as? String, "2020-01-06T10:40:00Z")
        XCTAssertEqual(state["last_activity"] as? String, "2020-01-07T12:40:00Z")
    }

    func testSharedSummaryIsLeftOutWhenNotAsked() async throws {
        let fixture = try makeChatDetailsFixture()
        let details = try await callTool(
            "get_chat_details", ["chat_id": "chat900", "include_shared_summary": false],
            database: fixture.database(), resolver: makeChatDetailsResolver()
        )
        XCTAssertNotNil(details["state"], "\(details)")
        XCTAssertNil(details["shared"])
    }

    // MARK: - Unnamed chat names

    /// An unnamed group is named for its participants, alphabetically: all
    /// of them up to four, then the first three "and N others".
    func testUnnamedGroupNameListsUpToFourThenCountsTheRest() async throws {
        let names = ["Eli Sun", "Ana Lima", "Dee Ray", "Ben Ode", "Cy Park"]
        var contacts: [String: String] = [:]
        let fixture = try ToolTestDatabase(name: "unnamed-groups")
        for (index, name) in names.enumerated() {
            let handle = "+1555000010\(index)"
            contacts[handle] = name
            try fixture.insertHandle(rowId: index + 1, handle: handle)
        }
        try fixture.insertChat(rowId: 4, guid: "iMessage;+;four")
        for handle in 1...4 { try fixture.joinChatHandle(chatId: 4, handleId: handle) }
        try fixture.insertChat(rowId: 5, guid: "iMessage;+;five")
        for handle in 1...5 { try fixture.joinChatHandle(chatId: 5, handleId: handle) }
        let resolver = ContactResolver(seedCache: contacts)

        let four = try await callTool("get_chat_details", ["chat_id": "chat4"], database: fixture.database(), resolver: resolver)
        XCTAssertEqual((four["chat"] as? [String: Any])?["name"] as? String, "Ana Lima, Ben Ode, Dee Ray, Eli Sun")
        let five = try await callTool("get_chat_details", ["chat_id": "chat5"], database: fixture.database(), resolver: resolver)
        XCTAssertEqual((five["chat"] as? [String: Any])?["name"] as? String, "Ana Lima, Ben Ode, Cy Park and 2 others")
    }

    func testUnnamedChatWithNoParticipantsIsUnknownChat() async throws {
        let fixture = try ToolTestDatabase(name: "no-participants")
        try fixture.insertChat(rowId: 1, guid: "iMessage;+;empty")
        let details = try await callTool("get_chat_details", ["chat_id": "chat1"], database: fixture.database())
        XCTAssertEqual((details["chat"] as? [String: Any])?["name"] as? String, "Unknown Chat")
    }
}

func makeChatDetailsFixture() throws -> ToolTestDatabase {
    let fixture = try ToolTestDatabase(name: "chat-details")
    let imageURL = try makeFixtureImage(name: "chat-details-image.jpg")
    let imageSize = (try? FileManager.default.attributesOfItem(atPath: imageURL.path)[.size] as? Int) ?? 0

    try fixture.insertHandle(rowId: 1, handle: "+15550001111")
    try fixture.insertHandle(rowId: 2, handle: "+15550002222")
    try fixture.insertHandle(rowId: 3, handle: "+15550003333")

    try fixture.insertChat(rowId: 900, guid: "chat-details-guid", displayName: "Planning")
    try fixture.joinChatHandle(chatId: 900, handleId: 1)
    try fixture.joinChatHandle(chatId: 900, handleId: 2)
    try fixture.joinChatHandle(chatId: 900, handleId: 3)

    let base = AppleTime.fromDate(Date().addingTimeInterval(-12 * 3600))
    let minute: Int64 = 60 * 1_000_000_000

    try fixture.insertMessage(rowId: 9000, guid: "cd-1", text: "Need the latest deck", date: base, isFromMe: false, isRead: false, handleId: 1)
    try fixture.joinChatMessage(chatId: 900, messageId: 9000)

    try fixture.insertMessage(rowId: 9001, guid: "cd-2", text: "Sending now", date: base + minute, isFromMe: true)
    try fixture.joinChatMessage(chatId: 900, messageId: 9001)

    try fixture.insertMessage(rowId: 9002, guid: "cd-3", text: nil, date: base + (2 * minute), isFromMe: false, handleId: 2)
    try fixture.joinChatMessage(chatId: 900, messageId: 9002)

    try fixture.insertAttachment(
        rowId: 9900,
        filename: imageURL.path,
        mimeType: "image/jpeg",
        uti: "public.jpeg",
        totalBytes: imageSize,
        transferName: imageURL.lastPathComponent
    )
    try fixture.joinMessageAttachment(messageId: 9002, attachmentId: 9900)

    try fixture.insertAttachment(
        rowId: 9901,
        filename: imageURL.path,
        mimeType: "image/jpeg",
        uti: "public.jpeg",
        totalBytes: imageSize,
        transferName: "chat-details-image-2.jpg"
    )
    try fixture.joinMessageAttachment(messageId: 9002, attachmentId: 9901)

    return fixture
}

func makeChatDetailsResolver() -> ContactResolver {
    ContactResolver(seedCache: [
        "+15550001111": "Alex Smith",
        "+15550002222": "Alex Smith",
        "+15550003333": "Taylor Jones",
    ])
}
