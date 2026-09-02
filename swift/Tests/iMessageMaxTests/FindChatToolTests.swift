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

    func testFindChatDisambiguatesDuplicateDisplayNames() async throws {
        let fixture = try ToolTestDatabase(name: "find-chat-alex-doe")
        try fixture.insertHandle(rowId: 11, handle: "+15550000011")
        try fixture.insertHandle(rowId: 12, handle: "+15550000012")
        try fixture.insertChat(rowId: 11, guid: "chat-alex-guid", displayName: nil)
        try fixture.joinChatHandle(chatId: 11, handleId: 11)
        try fixture.joinChatHandle(chatId: 11, handleId: 12)
        try fixture.insertMessage(
            rowId: 1,
            guid: "msg-1",
            text: "hello",
            date: 1_000_000_000,
            isFromMe: false,
            handleId: 11
        )
        try fixture.joinChatMessage(chatId: 11, messageId: 1)

        let resolver = ContactResolver(seedCache: [
            "+15550000001": "Alice Smith",
            "+15550000002": "Bob Brown",
            "+15550000003": "Chris Green",
            "+15550000011": "Alex Doe",
            "+15550000012": "Alex Doe",
        ])
        let contents = try await FindChatTool.execute(
            arguments: [
                "participants": .array([.string("+15550000011")]),
            ],
            database: fixture.database(),
            resolver: resolver
        )
        let payload = try decodeJSONDictionary(from: contents)
        let chats = try decodeJSONArray(try XCTUnwrap(payload["chats"]))
        XCTAssertEqual(chats.count, 1)
        let participants = try decodeJSONArray(try XCTUnwrap(chats.first?["participants"]))
        let names = participants.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["Alex Doe (0011)", "Alex Doe (0012)"])
    }

    func testFilteredChatsAreHiddenByDefault() async throws {
        let fixture = try ToolTestDatabase(name: "find-chat-filtered")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        let now = Int64(Date().timeIntervalSinceReferenceDate * 1_000_000_000)
        let filters = [0, 1, 36]
        for (index, isFiltered) in filters.enumerated() {
            let chatId = index + 1
            try fixture.insertChat(
                rowId: chatId,
                guid: "find-filtered-\(chatId)",
                displayName: "Zebra Club \(chatId)",
                isFiltered: isFiltered
            )
            try fixture.joinChatHandle(chatId: chatId, handleId: 1)
            try fixture.insertMessage(
                rowId: chatId,
                guid: "find-filtered-msg-\(chatId)",
                text: "hello \(chatId)",
                date: now + Int64(chatId) * 1_000_000_000,
                isFromMe: false,
                handleId: 1
            )
            try fixture.joinChatMessage(chatId: chatId, messageId: chatId)
        }

        let hiddenContents = try await FindChatTool.execute(
            arguments: ["name": .string("Zebra")],
            database: fixture.database(),
            resolver: ContactResolver(seedCache: [:])
        )
        let hidden = try decodeJSONDictionary(from: hiddenContents)
        let hiddenChats = try decodeJSONArray(try XCTUnwrap(hidden["chats"]))
        XCTAssertEqual(hiddenChats.count, 1)
        XCTAssertEqual(hiddenChats.first?["id"] as? String, "chat1")
        XCTAssertEqual(hidden["filtered_hidden"] as? Int, 2)

        let shownContents = try await FindChatTool.execute(
            arguments: [
                "name": .string("Zebra"),
                "include_filtered": .bool(true),
            ],
            database: fixture.database(),
            resolver: ContactResolver(seedCache: [:])
        )
        let shown = try decodeJSONDictionary(from: shownContents)
        let shownChats = try decodeJSONArray(try XCTUnwrap(shown["chats"]))
        XCTAssertEqual(shownChats.count, 3)
        XCTAssertNil(shown["filtered_hidden"])
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
