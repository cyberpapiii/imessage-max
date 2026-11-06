import MCP
import XCTest
@testable import iMessageMax

/// The participant preview and last-message summary every chat-listing tool
/// shows, read from the tools' JSON.
final class ChatSummaryTests: XCTestCase {

    // MARK: - Duplicate chat_handle_join rows

    /// chat_handle_join has no unique constraint, and iCloud sync merges do
    /// leave the same handle joined twice. One participant per handle must
    /// come back: no double count, no "(0001)" suffix, no trap.
    func testDuplicateJoinRowsCountAsOneParticipant() async throws {
        let fixture = try ToolTestDatabase(name: "summary-duplicate-join")
        for rowId in 1...5 {
            try fixture.insertHandle(rowId: rowId, handle: "+1555000000\(rowId)")
        }
        // chat10: unnamed, Alice joined twice, plus Bob.
        try fixture.insertChat(rowId: 10, guid: "chat-10-guid")
        for handleId in [1, 1, 2] {
            try fixture.joinChatHandle(chatId: 10, handleId: handleId)
        }
        // chat20: named, five people, Alice joined twice. Chris spoke last.
        try fixture.insertChat(rowId: 20, guid: "chat-20-guid", displayName: "Weekend Plans")
        for handleId in [1, 1, 2, 3, 4, 5] {
            try fixture.joinChatHandle(chatId: 20, handleId: handleId)
        }
        try fixture.insertMessage(rowId: 100, guid: "msg-100", text: "hi", date: 700_000_000_000_000_000, isFromMe: false, handleId: 1)
        try fixture.joinChatMessage(chatId: 10, messageId: 100)
        try fixture.insertMessage(rowId: 200, guid: "msg-200", text: "who is in?", date: 700_000_000_000_000_000, isFromMe: false, handleId: 3)
        try fixture.joinChatMessage(chatId: 20, messageId: 200)

        let chats = try await listChats(fixture)

        let small = try XCTUnwrap(chats["chat10"])
        XCTAssertEqual(small["participant_count"] as? Int, 2)
        XCTAssertEqual(small["participants_preview"] as? [String], ["Alice Smith", "Bob Brown"])

        let named = try XCTUnwrap(chats["chat20"])
        XCTAssertEqual(named["participant_count"] as? Int, 5)
        let preview = try XCTUnwrap(named["participants_preview"] as? [String])
        XCTAssertEqual(preview.first, "Chris Green", "most recent sender leads the preview")
        XCTAssertEqual(preview.last, "+2 more")
        XCTAssertFalse(preview.contains { $0.contains("(0001)") }, "\(preview)")
    }

    // MARK: - Participant preview

    /// Six handles. Newest inbound non-reactions come from handles 3, 3, 5, 1;
    /// a newer outbound row and a reaction from handle 6 must not count.
    /// Named: the first three distinct recent senders, then "+3 more".
    /// Unnamed: contact names first, alphabetical, recency ignored.
    func testNamedChatPreviewLeadsWithRecentSendersAndUnnamedIsAlphabetical() async throws {
        let fixture = try ToolTestDatabase(name: "summary-preview")
        for rowId in 1...6 {
            try fixture.insertHandle(rowId: rowId, handle: "+1555000000\(rowId)")
        }
        let base: Int64 = 700_000_000_000_000_000
        let sec: Int64 = 1_000_000_000
        for (chatId, name) in [(10, "Big Group" as String?), (20, nil)] {
            try fixture.insertChat(rowId: chatId, guid: "chat-\(chatId)-guid", displayName: name)
            for handleId in 1...6 {
                try fixture.joinChatHandle(chatId: chatId, handleId: handleId)
            }
            let inbound: [(Int, Int64)] = [(3, 4), (3, 3), (5, 2), (1, 1)]
            for (index, (handleId, offset)) in inbound.enumerated() {
                let rowId = chatId * 10 + index
                try fixture.insertMessage(rowId: rowId, guid: "msg-\(rowId)", text: "inbound \(rowId)", date: base + offset * sec, isFromMe: false, handleId: handleId)
                try fixture.joinChatMessage(chatId: chatId, messageId: rowId)
            }
            let outbound = chatId * 10 + 5
            try fixture.insertMessage(rowId: outbound, guid: "msg-\(outbound)", text: "outbound", date: base + 5 * sec, isFromMe: true)
            try fixture.joinChatMessage(chatId: chatId, messageId: outbound)
            let reaction = chatId * 10 + 6
            try fixture.insertMessage(
                rowId: reaction, guid: "msg-\(reaction)", date: base + 6 * sec, isFromMe: false, handleId: 6,
                associatedMessageType: 2000, associatedMessageGuid: "msg-\(chatId * 10)"
            )
            try fixture.joinChatMessage(chatId: chatId, messageId: reaction)
        }

        let chats = try await listChats(fixture)
        XCTAssertEqual(
            chats["chat10"]?["participants_preview"] as? [String],
            ["Chris Green", "+1 (555) 000-0005", "Alice Smith", "+3 more"]
        )
        XCTAssertEqual(
            chats["chat20"]?["participants_preview"] as? [String],
            ["Alice Smith", "Bob Brown", "Chris Green", "+3 more"]
        )
    }

