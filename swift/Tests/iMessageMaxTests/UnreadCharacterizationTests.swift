import XCTest
import MCP
@testable import iMessageMax

// Characterization tests for get_unread summary mode.
// These lock in the current behavior so that the batched-query migration
// (ChatSummaryQueries) cannot silently change participant resolution,
// latest-unread-message selection, or per-chat/total unread counts.

final class UnreadCharacterizationTests: XCTestCase {

    // MARK: - Shared fixture

    // Chat 1 (DM): Alice only
    //   msg 10 from me (oldest)
    //   msg 11 from Alice, READ (must not count or be selected)
    //   msg 12 from Alice, unread "first unread from alice"
    //   msg 13 from Alice, unread "second unread from alice" ← newest unread message
    //   msg 14 from Alice, unread reaction (associated_message_type = 2000),
    //          NEWER than msg 13 — must be ignored everywhere
    // Chat 2 (DM): Bob only
    //   msg 20 from Bob, unread "bob unread"
    // Chat 3 (DM): Alice only
    //   msg 30 from Alice, READ — chat must be excluded entirely

    private func makeUnreadFixture() throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "unread-characterization")

        try fixture.insertHandle(rowId: 1, handle: "+15550000001")  // Alice
        try fixture.insertHandle(rowId: 2, handle: "+15550000002")  // Bob

        try fixture.insertChat(rowId: 1, guid: "iMessage;-;unread-alice-guid")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)

        try fixture.insertChat(rowId: 2, guid: "iMessage;-;unread-bob-guid")
        try fixture.joinChatHandle(chatId: 2, handleId: 2)

        try fixture.insertChat(rowId: 3, guid: "iMessage;-;read-only-guid")
        try fixture.joinChatHandle(chatId: 3, handleId: 1)

        // Apple epoch: nanoseconds since 2001-01-01; ~1 hour ago so the
        // default "7d" window includes everything and ago is non-nil.
        let base = Int64(Date().timeIntervalSinceReferenceDate * 1_000_000_000) - 3_600_000_000_000
        let sec: Int64 = 1_000_000_000

        // Chat 1 messages
        try fixture.insertMessage(
            rowId: 10,
            guid: "msg10",
            text: "hey alice",
            date: base,
            isFromMe: true
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 10)

        try fixture.insertMessage(
            rowId: 11,
            guid: "msg11",
            text: "already read",
            date: base + sec,
            isFromMe: false,
            isRead: true,
            handleId: 1
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 11)

        try fixture.insertMessage(
            rowId: 12,
            guid: "msg12",
            text: "first unread from alice",
            date: base + (2 * sec),
            isFromMe: false,
            isRead: false,
            handleId: 1
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 12)

        try fixture.insertMessage(
            rowId: 13,
            guid: "msg13",
            text: "second unread from alice",
            date: base + (3 * sec),
            isFromMe: false,
            isRead: false,
            handleId: 1
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 13)

        // Unread reaction from Alice — newer than every unread message but
        // must never be selected or counted (associated_message_type != 0).
        try fixture.insertMessage(
            rowId: 14,
            guid: "msg14",
            text: nil,
            date: base + (4 * sec),
            isFromMe: false,
            isRead: false,
            handleId: 1,
            associatedMessageType: 2000,
            associatedMessageGuid: "msg13"
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 14)

        // Chat 2 messages
        try fixture.insertMessage(
            rowId: 20,
            guid: "msg20",
            text: "bob unread",
            date: base + (5 * sec),
            isFromMe: false,
            isRead: false,
            handleId: 2
        )
        try fixture.joinChatMessage(chatId: 2, messageId: 20)

        // Chat 3: only a read message — chat excluded from summary
        try fixture.insertMessage(
            rowId: 30,
            guid: "msg30",
            text: "old news",
            date: base + (6 * sec),
            isFromMe: false,
            isRead: true,
            handleId: 1
        )
        try fixture.joinChatMessage(chatId: 3, messageId: 30)

        return fixture
    }

    private func runSummary(_ fixture: ToolTestDatabase) async throws -> UnreadSummaryResponse {
        let tool = GetUnread(database: fixture.database(), contactResolver: makeSeededResolver())
        let responseAny = try await tool.execute(params: GetUnread.Parameters(format: .summary))
        return try XCTUnwrap(responseAny as? UnreadSummaryResponse, "Expected unread summary response")
    }

    // MARK: - Tests

    func testUnreadSummaryResolvesParticipants() async throws {
        let fixture = try makeUnreadFixture()
        let response = try await runSummary(fixture)

        let aliceChat = try XCTUnwrap(
            response.chats.first(where: { $0.chat.id == "chat1" }),
            "Expected chat1 (Alice DM) in unread summary"
        )
        // Participants resolved from the seeded contact cache — names, not handles.
        XCTAssertEqual(aliceChat.chat.name, "Alice Smith", "Unnamed DM takes the resolved participant name")
        XCTAssertEqual(aliceChat.chat.participantsPreview, ["Alice Smith"])
        XCTAssertFalse(
            aliceChat.chat.participantsPreview.contains("+15550000001"),
            "Raw handle should not appear when contact name is available"
        )

        let bobChat = try XCTUnwrap(response.chats.first(where: { $0.chat.id == "chat2" }))
        XCTAssertEqual(bobChat.chat.participantsPreview, ["Bob Brown"])
    }

    func testUnreadSummaryLastMessageIsNewestUnreadInboundNonReaction() async throws {
        let fixture = try makeUnreadFixture()
        let response = try await runSummary(fixture)

        let aliceChat = try XCTUnwrap(response.chats.first(where: { $0.chat.id == "chat1" }))
        let lastMessage = try XCTUnwrap(aliceChat.lastMessage, "Expected last_message on chat1")
        // msg13 wins: newest unread inbound non-reaction. The read msg11 and
        // the even-newer unread reaction msg14 must both be skipped.
        XCTAssertEqual(lastMessage.text, "second unread from alice")
        XCTAssertEqual(lastMessage.from, "Alice Smith", "from should be the resolved sender name")

        let bobChat = try XCTUnwrap(response.chats.first(where: { $0.chat.id == "chat2" }))
        let bobLast = try XCTUnwrap(bobChat.lastMessage)
        XCTAssertEqual(bobLast.text, "bob unread")
        XCTAssertEqual(bobLast.from, "Bob Brown")
    }

    func testUnreadSummaryCountsPerChatAndTotal() async throws {
        let fixture = try makeUnreadFixture()
        let response = try await runSummary(fixture)

        let aliceChat = try XCTUnwrap(response.chats.first(where: { $0.chat.id == "chat1" }))
        XCTAssertEqual(aliceChat.unreadCount, 2, "Chat1 has 2 unread inbound non-reaction messages")

        let bobChat = try XCTUnwrap(response.chats.first(where: { $0.chat.id == "chat2" }))
        XCTAssertEqual(bobChat.unreadCount, 1)

        XCTAssertEqual(response.totalUnread, 3)
        XCTAssertEqual(response.chatsWithUnread, 2)
        XCTAssertEqual(response.chats.count, 2)
    }

    func testChatWithOnlyReadMessagesExcluded() async throws {
        let fixture = try makeUnreadFixture()
        let response = try await runSummary(fixture)

        XCTAssertNil(
            response.chats.first(where: { $0.chat.id == "chat3" }),
            "A chat whose messages are all read must not appear in the unread summary"
        )
    }
}
