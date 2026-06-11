import XCTest
@testable import iMessageMax

final class ChatSummaryQueriesTests: XCTestCase {

    // MARK: - participantsByChat

    /// Two chats with overlapping participants. Alice is in both; Bob only in chat 2.
    /// The method must group rows by chat ID and resolve contact names.
    func testParticipantsByChatGroupsAndResolves() async throws {
        let fixture = try ToolTestDatabase(name: "csq-participants")
        let resolver = makeSeededResolver()

        try fixture.insertHandle(rowId: 1, handle: "+15550000001")  // Alice
        try fixture.insertHandle(rowId: 2, handle: "+15550000002")  // Bob

        try fixture.insertChat(rowId: 10, guid: "chat-10-guid")
        try fixture.joinChatHandle(chatId: 10, handleId: 1)          // Alice in chat 10

        try fixture.insertChat(rowId: 20, guid: "chat-20-guid")
        try fixture.joinChatHandle(chatId: 20, handleId: 1)          // Alice in chat 20
        try fixture.joinChatHandle(chatId: 20, handleId: 2)          // Bob in chat 20

        let result = try await ChatSummaryQueries.participantsByChat(
            db: fixture.database(),
            chatIds: [10, 20],
            resolver: resolver
        )

        // Chat 10: only Alice
        let chat10 = try XCTUnwrap(result[10], "Expected participants for chatId 10")
        XCTAssertEqual(chat10.count, 1, "Chat 10 should have exactly 1 participant")
        XCTAssertEqual(chat10.first?.handle, "+15550000001")
        XCTAssertEqual(chat10.first?.name, "Alice Smith", "Resolved name should match seeded cache")

        // Chat 20: Alice and Bob
        let chat20 = try XCTUnwrap(result[20], "Expected participants for chatId 20")
        XCTAssertEqual(chat20.count, 2, "Chat 20 should have exactly 2 participants")
        let handles20 = Set(chat20.map(\.handle))
        XCTAssertTrue(handles20.contains("+15550000001"), "Alice should be in chat 20")
        XCTAssertTrue(handles20.contains("+15550000002"), "Bob should be in chat 20")
        let names20 = chat20.compactMap(\.name)
        XCTAssertTrue(names20.contains("Alice Smith"), "Alice's resolved name expected")
        XCTAssertTrue(names20.contains("Bob Brown"), "Bob's resolved name expected")
    }

    // MARK: - lastMessagesByChat

