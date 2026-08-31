import XCTest
import MCP
@testable import iMessageMax

// Characterization tests for list_chats and get_active_conversations.
// These lock in the current behavior so that a future batching refactor
// cannot silently change participant resolution, last-message selection,
// awaiting-reply logic, or exchange-count computation.

final class ListToolCharacterizationTests: XCTestCase {

    // MARK: - Shared fixture

    // Chat 1 (DM): Alice only
    //   msg 1 from me (oldest)
    //   msg 2 from Alice (newer) ← should be last_message
    //   msg 3 from Alice, reaction (newest, but associated_message_type = 2000)
    // Chat 2 (group, "Trip Crew"): Alice, Bob, Chris
    //   msg 4 from me (last message)

    private func makeListCharacterizationFixture() throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "list-characterization")

        try fixture.insertHandle(rowId: 1, handle: "+15550000001")  // Alice
        try fixture.insertHandle(rowId: 2, handle: "+15550000002")  // Bob
        try fixture.insertHandle(rowId: 3, handle: "+15550000003")  // Chris

        // Chat 1: DM with Alice
        try fixture.insertChat(rowId: 1, guid: "iMessage;-;alice-dm-guid")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)

        // Chat 2: group "Trip Crew"
        try fixture.insertChat(rowId: 2, guid: "iMessage;+;trip-crew-guid", displayName: "Trip Crew")
        try fixture.joinChatHandle(chatId: 2, handleId: 1)
        try fixture.joinChatHandle(chatId: 2, handleId: 2)
        try fixture.joinChatHandle(chatId: 2, handleId: 3)

        // Apple epoch: nanoseconds since 2001-01-01
        let base = Int64(Date().timeIntervalSinceReferenceDate * 1_000_000_000) - 3_600_000_000_000
        let sec: Int64 = 1_000_000_000

        // Chat 1 messages
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

        // Reaction from Alice - newer but should NOT be selected as last_message
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

        // Chat 2 messages
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

    // MARK: - list_chats tests

    func testListChatsResolvesParticipantNamesFromContacts() async throws {
        let fixture = try makeListCharacterizationFixture()
        let resolver = makeSeededResolver()

        let result = await ListChatsTool.execute(
            limit: 10,
            since: nil,
            isGroup: nil,
            minParticipants: nil,
            maxParticipants: nil,
            sort: "recent",
            db: fixture.database(),
            resolver: resolver
        )

        switch result {
        case .failure(let error):
            XCTFail("list_chats failed: \(error.message)")
        case .success(let response):
            let groupChat = try XCTUnwrap(
                response.chats.first(where: { $0.id == "chat2" }),
                "Expected chat2 (Trip Crew) in results"
            )
            let preview = groupChat.participantsPreview
            XCTAssertTrue(
                preview.contains("Alice Smith"),
                "Expected 'Alice Smith' in participants_preview, got \(preview)"
            )
            XCTAssertFalse(
                preview.contains("+15550000001"),
                "Raw handle should not appear when contact name is available"
            )
        }
    }

    func testListChatsLastMessagePicksNewestNonReaction() async throws {
        let fixture = try makeListCharacterizationFixture()
        let resolver = makeSeededResolver()

        let result = await ListChatsTool.execute(
            limit: 10,
            since: nil,
            isGroup: nil,
            minParticipants: nil,
            maxParticipants: nil,
            sort: "recent",
            db: fixture.database(),
            resolver: resolver
        )

        switch result {
        case .failure(let error):
            XCTFail("list_chats failed: \(error.message)")
        case .success(let response):
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
    }

    func testListChatsAwaitingReplyTrueWhenLastMessageFromThem() async throws {
        let fixture = try makeListCharacterizationFixture()
        let resolver = makeSeededResolver()

        let result = await ListChatsTool.execute(
            limit: 10,
            since: nil,
            isGroup: nil,
            minParticipants: nil,
            maxParticipants: nil,
            sort: "recent",
            db: fixture.database(),
            resolver: resolver
        )

        switch result {
        case .failure(let error):
            XCTFail("list_chats failed: \(error.message)")
        case .success(let response):
            let dmChat = try XCTUnwrap(response.chats.first(where: { $0.id == "chat1" }))
            XCTAssertEqual(dmChat.awaitingReply, true, "DM should be awaiting_reply when last message is from them")

            let groupChat = try XCTUnwrap(response.chats.first(where: { $0.id == "chat2" }))
            XCTAssertNotEqual(groupChat.awaitingReply, true, "Group should not be awaiting_reply when last message is from me")
        }
    }

    func testListChatsGroupFlagAndParticipantCount() async throws {
        let fixture = try makeListCharacterizationFixture()
        let resolver = makeSeededResolver()

        let result = await ListChatsTool.execute(
            limit: 10,
            since: nil,
            isGroup: nil,
            minParticipants: nil,
            maxParticipants: nil,
            sort: "recent",
            db: fixture.database(),
            resolver: resolver
        )

        switch result {
        case .failure(let error):
            XCTFail("list_chats failed: \(error.message)")
        case .success(let response):
            let groupChat = try XCTUnwrap(response.chats.first(where: { $0.id == "chat2" }))
            XCTAssertEqual(groupChat.group, true, "Chat with 3 participants should be flagged as group")
            XCTAssertEqual(groupChat.participantCount, 3, "Trip Crew should report 3 participants")

            let dmChat = try XCTUnwrap(response.chats.first(where: { $0.id == "chat1" }))
            XCTAssertNil(dmChat.group, "DM should not have group flag set")
        }
    }

    // MARK: - get_active_conversations tests

    // For get_active_conversations the messages must fall within the query window.
    // We use the same base date (near-current) so they always qualify.

    private func makeActiveConversationsFixture() throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "active-conversations")

        try fixture.insertHandle(rowId: 1, handle: "+15550000001")  // Alice
        try fixture.insertHandle(rowId: 2, handle: "+15550000002")  // Bob

        // Chat 10: will have 3 my-messages, 2 their-messages → exchanges = min(3,2) = 2
        try fixture.insertChat(rowId: 10, guid: "iMessage;+;active-test-guid")
        try fixture.joinChatHandle(chatId: 10, handleId: 1)

        // Recent timestamps (within last 24 hours)
        let now = Int64(Date().timeIntervalSinceReferenceDate * 1_000_000_000)
        let sec: Int64 = 1_000_000_000

        // 3 from me
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

        // 2 from them (last from them is newest in window)
        try fixture.insertMessage(
            rowId: 200,
            guid: "active-them-200",
            text: "their first",
            date: now - (5 * sec),
            isFromMe: false,
            handleId: 1
        )
        try fixture.joinChatMessage(chatId: 10, messageId: 200)

        // NOTE: last-from-them (msg 201) is newer than last-from-me (msg 102, date = now-8*sec)
        // So awaiting_reply should be true for chat 10
        try fixture.insertMessage(
            rowId: 201,
            guid: "active-them-201",
            text: "their second",
            date: now - (2 * sec),    // newer than any "from me" message
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

    // MARK: - Participant fan-out regression

    // Both list tools used to join chat_handle_join alongside the message
    // tables, which multiplied every chat's message rows by its participant
    // count. Group chats reported inflated totals; DM fixtures hid it because
    // one participant multiplies by one. These two fixtures use group chats.

    private func makeFanOutFixture() throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "participant-fan-out")

        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertHandle(rowId: 2, handle: "+15550000002")
        try fixture.insertHandle(rowId: 3, handle: "+15550000003")

        // Chat 1: DM, 3 messages.
        try fixture.insertChat(rowId: 1, guid: "iMessage;-;fanout-dm")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)

        // Chat 2: group of 3, only 2 messages. Fewer messages than chat 1, but
        // the old query counted 2 x 3 = 6 and ranked it first for most_active.
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

        let result = await ListChatsTool.execute(
            limit: 10,
            sort: "most_active",
            db: fixture.database(),
            resolver: makeSeededResolver()
        )

        guard case .success(let response) = result else {
            return XCTFail("list_chats failed")
        }

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

        // Group of 3 with 2 messages each direction.
        try fixture.insertChat(rowId: 20, guid: "iMessage;+;group-activity", displayName: "Group Activity")
        try fixture.joinChatHandle(chatId: 20, handleId: 1)
        try fixture.joinChatHandle(chatId: 20, handleId: 2)
        try fixture.joinChatHandle(chatId: 20, handleId: 3)

        let now = Int64(Date().timeIntervalSinceReferenceDate * 1_000_000_000)
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
}
