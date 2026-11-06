import XCTest
import MCP
@testable import iMessageMax

final class ListToolCharacterizationTests: XCTestCase {

    private func makeListCharacterizationFixture() throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "list-characterization")

        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertHandle(rowId: 2, handle: "+15550000002")
        try fixture.insertHandle(rowId: 3, handle: "+15550000003")

        try fixture.insertChat(rowId: 1, guid: "iMessage;-;alice-dm-guid")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)

        try fixture.insertChat(rowId: 2, guid: "iMessage;+;trip-crew-guid", displayName: "Trip Crew")
        try fixture.joinChatHandle(chatId: 2, handleId: 1)
        try fixture.joinChatHandle(chatId: 2, handleId: 2)
        try fixture.joinChatHandle(chatId: 2, handleId: 3)

        let base = AppleTime.fromDate(Date().addingTimeInterval(-3600))
        let sec: Int64 = 1_000_000_000

        try fixture.insertMessage(
            rowId: 10,
            guid: "msg10",
            text: "hey there",
            date: base,
            isFromMe: true
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 10)

        try fixture.insertMessage(
            rowId: 11,
            guid: "msg11",
            text: "hello from alice",
            date: base + sec,
            isFromMe: false,
            handleId: 1
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 11)

        try fixture.insertMessage(
            rowId: 12,
            guid: "msg12",
            text: nil,
            date: base + (2 * sec),
            isFromMe: false,
            handleId: 1,
            associatedMessageType: 2000,
            associatedMessageGuid: "msg11"
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 12)

        try fixture.insertMessage(
            rowId: 20,
            guid: "msg20",
            text: "let's plan the trip",
            date: base + (3 * sec),
            isFromMe: true
        )
        try fixture.joinChatMessage(chatId: 2, messageId: 20)

        return fixture
    }

    func testListChatsLastMessagePicksNewestNonReaction() async throws {
        let fixture = try makeListCharacterizationFixture()
        let resolver = makeSeededResolver()

        let result = try await ListChatsTool.execute(
            limit: 10,
            since: nil,
            isGroup: nil,
            minParticipants: nil,
            maxParticipants: nil,
            sort: "recent",
            db: fixture.database(),
            resolver: resolver
        )

        let response = result
        let dmChat = try XCTUnwrap(
            response.chats.first(where: { $0.id == "chat1" }),
            "Expected chat1 (DM) in results"
        )
        let lastMsg = try XCTUnwrap(dmChat.lastMessage, "Expected last_message on DM chat")
        XCTAssertEqual(
            lastMsg.text,
            "hello from alice",
            "last_message should be the newest non-reaction, not the reaction"
        )
        XCTAssertEqual(
            lastMsg.from,
            "Alice Smith",
            "last_message.from should be the resolved contact name"
        )
    }

    func testListChatsAwaitingReplyTrueWhenLastMessageFromThem() async throws {
        let fixture = try makeListCharacterizationFixture()
        let resolver = makeSeededResolver()

        let result = try await ListChatsTool.execute(
            limit: 10,
            since: nil,
            isGroup: nil,
            minParticipants: nil,
            maxParticipants: nil,
            sort: "recent",
            db: fixture.database(),
            resolver: resolver
        )

        let response = result
        let dmChat = try XCTUnwrap(response.chats.first(where: { $0.id == "chat1" }))
        XCTAssertEqual(dmChat.awaitingReply, true, "DM should be awaiting_reply when last message is from them")

        let groupChat = try XCTUnwrap(response.chats.first(where: { $0.id == "chat2" }))
        XCTAssertNotEqual(groupChat.awaitingReply, true, "Group should not be awaiting_reply when last message is from me")
    }

    func testListChatsGroupFlagAndParticipantCount() async throws {
        let fixture = try makeListCharacterizationFixture()
        let resolver = makeSeededResolver()

        let result = try await ListChatsTool.execute(
            limit: 10,
            since: nil,
            isGroup: nil,
            minParticipants: nil,
            maxParticipants: nil,
            sort: "recent",
            db: fixture.database(),
            resolver: resolver
        )

        let response = result
        let groupChat = try XCTUnwrap(response.chats.first(where: { $0.id == "chat2" }))
        XCTAssertEqual(groupChat.group, true, "Chat with 3 participants should be flagged as group")
        XCTAssertEqual(groupChat.participantCount, 3, "Trip Crew should report 3 participants")

        let dmChat = try XCTUnwrap(response.chats.first(where: { $0.id == "chat1" }))
        XCTAssertNil(dmChat.group, "DM should not have group flag set")
    }

    private func makeActiveConversationsFixture() throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "active-conversations")

        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertHandle(rowId: 2, handle: "+15550000002")

        try fixture.insertChat(rowId: 10, guid: "iMessage;+;active-test-guid")
        try fixture.joinChatHandle(chatId: 10, handleId: 1)

        let now = AppleTime.fromDate(Date())
        let sec: Int64 = 1_000_000_000

        for i in 0..<3 {
            let msgId = 100 + i
            try fixture.insertMessage(
                rowId: msgId,
                guid: "active-me-\(msgId)",
                text: "my message \(i)",
                date: now - Int64(10 - i) * sec,
                isFromMe: true
            )
            try fixture.joinChatMessage(chatId: 10, messageId: msgId)
        }

        try fixture.insertMessage(
            rowId: 200,
            guid: "active-them-200",
            text: "their first",
            date: now - (5 * sec),
            isFromMe: false,
            handleId: 1
        )
        try fixture.joinChatMessage(chatId: 10, messageId: 200)

        try fixture.insertMessage(
            rowId: 201,
            guid: "active-them-201",
            text: "their second",
            date: now - (2 * sec),
            isFromMe: false,
            handleId: 1
        )
        try fixture.joinChatMessage(chatId: 10, messageId: 201)

        return fixture
    }

    func testActiveConversationsExchangeCountIsMinOfDirections() async throws {
        let fixture = try makeActiveConversationsFixture()
        let resolver = makeSeededResolver()

        let result = try await GetActiveConversations.execute(
            hours: 24,
            minExchanges: 1,
            isGroup: nil,
            limit: 10,
            database: fixture.database(),
            resolver: resolver
        )

        let convo = try XCTUnwrap(
            result.conversations.first(where: { $0.id == "chat10" }),
            "Expected chat10 in active conversations"
        )
        XCTAssertEqual(convo.activity.exchanges, 2, "exchanges should be min(my_msgs, their_msgs)")
        XCTAssertEqual(convo.activity.myMsgs, 3, "Expected 3 messages from me")
        XCTAssertEqual(convo.activity.theirMsgs, 2, "Expected 2 messages from them")
    }

    func testActiveConversationsAwaitingReplyComputedFromTimestamps() async throws {
        let fixture = try makeActiveConversationsFixture()
        let resolver = makeSeededResolver()

        let result = try await GetActiveConversations.execute(
            hours: 24,
            minExchanges: 1,
            isGroup: nil,
            limit: 10,
            database: fixture.database(),
            resolver: resolver
        )

        let convo = try XCTUnwrap(
            result.conversations.first(where: { $0.id == "chat10" }),
            "Expected chat10 in active conversations"
        )
        XCTAssertTrue(
            convo.awaitingReply,
            "awaiting_reply should be true when last-from-them is more recent than last-from-me"
        )
    }

    private func makeFanOutFixture() throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "participant-fan-out")

        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertHandle(rowId: 2, handle: "+15550000002")
        try fixture.insertHandle(rowId: 3, handle: "+15550000003")

        try fixture.insertChat(rowId: 1, guid: "iMessage;-;fanout-dm")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)

        try fixture.insertChat(rowId: 2, guid: "iMessage;+;fanout-group", displayName: "Fan Out")
        try fixture.joinChatHandle(chatId: 2, handleId: 1)
        try fixture.joinChatHandle(chatId: 2, handleId: 2)
        try fixture.joinChatHandle(chatId: 2, handleId: 3)

        let base: Int64 = 6_000_000_000_000
        let sec: Int64 = 1_000_000_000

        for i in 0..<3 {
            let id = 300 + i
            try fixture.insertMessage(
                rowId: id,
                guid: "fanout-dm-\(id)",
                text: "dm \(i)",
                date: base + Int64(i) * sec,
                isFromMe: false,
                handleId: 1
            )
            try fixture.joinChatMessage(chatId: 1, messageId: id)
        }

        for i in 0..<2 {
            let id = 400 + i
            try fixture.insertMessage(
                rowId: id,
                guid: "fanout-group-\(id)",
                text: "group \(i)",
                date: base + Int64(10 + i) * sec,
                isFromMe: false,
                handleId: 2
            )
            try fixture.joinChatMessage(chatId: 2, messageId: id)
        }

        return fixture
    }

    func testListChatsMostActiveIsNotInflatedByParticipantCount() async throws {
        let fixture = try makeFanOutFixture()

        let result = try await ListChatsTool.execute(
            limit: 10,
            sort: "most_active",
            db: fixture.database(),
            resolver: makeSeededResolver()
        )

        let response = result

        XCTAssertEqual(
            response.chats.map(\.id),
            ["chat1", "chat2"],
            "The 3-message DM outranks the 2-message group; participant count must not scale message_count"
        )
    }

    private func makeGroupActivityFixture() throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "group-activity")

        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertHandle(rowId: 2, handle: "+15550000002")
        try fixture.insertHandle(rowId: 3, handle: "+15550000003")

        try fixture.insertChat(rowId: 20, guid: "iMessage;+;group-activity", displayName: "Group Activity")
        try fixture.joinChatHandle(chatId: 20, handleId: 1)
        try fixture.joinChatHandle(chatId: 20, handleId: 2)
        try fixture.joinChatHandle(chatId: 20, handleId: 3)

        let now = AppleTime.fromDate(Date())
        let sec: Int64 = 1_000_000_000

        for i in 0..<2 {
            let id = 500 + i
            try fixture.insertMessage(
                rowId: id,
                guid: "group-me-\(id)",
                text: "mine \(i)",
                date: now - Int64(20 - i) * sec,
                isFromMe: true
            )
            try fixture.joinChatMessage(chatId: 20, messageId: id)
        }

        for i in 0..<2 {
            let id = 600 + i
            try fixture.insertMessage(
                rowId: id,
                guid: "group-them-\(id)",
                text: "theirs \(i)",
                date: now - Int64(10 - i) * sec,
                isFromMe: false,
                handleId: 1
            )
            try fixture.joinChatMessage(chatId: 20, messageId: id)
        }

        return fixture
    }

    func testActiveConversationsCountsAreNotInflatedByParticipantCount() async throws {
        let fixture = try makeGroupActivityFixture()

        let result = try await GetActiveConversations.execute(
            hours: 24,
            minExchanges: 1,
            isGroup: nil,
            limit: 10,
            database: fixture.database(),
            resolver: makeSeededResolver()
        )

        let convo = try XCTUnwrap(
            result.conversations.first(where: { $0.id == "chat20" }),
            "Expected chat20 in active conversations"
        )

        XCTAssertEqual(convo.participantCount, 3)
        XCTAssertEqual(convo.activity.myMsgs, 2, "2 messages from me, not 2 x 3 participants")
        XCTAssertEqual(convo.activity.theirMsgs, 2, "2 messages from them, not 2 x 3 participants")
        XCTAssertEqual(convo.activity.exchanges, 2)
    }

    func testListChatsQueryCountDoesNotGrowWithPageSize() async throws {
        let fixture = try ToolTestDatabase(name: "list-chats-query-count")
        for rowId in 1...6 {
            try fixture.insertHandle(rowId: rowId, handle: "+1555000000\(rowId)")
        }
        let base: Int64 = 700_000_000_000_000_000
        let sec: Int64 = 1_000_000_000
        for chatId in 1...24 {
            try fixture.insertChat(rowId: chatId, guid: "chat-\(chatId)-guid", displayName: "Group \(chatId)")
            for handleId in 1...6 {
                try fixture.joinChatHandle(chatId: chatId, handleId: handleId)
            }
            for inbound in 1...3 {
                let messageId = chatId * 10 + inbound
                try fixture.insertMessage(
                    rowId: messageId,
                    guid: "msg-\(messageId)",
                    text: "hello \(messageId)",
                    date: base + Int64(chatId * 3 + inbound) * sec,
                    isFromMe: false,
                    handleId: inbound
                )
                try fixture.joinChatMessage(chatId: chatId, messageId: messageId)
            }
        }

        func queries(limit: Int) async throws -> Int {
            try await countQueries {
                let response = try await ListChatsTool.execute(
                    limit: limit,
                    sort: "recent",
                    db: fixture.database(),
                    resolver: makeSeededResolver()
                )
                XCTAssertEqual(response.chats.count, limit)
            }
        }
        let three = try await queries(limit: 3)
        let twelve = try await queries(limit: 12)
        XCTAssertGreaterThan(three, 0)
        XCTAssertEqual(twelve, three, "a page of 12 ran \(twelve) queries, a page of 3 ran \(three)")
    }

    func testActiveConversationsFindsQualifyingChatsBehindNewerThinOnes() async throws {
        let fixture = try ToolTestDatabase(name: "active")
        let base = AppleTime.fromDate(Date()) - 120 * appleMinute
        var row = 0
        func exchange(_ chat: Int, atMinute minute: Int64, rounds: Int) throws {
            for round in 0..<rounds {
                for fromMe in [true, false] {
                    row += 1
                    try fixture.insertMessage(rowId: row, guid: "A\(row)", text: "t\(row)", date: base + (minute + Int64(round)) * appleMinute,
                                              isFromMe: fromMe, handleId: fromMe ? nil : chat)
                    try fixture.joinChatMessage(chatId: chat, messageId: row)
                }
            }
        }
        for chat in 1...6 {
            try fixture.insertHandle(rowId: chat, handle: "+1555000000\(chat)")
            try fixture.insertChat(rowId: chat, guid: "iMessage;-;\(chat)")
            try fixture.joinChatHandle(chatId: chat, handleId: chat)
        }
        try exchange(1, atMinute: 0, rounds: 2)
        try exchange(2, atMinute: 5, rounds: 2)
        for chat in 3...6 { try exchange(chat, atMinute: Int64(20 + chat), rounds: 1) }

        let one = try await callTool("get_active_conversations", ["limit": 1, "min_exchanges": 2], database: fixture.database())
        XCTAssertEqual(try itemIds(one, "conversations"), ["chat2"])
        XCTAssertEqual(one["more"] as? Bool, true)
        let all = try await callTool("get_active_conversations", ["limit": 2, "min_exchanges": 2], database: fixture.database())
        XCTAssertEqual(try itemIds(all, "conversations"), ["chat2", "chat1"])
        XCTAssertEqual(all["more"] as? Bool, false)
    }

    func testActiveConversationsAndListAttachmentsSkipHiddenChats() async throws {
        let fixture = try ToolTestDatabase(name: "hidden-active")
        try fixture.insertHandle(rowId: 1, handle: "spam@example.com")
        try fixture.insertChat(rowId: 1, guid: "iMessage;-;spam@example.com", isFiltered: 1)
        try fixture.joinChatHandle(chatId: 1, handleId: 1)
        let recent = AppleTime.fromDate(Date().addingTimeInterval(-3600))
        try fixture.insertMessage(rowId: 1, guid: "g1", text: "\u{FFFC}", date: recent, isFromMe: false, handleId: 1)
        try fixture.insertMessage(rowId: 2, guid: "g2", text: "who is this", date: recent + 1, isFromMe: true)
        for row in 1...2 { try fixture.joinChatMessage(chatId: 1, messageId: row) }
        try fixture.insertAttachment(rowId: 1, filename: "/nonexistent/x.pdf", mimeType: "application/pdf", uti: "com.adobe.pdf")
        try fixture.joinMessageAttachment(messageId: 1, attachmentId: 1)

        let active = try await callTool("get_active_conversations", ["min_exchanges": 1], database: fixture.database())
        XCTAssertEqual(try itemIds(active, "conversations"), [])
        let listed = try await callTool("list_attachments", [:], database: fixture.database())
        XCTAssertEqual(try decodeJSONArray(listed["messages"]).count, 0)
        let named = try await callTool("list_attachments", ["chat_id": "chat1"], database: fixture.database())
        XCTAssertEqual(try decodeJSONArray(named["messages"]).count, 1)
    }
}
