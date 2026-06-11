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
            cursor: nil,
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
            // Participants are resolved from the seeded cache - names, not raw handles
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
            cursor: nil,
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
            // msg11 from Alice should be selected, not the reaction msg12
            XCTAssertEqual(
                lastMsg.text,
                "hello from alice",
                "last_message should be the newest non-reaction, not the reaction"
            )
            // Sender should be Alice's resolved name (not raw handle)
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
            cursor: nil,
            db: fixture.database(),
            resolver: resolver
        )

        switch result {
        case .failure(let error):
            XCTFail("list_chats failed: \(error.message)")
        case .success(let response):
            // DM: last non-reaction message is from Alice (not from me)
            let dmChat = try XCTUnwrap(response.chats.first(where: { $0.id == "chat1" }))
            XCTAssertEqual(dmChat.awaitingReply, true, "DM should be awaiting_reply when last message is from them")

            // Group: last message is from me
            let groupChat = try XCTUnwrap(response.chats.first(where: { $0.id == "chat2" }))
            // awaiting_reply should be false (last message is from me)
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
            cursor: nil,
            db: fixture.database(),
            resolver: resolver
        )

        switch result {
        case .failure(let error):
            XCTFail("list_chats failed: \(error.message)")
        case .success(let response):
            // Chat 2 (Trip Crew): 3 participants → group = true
            let groupChat = try XCTUnwrap(response.chats.first(where: { $0.id == "chat2" }))
            XCTAssertEqual(groupChat.group, true, "Chat with 3 participants should be flagged as group")
            XCTAssertEqual(groupChat.participantCount, 3, "Trip Crew should report 3 participants")

            // Chat 1 (DM): 1 participant → group = nil (encoded as absent)
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
        // 3 my-messages, 2 their-messages → exchanges = min(3, 2) = 2
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
        // last-from-them (msg 201, now-2s) is newer than last-from-me (msg 102, now-8s)
        XCTAssertTrue(
            convo.awaitingReply,
            "awaiting_reply should be true when last-from-them is more recent than last-from-me"
        )
    }
}
