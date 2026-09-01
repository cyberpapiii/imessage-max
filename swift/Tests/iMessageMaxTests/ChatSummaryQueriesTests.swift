import XCTest
@testable import iMessageMax

final class ChatSummaryQueriesTests: XCTestCase {

    // MARK: - participantsByChat

    /// Two chats with overlapping participants. Alice is in both; Bob only in chat 2.
    /// The method must group rows by chat ID and resolve contact names.
    func testParticipantsByChatGroupsAndResolves() async throws {
        let fixture = try ToolTestDatabase(name: "csq-participants")
        let resolver = makeSeededResolver()

        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertHandle(rowId: 2, handle: "+15550000002")

        try fixture.insertChat(rowId: 10, guid: "chat-10-guid")
        try fixture.joinChatHandle(chatId: 10, handleId: 1)

        try fixture.insertChat(rowId: 20, guid: "chat-20-guid")
        try fixture.joinChatHandle(chatId: 20, handleId: 1)
        try fixture.joinChatHandle(chatId: 20, handleId: 2)

        let result = try await ChatSummaryQueries.participantsByChat(
            db: fixture.database(),
            chatIds: [10, 20],
            resolver: resolver
        )

        let chat10 = try XCTUnwrap(result[10], "Expected participants for chatId 10")
        XCTAssertEqual(chat10.count, 1, "Chat 10 should have exactly 1 participant")
        XCTAssertEqual(chat10.first?.handle, "+15550000001")
        XCTAssertEqual(chat10.first?.name, "Alice Smith", "Resolved name should match seeded cache")

        let chat20 = try XCTUnwrap(result[20], "Expected participants for chatId 20")
        XCTAssertEqual(chat20.count, 2, "Chat 20 should have exactly 2 participants")
        let handles20 = Set(chat20.map(\.handle))
        XCTAssertTrue(handles20.contains("+15550000001"), "Alice should be in chat 20")
        XCTAssertTrue(handles20.contains("+15550000002"), "Bob should be in chat 20")
        let names20 = chat20.compactMap(\.name)
        XCTAssertTrue(names20.contains("Alice Smith"), "Alice's resolved name expected")
        XCTAssertTrue(names20.contains("Bob Brown"), "Bob's resolved name expected")
    }

    /// chat_handle_join has no unique constraint, and iCloud sync merges do
    /// leave the same handle joined twice. One participant per handle must
    /// come back, or every dictionary keyed by handle downstream traps.
    func testDuplicateJoinRowsYieldOneParticipantPerHandle() async throws {
        let fixture = try ToolTestDatabase(name: "csq-duplicate-join")
        let resolver = makeSeededResolver()

        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 10, guid: "chat-10-guid")
        try fixture.joinChatHandle(chatId: 10, handleId: 1)
        try fixture.joinChatHandle(chatId: 10, handleId: 1)

        let result = try await ChatSummaryQueries.participantsByChat(
            db: fixture.database(),
            chatIds: [10],
            resolver: resolver
        )

