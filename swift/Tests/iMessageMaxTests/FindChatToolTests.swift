import XCTest
import MCP
@testable import iMessageMax

final class FindChatToolTests: XCTestCase {
    func testContainsRecentFindsOlderMatchAmongManyRichMessages() async throws {
        let fixture = try makeContainsRecentRichFixture()
        let contents = try await FindChatTool.execute(
            arguments: [
                "contains_recent": .string("zebra"),
                "limit": .int(5),
            ],
            database: fixture.database(),
            resolver: makeSeededResolver()
        )
        let payload = try decodeJSONDictionary(from: contents)
        let chats = try decodeJSONArray(try XCTUnwrap(payload["chats"]))
        XCTAssertEqual(chats.count, 1)
        XCTAssertEqual(chats.first?["id"] as? String, "chat1")
    }
}

private func makeContainsRecentRichFixture() throws -> ToolTestDatabase {
    let fixture = try ToolTestDatabase(name: "find-chat-rich")
    try fixture.insertHandle(rowId: 1, handle: "+15550000001")
    try fixture.insertChat(rowId: 1, guid: "rich-chat", displayName: "Rich")
    try fixture.joinChatHandle(chatId: 1, handleId: 1)

    try fixture.insertMessage(
        rowId: 1,
        guid: "zebra-text",
        text: "zebra",
        date: 1,
        isFromMe: false,
        handleId: 1
    )
    try fixture.joinChatMessage(chatId: 1, messageId: 1)

    // Newer rich rows: text present (not "zebra") plus a non-NULL attributedBody.
    // Today's `OR m.attributedBody IS NOT NULL` matches all of them and the
    // 200-row fetch window never reaches the zebra row. After the predicate
    // fix they drop out because text is populated and does not LIKE zebra.
    let dummyBlob = Data([0x00, 0x01, 0x02])
    for n in 2...251 {
        try fixture.insertMessage(
            rowId: n,
            guid: "rich-\(n)",
            text: "filler \(n)",
            date: Int64(n),
            isFromMe: false,
            handleId: 1,
            attributedBody: dummyBlob
        )
        try fixture.joinChatMessage(chatId: 1, messageId: n)
    }
    return fixture
}
