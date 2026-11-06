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

    /// Every result's summary comes from batched queries, not one per chat.
    func testEnrichmentQueryCountDoesNotGrowWithResults() async throws {
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

        func queries(limit: Int) async throws -> Int {
            try await countQueries {
                let contents = try await FindChatTool.execute(
                    arguments: [
                        "participants": .array([.string("+15550000001")]),
                        "limit": .int(limit),
                    ],
                    database: fixture.database(),
                    resolver: makeSeededResolver()
                )
                let chats = try decodeJSONArray(try decodeJSONDictionary(from: contents)["chats"])
                XCTAssertEqual(chats.count, limit)
            }
        }
        let two = try await queries(limit: 2)
        let ten = try await queries(limit: 10)
        XCTAssertGreaterThan(two, 0)
        XCTAssertEqual(ten, two, "10 results ran \(ten) queries, 2 ran \(two)")
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
        let fixture = try filteredChatsFixture()

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

    // MARK: - Participants, content and ordering

    func testContainsRecentSeesPastTwoHundredBlobRows() async throws {
        let fixture = try blobTextFixture(fillerCount: 300)
        let found = try await callTool("find_chat", ["contains_recent": "Lisbon"], database: fixture.database())
        XCTAssertEqual(try itemIds(found, "chats"), ["chat1"])
    }

    func testAnUnresolvedParticipantMatchesNothing() async throws {
        let fixture = try participantsFixture()
        let found = try await callTool(
            "find_chat", ["participants": ["Alice", "Bob", "Nobody Known"]], database: fixture.database(),
            resolver: ContactResolver(seedCache: aliceAndBob)
        )
        XCTAssertEqual(try itemIds(found, "chats"), [])
    }

    func testParticipantsAcceptAnEmail() async throws {
        let fixture = try participantsFixture()
        let found = try await callTool("find_chat", ["participants": ["pat@example.com"]], database: fixture.database())
        XCTAssertEqual(try itemIds(found, "chats"), ["chat30"])
    }

    func testRanksTheExactParticipantSetFirst() async throws {
        let fixture = try participantsFixture()
        let resolver = ContactResolver(seedCache: aliceAndBob)
        let bob = try await callTool("find_chat", ["participants": ["Bob"]], database: fixture.database(), resolver: resolver)
        XCTAssertEqual(try itemIds(bob, "chats"), ["chat20"])
        let alice = try await callTool("find_chat", ["participants": ["Alice"], "limit": 3], database: fixture.database(), resolver: resolver)
        XCTAssertEqual(try itemIds(alice, "chats"), ["chat12", "chat11", "chat10"])
    }

    func testByNameListsTheMostRecentlyActiveFirst() async throws {
        let fixture = try ToolTestDatabase(name: "name-order")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertHandle(rowId: 2, handle: "+15550000002")
        let base = AppleTime.fromDate(Date()) - 60 * appleMinute
        for (chat, minute) in [(1, 2), (2, 3), (3, 1)] {
            try fixture.insertChat(rowId: chat, guid: "iMessage;+;team\(chat)", displayName: "Team \(chat)")
            try fixture.joinChatHandle(chatId: chat, handleId: 1)
            try fixture.joinChatHandle(chatId: chat, handleId: 2)
            try fixture.insertMessage(rowId: chat, guid: "T\(chat)", text: "m\(chat)", date: base + Int64(minute) * appleMinute, isFromMe: true)
            try fixture.joinChatMessage(chatId: chat, messageId: chat)
        }
        let found = try await callTool("find_chat", ["name": "Team", "limit": 2], database: fixture.database())
        XCTAssertEqual(try itemIds(found, "chats"), ["chat2", "chat1"])
    }

    /// filtered_hidden counts every hidden chat that would have matched, by
    /// name or by content, not just the ones past the limit.
    func testFilteredHiddenCountsEveryHiddenChatThatWouldHaveMatched() async throws {
        let fixture = try ToolTestDatabase(name: "find-hidden")
        for handle in 1...4 { try fixture.insertHandle(rowId: handle, handle: "+1555000000\(handle)") }
        try fixture.insertChat(rowId: 1, guid: "iMessage;+;shown", displayName: "Spam Fans")
        try fixture.insertChat(rowId: 2, guid: "iMessage;+;h1", displayName: "Spam Club 1", isFiltered: 1)
        try fixture.insertChat(rowId: 3, guid: "iMessage;+;h2", displayName: "Spam Club 2", isFiltered: 1)
        try fixture.insertChat(rowId: 4, guid: "iMessage;-;+15550000004", isFiltered: 1)
        for (chat, handles) in [(1, [1, 2]), (2, [1, 3]), (3, [2, 3]), (4, [4])] {
            for handle in handles { try fixture.joinChatHandle(chatId: chat, handleId: handle) }
            try fixture.insertMessage(rowId: chat, guid: "g\(chat)", text: "zebra crossing", date: 700_000_000_000_000_000 + Int64(chat), isFromMe: false, handleId: handles[0])
            try fixture.joinChatMessage(chatId: chat, messageId: chat)
        }
        let resolver = ContactResolver(seedCache: ["+15550000004": "Spam Bot"])

        let byName = try await callTool("find_chat", ["name": "Spam", "limit": 1], database: fixture.database(), resolver: resolver)
        XCTAssertEqual(try itemIds(byName, "chats").count, 1)
        XCTAssertEqual(byName["filtered_hidden"] as? Int, 3, "two named groups and the unnamed DM")

        let byContent = try await callTool("find_chat", ["contains_recent": "zebra", "limit": 1], database: fixture.database(), resolver: resolver)
        XCTAssertEqual(try itemIds(byContent, "chats").count, 1)
        XCTAssertEqual(byContent["filtered_hidden"] as? Int, 3)
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