        let chat10 = try XCTUnwrap(result[10], "Expected participants for chatId 10")
        XCTAssertEqual(chat10.count, 1, "Duplicate join rows must collapse to one participant")
        XCTAssertEqual(chat10.first?.handle, "+15550000001")
        XCTAssertEqual(chat10.first?.name, "Alice Smith")
    }

    /// The other participant queries still read chat_handle_join without
    /// DISTINCT, so the preview formatter has to survive a duplicate handle in
    /// the participant list it is handed. Small chat: only `previewNames` runs.
    func testDisplayNameWithDuplicateParticipantsDoesNotTrap() async throws {
        let fixture = try ToolTestDatabase(name: "csq-duplicate-preview")

        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertHandle(rowId: 2, handle: "+15550000002")
        try fixture.insertChat(rowId: 10, guid: "chat-10-guid")
        try fixture.joinChatHandle(chatId: 10, handleId: 1)
        try fixture.joinChatHandle(chatId: 10, handleId: 1)
        try fixture.joinChatHandle(chatId: 10, handleId: 2)

        let db = fixture.database()
        let identity = try await makeIdentityFromRawJoinRows(db: db, chatId: 10, explicitName: nil)
        XCTAssertEqual(identity.participants.map(\.handle), ["+15550000001", "+15550000001", "+15550000002"])

        let preview = try ChatSummaryBuilder.participantsPreview(db: db, chatId: 10, identity: identity)

        XCTAssertEqual(preview.count, 2)
        XCTAssertTrue(preview.contains("Bob Brown"))
        XCTAssertEqual(preview.filter { $0.hasPrefix("Alice Smith") }.count, 1)
        XCTAssertFalse(preview.contains(where: { $0.contains("(0001)") }))
    }

    /// Duplicate join rows used to look like two people with the same contact
    /// name, so the small-chat formatter appended a handle suffix. First handle
    /// wins; Alice stays "Alice Smith".
    func testSmallChatNameOmitsSuffixForDuplicateHandle() async throws {
        let fixture = try ToolTestDatabase(name: "csq-duplicate-suffix")

        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertHandle(rowId: 2, handle: "+15550000002")
        try fixture.insertChat(rowId: 10, guid: "chat-10-guid")
        try fixture.joinChatHandle(chatId: 10, handleId: 1)
        try fixture.joinChatHandle(chatId: 10, handleId: 1)
        try fixture.joinChatHandle(chatId: 10, handleId: 2)

        let db = fixture.database()
        let identity = try await makeIdentityFromRawJoinRows(db: db, chatId: 10, explicitName: nil)
        XCTAssertEqual(identity.participants.map(\.handle), ["+15550000001", "+15550000001", "+15550000002"])

        let preview = try ChatSummaryBuilder.participantsPreview(db: db, chatId: 10, identity: identity)
        XCTAssertFalse(
            preview.contains(where: { $0.contains("(0001)") }),
            "small-chat preview must not suffix a duplicated handle: \(preview)"
        )
        XCTAssertEqual(IdentityDisplayFormatter.participants(identity.participants).map(\.name), [
            "Alice Smith",
            "Bob Brown",
        ])
    }

    /// Named chats with more than four participants take the recent-sender
    /// path, which builds its own handle-keyed dictionary. Same duplicate,
    /// different trap.
    func testLargeNamedChatWithDuplicateParticipantsDoesNotTrap() async throws {
        let fixture = try ToolTestDatabase(name: "csq-duplicate-preview-large")

        for rowId in 1...5 {
            try fixture.insertHandle(rowId: rowId, handle: "+1555000000\(rowId)")
        }
        try fixture.insertChat(rowId: 10, guid: "chat-10-guid", displayName: "Weekend Plans")
        try fixture.joinChatHandle(chatId: 10, handleId: 1)
        for rowId in 1...5 {
            try fixture.joinChatHandle(chatId: 10, handleId: rowId)
        }
        try fixture.insertMessage(
            rowId: 100,
            guid: "msg-100",
            text: "who is in?",
            date: 700_000_000_000_000_000,
            isFromMe: false,
            handleId: 3
        )
        try fixture.joinChatMessage(chatId: 10, messageId: 100)

        let db = fixture.database()
        let identity = try await makeIdentityFromRawJoinRows(db: db, chatId: 10, explicitName: "Weekend Plans")
        XCTAssertEqual(identity.participants.count, 6)
        XCTAssertTrue(identity.isNamed)

        let preview = try ChatSummaryBuilder.participantsPreview(db: db, chatId: 10, identity: identity)

        XCTAssertEqual(preview.count, 4, "three names plus the remainder marker")
        XCTAssertEqual(preview.first, "Chris Green", "most recent sender leads the preview")
        XCTAssertEqual(preview.last, "+3 more")
    }

    /// Builds a `ChatIdentity` the way the non-batched tools still do: a
    /// plain join over chat_handle_join with no de-duplication.
    private func makeIdentityFromRawJoinRows(
        db: Database,
        chatId: Int64,
        explicitName: String?
    ) async throws -> ChatIdentity {
        let resolver = makeSeededResolver()
        let handles = try db.query(
            """
            SELECT h.id
            FROM chat_handle_join chj
            JOIN handle h ON chj.handle_id = h.ROWID
            WHERE chj.chat_id = ?
            ORDER BY chj.rowid
            """,
            params: [chatId]
        ) { row in row.string(0) ?? "" }

        var participants: [ChatIdentity.Participant] = []
        for handle in handles {
            let name = await resolver.resolve(handle)
            participants.append(ChatIdentity.makeParticipant(handle: handle, contactName: name))
        }
        return ChatIdentity(
            mcpId: "chat\(chatId)",
            guid: "chat-\(chatId)-guid",
            explicitName: explicitName,
            participants: participants
        )
    }

    // MARK: - lastMessagesByChat

    /// Each chat has an older message, a newer message, and a reaction that is
    /// even newer. The reaction (associated_message_type ≠ 0) must be excluded,
    /// so the newer *non-reaction* message wins for each chat.
    func testLastMessagesByChatPicksNewestNonReactionPerChat() async throws {
        let fixture = try ToolTestDatabase(name: "csq-last-msgs")
        let resolver = makeSeededResolver()

        try fixture.insertHandle(rowId: 1, handle: "+15550000001")

        // Chat A and Chat B, each with the same pattern.
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

        // Reaction. Even newer, but it must not be picked.
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

        let last1 = try XCTUnwrap(result[1], "Expected last message for chatId 1")
        XCTAssertEqual(last1.info.text, "newest message", "Reaction must not be selected")
        XCTAssertEqual(last1.info.from, "Alice Smith", "Sender resolved from contact cache")
        XCTAssertTrue(last1.awaitingReply, "Not from me → awaitingReply = true")

        let last2 = try XCTUnwrap(result[2], "Expected last message for chatId 2")
        XCTAssertEqual(last2.info.text, "chat2 newest", "Reaction must not be selected")
        XCTAssertEqual(last2.info.from, "Me")
        XCTAssertFalse(last2.awaitingReply, "From me → awaitingReply = false")
    }

    // MARK: - Empty guard

    func testEmptyChatIdsReturnsEmpty() async throws {
        // Empty chatIds short-circuits before querying; fixture still needed for Database handle.
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

    // MARK: - Formatting parameterization

    /// previewMaxLength and unknownSenderLabel must be honored so callers can
    /// preserve their historical output (GetActiveConversations: 80 / "Unknown").
    func testFormattingParametersAreHonored() async throws {
        let fixture = try ToolTestDatabase(name: "csq-params")
        let resolver = makeSeededResolver()

        try fixture.insertChat(rowId: 1, guid: "params-chat-guid")

        let base = Int64(Date().timeIntervalSinceReferenceDate * 1_000_000_000) - 3_600_000_000_000

        // Incoming message with NO handle (handleId nil, isFromMe false)
        // → sender falls back to unknownSenderLabel.
        let longText = String(repeating: "a", count: 200)
        try fixture.insertMessage(
            rowId: 1,
            guid: "params-msg",
            text: longText,
            date: base,
            isFromMe: false
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 1)

        let custom = try await ChatSummaryQueries.lastMessagesByChat(
            db: fixture.database(),
            chatIds: [1],
            resolver: resolver,
            previewMaxLength: 80,
            unknownSenderLabel: "Unknown",
            agoFallback: nil
        )
        let customLast = try XCTUnwrap(custom[1])
        XCTAssertEqual(customLast.info.from, "Unknown", "Custom unknown-sender label must be used")
        XCTAssertEqual(customLast.info.text.count, 80, "Preview must be truncated to maxLength 80")

        let defaults = try await ChatSummaryQueries.lastMessagesByChat(
            db: fixture.database(),
            chatIds: [1],
            resolver: resolver
        )
        let defaultLast = try XCTUnwrap(defaults[1])
        XCTAssertEqual(defaultLast.info.from, "unknown", "Default unknown-sender label is lowercase")
        XCTAssertEqual(defaultLast.info.text.count, 50, "Default preview maxLength is 50")
    }

    // MARK: - Unread-inbound filter

    /// With `onlyUnreadInbound: true`, read messages and messages from me are
    /// skipped, so the newest *unread inbound* message wins. With the flag
    /// false (default), the overall newest non-reaction message wins.
    func testOnlyUnreadInboundFilter() async throws {
        let fixture = try ToolTestDatabase(name: "csq-unread-inbound")
        let resolver = makeSeededResolver()

        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 1, guid: "unread-filter-guid")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)

        let base = Int64(Date().timeIntervalSinceReferenceDate * 1_000_000_000) - 3_600_000_000_000
        let sec: Int64 = 1_000_000_000

        // Oldest: unread inbound, the one the filter must select.
        try fixture.insertMessage(
            rowId: 1,
            guid: "unread-inbound",
            text: "unread from alice",
            date: base,
            isFromMe: false,
            isRead: false,
            handleId: 1
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 1)

        // Newer: inbound but already read.
        try fixture.insertMessage(
            rowId: 2,
            guid: "read-inbound",
            text: "read from alice",
            date: base + sec,
            isFromMe: false,
            isRead: true,
            handleId: 1
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 2)

        // Newest: from me.
        try fixture.insertMessage(
            rowId: 3,
            guid: "from-me",
            text: "my reply",
            date: base + (2 * sec),
            isFromMe: true
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 3)

        let unreadOnly = try await ChatSummaryQueries.lastMessagesByChat(
            db: fixture.database(),
            chatIds: [1],
            resolver: resolver,
            onlyUnreadInbound: true
        )
        let unreadLast = try XCTUnwrap(unreadOnly[1], "Expected an unread-inbound match for chat 1")
        XCTAssertEqual(unreadLast.info.text, "unread from alice", "Newest unread inbound must win")
        XCTAssertEqual(unreadLast.info.from, "Alice Smith")

        let newest = try await ChatSummaryQueries.lastMessagesByChat(
            db: fixture.database(),
            chatIds: [1],
            resolver: resolver
        )
        let newestLast = try XCTUnwrap(newest[1])
        XCTAssertEqual(newestLast.info.text, "my reply", "Default behavior picks the overall newest message")
        XCTAssertEqual(newestLast.info.from, "Me")
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

    // MARK: - Pinned newest dates

    /// The pinned lookup states the newest date instead of sorting to find it.
    /// It has to pick the same message as the search does, including when two
    /// messages in a chat carry the identical date and the highest ROWID wins.
    func testPinnedNewestDateSelectsTheSameMessageAsTheSearch() async throws {
        let fixture = try ToolTestDatabase(name: "csq-pinned")
        let resolver = makeSeededResolver()
        let newest: Int64 = 700_000_000_000_000_000

        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 10, guid: "chat-10-guid")
        try fixture.joinChatHandle(chatId: 10, handleId: 1)

        let messages: [(Int, String, Int64)] = [
            (1, "older", newest - 86_400_000_000_000),
            (2, "tied loser", newest),
            (3, "tied winner", newest),
        ]
        for (rowId, text, date) in messages {
            try fixture.insertMessage(
                rowId: rowId,
                guid: "msg-\(rowId)",
                text: text,
                date: date,
                isFromMe: false,
                handleId: 1
            )
            try fixture.joinChatMessage(chatId: 10, messageId: rowId)
        }

        let searched = try await ChatSummaryQueries.lastMessagesByChat(
            db: fixture.database(),
            chatIds: [10],
            resolver: resolver
        )
        let pinned = try await ChatSummaryQueries.lastMessagesByChat(
            db: fixture.database(),
            chatIds: [10],
            resolver: resolver,
            newestDates: [10: newest]
        )

        XCTAssertEqual(searched[10]?.info.text, "tied winner")
        XCTAssertEqual(pinned[10]?.info.text, searched[10]?.info.text)
        XCTAssertEqual(pinned[10]?.info.ts, searched[10]?.info.ts)
        XCTAssertEqual(pinned[10]?.awaitingReply, searched[10]?.awaitingReply)
    }

    /// A partially covered batch has to keep the search: dropping the chats
    /// without a pinned date would silently drop their previews.
    func testPartiallyPinnedBatchStillReturnsEveryChat() async throws {
        let fixture = try ToolTestDatabase(name: "csq-pinned-partial")
        let resolver = makeSeededResolver()

        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        for (index, chatId) in [10, 20].enumerated() {
            try fixture.insertChat(rowId: chatId, guid: "chat-\(chatId)-guid")
            try fixture.joinChatHandle(chatId: chatId, handleId: 1)
            let rowId = index + 1
            try fixture.insertMessage(
                rowId: rowId,
                guid: "msg-\(rowId)",
                text: "hello \(chatId)",
                date: Int64(700_000_000 + index) * 1_000_000_000,
                isFromMe: false,
                handleId: 1
            )
            try fixture.joinChatMessage(chatId: chatId, messageId: rowId)
        }

        let result = try await ChatSummaryQueries.lastMessagesByChat(
            db: fixture.database(),
            chatIds: [10, 20],
            resolver: resolver,
            newestDates: [10: 700_000_000_000_000_000]
        )

        XCTAssertEqual(result[10]?.info.text, "hello 10")
        XCTAssertEqual(result[20]?.info.text, "hello 20")
    }

    /// get_unread pins the newest *unread inbound* date, which is not the
    /// chat's newest message. The pinned lookup has to keep the unread filter,
    /// or it hands back a message that is not unread.
    func testPinnedUnreadLookupSkipsNewerReadMessages() async throws {
        let fixture = try ToolTestDatabase(name: "csq-pinned-unread")
        let resolver = makeSeededResolver()
        let unreadDate: Int64 = 700_000_000_000_000_000

        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 10, guid: "chat-10-guid")
        try fixture.joinChatHandle(chatId: 10, handleId: 1)

        let messages: [(Int, String, Int64, Bool)] = [
            (1, "old unread", unreadDate - 86_400_000_000_000, false),
            (2, "newest unread", unreadDate, false),
            // Same instant, higher ROWID: a pinned lookup that dropped the
            // unread filter would tie-break straight onto this one.
            (3, "read reply", unreadDate, true),
        ]
        for (rowId, text, date, isRead) in messages {
            try fixture.insertMessage(
                rowId: rowId,
                guid: "msg-\(rowId)",
                text: text,
                date: date,
                isFromMe: false,
                isRead: isRead,
                handleId: 1
            )
            try fixture.joinChatMessage(chatId: 10, messageId: rowId)
        }

        let searched = try await ChatSummaryQueries.lastMessagesByChat(
            db: fixture.database(),
            chatIds: [10],
            resolver: resolver,
            onlyUnreadInbound: true
        )
        let pinned = try await ChatSummaryQueries.lastMessagesByChat(
            db: fixture.database(),
            chatIds: [10],
            resolver: resolver,
            onlyUnreadInbound: true,
            newestDates: [10: unreadDate]
        )

        XCTAssertEqual(searched[10]?.info.text, "newest unread")
        XCTAssertEqual(pinned[10]?.info.text, searched[10]?.info.text)
    }
}
