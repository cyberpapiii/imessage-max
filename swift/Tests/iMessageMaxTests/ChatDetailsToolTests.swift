import XCTest
import MCP
@testable import iMessageMax

final class ChatDetailsToolTests: XCTestCase {
    func testToolRegistryIncludesGetChatDetails() async {
        ToolHandlerRegistry.shared.resetForTesting()

        let server = Server(name: "test", version: "0")
        await ToolRegistry.registerAll(on: server, db: Database(), resolver: ContactResolver())

        let names = Set(ToolHandlerRegistry.shared.getTools().map(\.name))
        XCTAssertTrue(names.contains("get_chat_details"))
    }

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