    // MARK: - Last message

    /// The page's newest date is pinned per chat; a tie on that date goes to
    /// the higher ROWID, the same row an unpinned search would pick. A chat
    /// with no messages has no pinned date, and must neither lose the other
    /// chats' previews nor gain one of its own. An attachment-only message
    /// previews as its attachment.
    func testLastMessagePicksTheTiedHigherRowIdAndSkipsEmptyChats() async throws {
        let fixture = try ToolTestDatabase(name: "summary-last-message")
        let newest: Int64 = 700_000_000_000_000_000
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        for chatId in [10, 20, 30] {
            try fixture.insertChat(rowId: chatId, guid: "chat-\(chatId)-guid", displayName: "Chat \(chatId)")
            try fixture.joinChatHandle(chatId: chatId, handleId: 1)
        }
        let tied: [(Int, String?, Int64)] = [
            (1, "older", newest - 86_400_000_000_000),
            (2, "tied loser", newest),
            (3, "tied winner", newest),
        ]
        for (rowId, text, date) in tied {
            try fixture.insertMessage(rowId: rowId, guid: "msg-\(rowId)", text: text, date: date, isFromMe: false, handleId: 1)
            try fixture.joinChatMessage(chatId: 10, messageId: rowId)
        }
        try fixture.insertMessage(rowId: 4, guid: "msg-4", text: nil, date: newest - 1, isFromMe: false, handleId: 1)
        try fixture.joinChatMessage(chatId: 20, messageId: 4)
        try fixture.insertAttachment(rowId: 1, filename: "photo.jpg", mimeType: "image/jpeg", uti: "public.jpeg")
        try fixture.joinMessageAttachment(messageId: 4, attachmentId: 1)

        let chats = try await listChats(fixture)
        let tiedChat = try XCTUnwrap(chats["chat10"]?["last_message"] as? [String: Any])
        XCTAssertEqual(tiedChat["text"] as? String, "tied winner")
        let photoChat = try XCTUnwrap(chats["chat20"]?["last_message"] as? [String: Any])
        XCTAssertEqual(photoChat["text"] as? String, "[Photo]")
        let empty = try XCTUnwrap(chats["chat30"])
        XCTAssertNil(empty["last_message"])
    }

    /// get_unread pins the newest *unread inbound* date. A read reply at the
    /// same instant with a higher ROWID must not take over the preview.
    func testUnreadPreviewIgnoresAReadMessageTiedWithTheNewestUnread() async throws {
        let fixture = try ToolTestDatabase(name: "summary-unread-tie")
        let unreadDate = AppleTime.fromDate(Date().addingTimeInterval(-3600))
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 10, guid: "chat-10-guid")
        try fixture.joinChatHandle(chatId: 10, handleId: 1)
        let messages: [(Int, String, Int64, Bool)] = [
            (1, "old unread", unreadDate - 60_000_000_000, false),
            (2, "newest unread", unreadDate, false),
            (3, "read reply", unreadDate, true),
        ]
        for (rowId, text, date, isRead) in messages {
            try fixture.insertMessage(rowId: rowId, guid: "msg-\(rowId)", text: text, date: date, isFromMe: false, isRead: isRead, handleId: 1)
            try fixture.joinChatMessage(chatId: 10, messageId: rowId)
        }