    /// Each chat has an older message, a newer message, and a reaction that is
    /// even newer. The reaction (associated_message_type ≠ 0) must be excluded,
    /// so the newer *non-reaction* message wins for each chat.
    func testLastMessagesByChatPicksNewestNonReactionPerChat() async throws {
        let fixture = try ToolTestDatabase(name: "csq-last-msgs")
        let resolver = makeSeededResolver()

        try fixture.insertHandle(rowId: 1, handle: "+15550000001")  // Alice

        // Chat A and Chat B — each with the same pattern.
        for chatId in [1, 2] {
            try fixture.insertChat(rowId: chatId, guid: "chat-\(chatId)-guid")
            try fixture.joinChatHandle(chatId: chatId, handleId: 1)
        }

        // Apple epoch base: ~1 hour ago, so formatCompactRelative is non-nil.
        let base = Int64(Date().timeIntervalSinceReferenceDate * 1_000_000_000) - 3_600_000_000_000
        let sec: Int64 = 1_000_000_000

        // Chat 1 messages
        try fixture.insertMessage(
            rowId: 101,
            guid: "c1-old",
            text: "older message",
            date: base,
            isFromMe: true
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 101)

        try fixture.insertMessage(
            rowId: 102,
            guid: "c1-new",
            text: "newest message",
            date: base + sec,
            isFromMe: false,
            handleId: 1
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 102)

        // Reaction — even newer but must not be picked.
        try fixture.insertMessage(
            rowId: 103,
            guid: "c1-reaction",
            text: nil,
            date: base + (2 * sec),
            isFromMe: false,
            handleId: 1,
            associatedMessageType: 2000,
            associatedMessageGuid: "c1-new"
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 103)

        // Chat 2 messages (from me this time, so awaitingReply = false)
        try fixture.insertMessage(
            rowId: 201,
            guid: "c2-old",
            text: "chat2 older",
            date: base + (3 * sec),
            isFromMe: false,
            handleId: 1
        )
        try fixture.joinChatMessage(chatId: 2, messageId: 201)

        try fixture.insertMessage(
            rowId: 202,
            guid: "c2-new",
            text: "chat2 newest",
            date: base + (4 * sec),
            isFromMe: true
        )
        try fixture.joinChatMessage(chatId: 2, messageId: 202)

        try fixture.insertMessage(
            rowId: 203,
            guid: "c2-reaction",
            text: nil,
            date: base + (5 * sec),
            isFromMe: true,
            associatedMessageType: 2000,
            associatedMessageGuid: "c2-new"
        )
        try fixture.joinChatMessage(chatId: 2, messageId: 203)

        let result = try await ChatSummaryQueries.lastMessagesByChat(
            db: fixture.database(),
            chatIds: [1, 2],
            resolver: resolver
        )

        // Chat 1: newest non-reaction is msg 102, from Alice.
        let last1 = try XCTUnwrap(result[1], "Expected last message for chatId 1")
        XCTAssertEqual(last1.info.text, "newest message", "Reaction must not be selected")
        XCTAssertEqual(last1.info.from, "Alice Smith", "Sender resolved from contact cache")
        XCTAssertTrue(last1.awaitingReply, "Not from me → awaitingReply = true")

        // Chat 2: newest non-reaction is msg 202, from me.
        let last2 = try XCTUnwrap(result[2], "Expected last message for chatId 2")
        XCTAssertEqual(last2.info.text, "chat2 newest", "Reaction must not be selected")
        XCTAssertEqual(last2.info.from, "Me")
        XCTAssertFalse(last2.awaitingReply, "From me → awaitingReply = false")
    }

    // MARK: - Empty guard

    func testEmptyChatIdsReturnsEmpty() async throws {
        // No fixture needed — the guard path short-circuits before any DB call.
        let fixture = try ToolTestDatabase(name: "csq-empty")
        let resolver = makeSeededResolver()

        let participants = try await ChatSummaryQueries.participantsByChat(
            db: fixture.database(),
            chatIds: [],
            resolver: resolver
        )
        XCTAssertTrue(participants.isEmpty, "Empty chatIds must return empty dict")

        let lastMsgs = try await ChatSummaryQueries.lastMessagesByChat(
            db: fixture.database(),
            chatIds: [],
            resolver: resolver
        )
        XCTAssertTrue(lastMsgs.isEmpty, "Empty chatIds must return empty dict")
    }

    // MARK: - No-messages chat

    /// A chat with participants but zero messages: it appears in participantsByChat
    /// (as an empty array) but not in lastMessagesByChat.
    func testChatWithNoMessagesAbsentFromLastMessages() async throws {
        let fixture = try ToolTestDatabase(name: "csq-no-msgs")
        let resolver = makeSeededResolver()

        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 5, guid: "silent-chat-guid")
        try fixture.joinChatHandle(chatId: 5, handleId: 1)

        let participants = try await ChatSummaryQueries.participantsByChat(
            db: fixture.database(),
            chatIds: [5],
            resolver: resolver
        )
        XCTAssertNotNil(participants[5], "Chat with no messages must still appear in participantsByChat")
        XCTAssertEqual(participants[5]?.count, 1)

        let lastMsgs = try await ChatSummaryQueries.lastMessagesByChat(
            db: fixture.database(),
            chatIds: [5],
            resolver: resolver
        )
        XCTAssertNil(lastMsgs[5], "Chat with no messages must be absent from lastMessagesByChat")
    }
}
