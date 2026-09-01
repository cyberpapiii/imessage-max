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

    func testEnrichmentUsesBoundedQueryCount() async throws {
        let fixture = try ToolTestDatabase(name: "find-chat-batch")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        for chatId in 1...30 {
            try fixture.insertChat(rowId: chatId, guid: "chat-\(chatId)", displayName: "Chat \(chatId)")
            try fixture.joinChatHandle(chatId: chatId, handleId: 1)
            try fixture.insertMessage(
                rowId: chatId,
                guid: "msg-\(chatId)",
                text: "hello \(chatId)",
                date: Int64(chatId) * 1_000_000_000,
                isFromMe: false,
                handleId: 1
            )
            try fixture.joinChatMessage(chatId: chatId, messageId: chatId)
        }

        Database.queryCountForTesting = 0
        defer { Database.queryCountForTesting = nil }

        let contents = try await FindChatTool.execute(
            arguments: [
                "participants": .array([.string("+15550000001")]),
                "limit": .int(5),
            ],
            database: fixture.database(),
            resolver: makeSeededResolver()
        )
        let payload = try decodeJSONDictionary(from: contents)
        let chats = try decodeJSONArray(try XCTUnwrap(payload["chats"]))
        XCTAssertEqual(chats.count, 5)
        let queryCount = try XCTUnwrap(Database.queryCountForTesting)
        XCTAssertLessThanOrEqual(queryCount, 6, "find_chat ran \(queryCount) queries")
    }

    func testNameMatchesUnnamedDMByResolvedParticipantContact() async throws {
        let fixture = try ToolTestDatabase(name: "find-chat-unnamed-dm")
        try fixture.insertHandle(rowId: 1, handle: "+15550000022")
        try fixture.insertChat(rowId: 22, guid: "imessage-sukhmani", displayName: nil)
        try fixture.joinChatHandle(chatId: 22, handleId: 1)
        try fixture.insertMessage(
            rowId: 1,
            guid: "msg-1",
            text: "hello",
            date: 1_000_000_000,
            isFromMe: false,
            handleId: 1
        )
        try fixture.joinChatMessage(chatId: 22, messageId: 1)

        let contents = try await FindChatTool.execute(
            arguments: [
                "name": .string("Sukhmani"),
                "is_group": .bool(false),
            ],
            database: fixture.database(),
            resolver: ContactResolver(seedCache: ["+15550000022": "Sukhmani Kular"])
        )
        let payload = try decodeJSONDictionary(from: contents)
        let chats = try decodeJSONArray(try XCTUnwrap(payload["chats"]))
        XCTAssertEqual(chats.count, 1)
        XCTAssertEqual(chats.first?["id"] as? String, "chat22")
        XCTAssertEqual(chats.first?["name"] as? String, "Sukhmani Kular")
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