        let json = try await callTool("get_unread", ["since": .string("all")], database: fixture.database())
        let chat = try XCTUnwrap(decodeJSONArray(json["chats"]).first)
        let last = try XCTUnwrap(chat["last_message"] as? [String: Any])
        XCTAssertEqual(last["text"] as? String, "newest unread")
        XCTAssertEqual(last["from"] as? String, "Alice Smith")
    }

    /// An inbound row with no handle and a long text. list_chats previews
    /// 50 characters from "unknown"; get_active_conversations and
    /// get_chat_details preview 80 from "Unknown".
    func testPreviewLengthAndUnknownSenderPerTool() async throws {
        let fixture = try ToolTestDatabase(name: "summary-preview-format")
        let now = Date()
        try fixture.insertChat(rowId: 1, guid: "format-chat-guid", displayName: "Format")
        try fixture.insertMessage(rowId: 1, guid: "mine", text: "ping", date: AppleTime.fromDate(now.addingTimeInterval(-7200)), isFromMe: true)
        try fixture.joinChatMessage(chatId: 1, messageId: 1)
        try fixture.insertMessage(rowId: 2, guid: "theirs", text: String(repeating: "a", count: 200), date: AppleTime.fromDate(now.addingTimeInterval(-3600)), isFromMe: false)
        try fixture.joinChatMessage(chatId: 1, messageId: 2)

        let listedChats = try await listChats(fixture)
        let listed = try XCTUnwrap(listedChats["chat1"]?["last_message"] as? [String: Any])
        XCTAssertEqual(listed["from"] as? String, "unknown")
        XCTAssertEqual((listed["text"] as? String)?.count, 50)

        let active = try await callTool("get_active_conversations", ["min_exchanges": .int(1)], database: fixture.database())
        let conversation = try XCTUnwrap(decodeJSONArray(active["conversations"]).first)
        let activeLast = try XCTUnwrap(conversation["last_message"] as? [String: Any])
        XCTAssertEqual(activeLast["from"] as? String, "Unknown")
        XCTAssertEqual((activeLast["text"] as? String)?.count, 80)
    }

    /// list_chats JSON keyed by chat id.
    private func listChats(_ fixture: ToolTestDatabase) async throws -> [String: [String: Any]] {
        let json = try await callTool("list_chats", ["limit": .int(50)], database: fixture.database())
        let chats = try decodeJSONArray(json["chats"])
        return Dictionary(uniqueKeysWithValues: chats.compactMap { chat in
            (chat["id"] as? String).map { ($0, chat) }
        })
    }

    // MARK: - awaiting_reply and group events

    /// A group event after my reply is neither their message nor an
    /// exchange: the chat is not awaiting my reply in list_chats,
    /// get_chat_details or get_active_conversations.
    func testGroupEventIsNotAwaitingReplyOrAnExchange() async throws {
        let fixture = try groupFixture(name: "awaiting-events")
        let recent = AppleTime.fromDate(Date().addingTimeInterval(-3600))
        try fixture.insertMessage(rowId: 1, guid: "g1", text: "dinner?", date: recent, isFromMe: false, isRead: true, handleId: 1)
        try fixture.insertMessage(rowId: 2, guid: "g2", text: "yes", date: recent + 1_000, isFromMe: true)
        try fixture.insertMessage(rowId: 3, guid: "g3", text: nil, date: recent + 2_000, isFromMe: false, isRead: true, handleId: 2, itemType: 3)
        for row in 1...3 { try fixture.joinChatMessage(chatId: 1, messageId: row) }

        let listed = try await callTool("list_chats", [:], database: fixture.database())
        let chat = try XCTUnwrap(try decodeJSONArray(listed["chats"]).first)
        XCTAssertNotEqual(chat["awaiting_reply"] as? Bool, true)

        let details = try await callTool("get_chat_details", ["chat_id": "chat1"], database: fixture.database())
        XCTAssertNotEqual(details["awaiting_reply"] as? Bool, true)

        let active = try await callTool("get_active_conversations", ["min_exchanges": 1], database: fixture.database())
        let conversation = try XCTUnwrap(try decodeJSONArray(active["conversations"]).first)
        XCTAssertEqual(conversation["awaiting_reply"] as? Bool, false)
        let activity = try XCTUnwrap(conversation["activity"] as? [String: Any])
        XCTAssertEqual(activity["their_msgs"] as? Int, 1)
    }

    /// A group event of mine after their question does not count as my
    /// reply: the chat is still awaiting it.
    func testAwaitingReplyLooksPastAGroupEventToTheirMessage() async throws {
        let fixture = try groupFixture(name: "awaiting-past-event")
        let recent = AppleTime.fromDate(Date().addingTimeInterval(-3600))
        try fixture.insertMessage(rowId: 1, guid: "g1", text: "yes", date: recent, isFromMe: true)
        try fixture.insertMessage(rowId: 2, guid: "g2", text: "dinner?", date: recent + 1_000, isFromMe: false, isRead: true, handleId: 1)
        try fixture.insertMessage(rowId: 3, guid: "g3", text: nil, date: recent + 2_000, isFromMe: true, itemType: 2, groupTitle: "Dinner")
        for row in 1...3 { try fixture.joinChatMessage(chatId: 1, messageId: row) }

        let listed = try await callTool("list_chats", [:], database: fixture.database())
        XCTAssertEqual(try decodeJSONArray(listed["chats"]).first?["awaiting_reply"] as? Bool, true)
        let active = try await callTool("get_active_conversations", ["min_exchanges": 1], database: fixture.database())
        XCTAssertEqual(try decodeJSONArray(active["conversations"]).first?["awaiting_reply"] as? Bool, true)
    }

    /// Chat 1, "Group", with +15550000001 and +15550000002 and no messages.
    private func groupFixture(name: String) throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: name)
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertHandle(rowId: 2, handle: "+15550000002")
        try fixture.insertChat(rowId: 1, guid: "iMessage;+;chat-g", displayName: "Group")
        for handle in 1...2 { try fixture.joinChatHandle(chatId: 1, handleId: handle) }
        return fixture
    }
}
