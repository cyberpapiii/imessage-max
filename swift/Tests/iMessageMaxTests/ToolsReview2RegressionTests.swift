import XCTest
import MCP
@testable import iMessageMax

/// Regressions for the second read-tool review.
final class ToolsReview2RegressionTests: XCTestCase {
    private let base: Int64 = 700_000_000_000_000_000

    private func ids(_ json: [String: Any], _ key: String = "messages") throws -> [String] {
        try decodeJSONArray(json[key]).compactMap { $0["id"] as? String }
    }

    // MARK: - get_messages_since pages without skipping rows

    func testSinceFullPageEndingOnABatchsLastRowStillReportsMore() async throws {
        let f = try ToolTestDatabase(name: "since-full-batch")
        try f.insertHandle(rowId: 1, handle: "+15550000001")
        try f.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
        try f.insertChat(rowId: 2, guid: "SMS;-;spam", isFiltered: 1)
        // limit 31 reads a first batch of 32 rows; one of them is hidden, so
        // the 31st kept row is the batch's last.
        try f.insertMessage(rowId: 1, guid: "h", text: "spam", date: base, isFromMe: false, handleId: 1)
        try f.joinChatMessage(chatId: 2, messageId: 1)
        for row in 2...40 {
            try f.insertMessage(rowId: row, guid: "g\(row)", text: "m\(row)", date: base + Int64(row), isFromMe: false, handleId: 1)
            try f.joinChatMessage(chatId: 1, messageId: row)
        }

        let first = try await callTool("get_messages_since", ["since_rowid": 0, "limit": 31], database: f.database())
        XCTAssertEqual(try ids(first).count, 31)
        XCTAssertEqual(first["has_more"] as? Bool, true)
        XCTAssertEqual(first["next_rowid"] as? Int, 32)

        let second = try await callTool("get_messages_since", ["since_rowid": 32, "limit": 31], database: f.database())
        XCTAssertEqual(try ids(second), (33...40).map { "msg_\($0)" })
        XCTAssertEqual(second["has_more"] as? Bool, false)
    }

    // MARK: - A message's chat

    func testSinceChatFilterMatchesAMessageWhoseHomeChatIsAnother() async throws {
        let f = try ToolTestDatabase(name: "since-second-chat")
        try f.insertHandle(rowId: 1, handle: "+15550000001")
        try f.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
        try f.insertChat(rowId: 2, guid: "SMS;-;+15550000001", serviceName: "SMS")
        try f.insertMessage(rowId: 1, guid: "g1", text: "in both", date: base, isFromMe: false, handleId: 1)
        try f.joinChatMessage(chatId: 1, messageId: 1)
        try f.joinChatMessage(chatId: 2, messageId: 1)

        let json = try await callTool("get_messages_since", ["since_rowid": 0, "chat_id": "chat2"], database: f.database())
        let messages = try decodeJSONArray(json["messages"])
        XCTAssertEqual(messages.compactMap { $0["id"] as? String }, ["msg_1"])
        XCTAssertEqual((messages.first?["chat"] as? [String: Any])?["id"] as? String, "chat2")

        let unfiltered = try await callTool("get_messages_since", ["since_rowid": 0], database: f.database())
        let home = try decodeJSONArray(unfiltered["messages"]).first?["chat"] as? [String: Any]
        XCTAssertEqual(home?["id"] as? String, "chat1")
    }

    func testContextAndAttachmentNameTheMessagesHomeChat() async throws {
        let f = try ToolTestDatabase(name: "home-chat")
        try f.insertHandle(rowId: 1, handle: "+15550000001")
        // The higher chat id is inserted first, so an unordered pick lands on it.
        try f.insertChat(rowId: 9, guid: "SMS;-;+15550000001", serviceName: "SMS")
        try f.insertChat(rowId: 3, guid: "iMessage;-;+15550000001")
        try f.insertMessage(rowId: 1, guid: "g1", text: "\u{FFFC}", date: base, isFromMe: false, handleId: 1)
        try f.joinChatMessage(chatId: 9, messageId: 1)
        try f.joinChatMessage(chatId: 3, messageId: 1)
        try f.insertAttachment(rowId: 1, filename: "/nonexistent/a.pdf", mimeType: "application/pdf", uti: "com.adobe.pdf")
        try f.joinMessageAttachment(messageId: 1, attachmentId: 1)

        let context = try await callTool("get_context", ["message_id": "msg_1"], database: f.database())
        XCTAssertEqual((context["chat"] as? [String: Any])?["id"] as? String, "chat3")

        for sort in ["recent_first", "largest_first"] {
            let listed = try await callTool("list_attachments", ["sort": .string(sort)], database: f.database())
            let chat = try decodeJSONArray(listed["messages"]).first?["chat"] as? [String: Any]
            XCTAssertEqual(chat?["id"] as? String, "chat3", sort)
        }
    }

    // MARK: - search with only single-character words

    func testSearchForOnlySingleCharactersMatchesThemAsASubstring() async throws {
        let f = try ToolTestDatabase(name: "short-query")
        try f.insertHandle(rowId: 1, handle: "+15550000001")
        try f.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
        let texts = ["我的猫很可爱", "a dog", "nothing here", "b c d"]
        for (i, text) in texts.enumerated() {
            try f.insertMessage(rowId: i + 1, guid: "g\(i)", text: text, date: base + Int64(i), isFromMe: false, handleId: 1)
            try f.joinChatMessage(chatId: 1, messageId: i + 1)
        }
        let cat = try await callTool("search", ["query": "猫"], database: f.database())
        XCTAssertEqual(try ids(cat, "results"), ["msg_1"])
        let a = try await callTool("search", ["query": " A "], database: f.database())
        XCTAssertEqual(try ids(a, "results"), ["msg_2"])
        let phrase = try await callTool("search", ["query": "c d"], database: f.database())
        XCTAssertEqual(try ids(phrase, "results"), ["msg_4"])
    }

    // MARK: - Excerpts index the text they were matched in

    func testExcerptSurvivesTextWhoseLowercaseIsLonger() {
        let text = String(repeating: "İ", count: 300) + " needle " + String(repeating: "x", count: 300)
        let excerpt = SearchTool.makeExcerpt(text: text, query: "needle")
        XCTAssertTrue(excerpt.contains("needle"), excerpt)
    }

    func testExcerptCentresOnTheMatchPastEmoji() {
        let text = String(repeating: "👍", count: 200) + " needle " + String(repeating: "👍", count: 200)
        let excerpt = SearchTool.makeExcerpt(text: text, query: "NEEDLE")
        XCTAssertTrue(excerpt.contains("needle"), excerpt)
        XCTAssertTrue(excerpt.hasPrefix("..."))
        XCTAssertTrue(excerpt.hasSuffix("..."))
        XCTAssertFalse(excerpt.contains("\u{FFFD}"), "an emoji was split")
    }

    // MARK: - get_unread pages to the newest message

    func testUnreadMessagesPageWithACursorToTheNewest() async throws {
        let f = try ToolTestDatabase(name: "unread-cursor")
        try f.insertHandle(rowId: 1, handle: "+15550000001")
        try f.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
        let recent = Int64(Date().timeIntervalSinceReferenceDate) * 1_000_000_000 - 3_600_000_000_000
        for row in 1...5 {
            try f.insertMessage(rowId: row, guid: "g\(row)", text: "u\(row)", date: recent + Int64(row), isFromMe: false, handleId: 1)
            try f.joinChatMessage(chatId: 1, messageId: row)
        }
        var seen: [String] = []
        var cursor: String?
        for page in 0..<3 {
            var args: [String: Value] = ["format": "messages", "limit": 2]
            if let cursor { args["cursor"] = .string(cursor) }
            let json = try await callTool("get_unread", args, database: f.database())
            seen += try ids(json)
            cursor = json["cursor"] as? String
            XCTAssertEqual(json["more"] as? Bool, cursor != nil)
            XCTAssertEqual(json["total_unread"] as? Int, 5)
            XCTAssertEqual(cursor == nil, page == 2)
        }
        XCTAssertEqual(seen, (1...5).map { "msg_\($0)" })
    }

    // MARK: - list_chats pages to chats with no messages

    func testListChatsPagesReachChatsWithNoMessages() async throws {
        let f = try ToolTestDatabase(name: "list-empty-chats")
        try f.insertHandle(rowId: 1, handle: "+15550000001")
        for chat in 1...5 {
            try f.insertChat(rowId: chat, guid: "iMessage;+;c\(chat)", displayName: "Chat \(chat)")
            try f.joinChatHandle(chatId: chat, handleId: 1)
        }
        // Chats 1 and 2 have messages; 3, 4 and 5 have none.
        for chat in 1...2 {
            try f.insertMessage(rowId: chat, guid: "g\(chat)", text: "hi", date: base + Int64(chat), isFromMe: false, handleId: 1)
            try f.joinChatMessage(chatId: chat, messageId: chat)
        }
        for sort in ["recent", "most_active"] {
            var seen: [String] = []
            var cursor: String?
            for _ in 0..<6 {
                var args: [String: Value] = ["sort": .string(sort), "limit": 2]
                if let cursor { args["cursor"] = .string(cursor) }
                let json = try await callTool("list_chats", args, database: f.database())
                let page = try decodeJSONArray(json["chats"]).compactMap { $0["id"] as? String }
                XCTAssertFalse(page.isEmpty, "\(sort): an empty page after more:true")
                seen += page
                cursor = json["cursor"] as? String
                XCTAssertEqual(json["more"] as? Bool, cursor != nil)
                if cursor == nil { break }
            }
            XCTAssertEqual(seen, ["chat2", "chat1", "chat5", "chat4", "chat3"], sort)
        }
    }

    // MARK: - Hidden chats stay hidden

    func testActiveConversationsAndAttachmentsSkipHiddenChats() async throws {
        let f = try ToolTestDatabase(name: "hidden-active")
        try f.insertHandle(rowId: 1, handle: "spam@example.com")
        try f.insertChat(rowId: 1, guid: "iMessage;-;spam@example.com", isFiltered: 1)
        try f.joinChatHandle(chatId: 1, handleId: 1)
        let recent = Int64(Date().timeIntervalSinceReferenceDate) * 1_000_000_000 - 3_600_000_000_000
        try f.insertMessage(rowId: 1, guid: "g1", text: "\u{FFFC}", date: recent, isFromMe: false, handleId: 1)
        try f.insertMessage(rowId: 2, guid: "g2", text: "who is this", date: recent + 1, isFromMe: true)
        for row in 1...2 { try f.joinChatMessage(chatId: 1, messageId: row) }
        try f.insertAttachment(rowId: 1, filename: "/nonexistent/x.pdf", mimeType: "application/pdf", uti: "com.adobe.pdf")
        try f.joinMessageAttachment(messageId: 1, attachmentId: 1)

        let active = try await callTool("get_active_conversations", ["min_exchanges": 1], database: f.database())
        XCTAssertEqual(try decodeJSONArray(active["conversations"]).count, 0)
        let listed = try await callTool("list_attachments", [:], database: f.database())
        XCTAssertEqual(try decodeJSONArray(listed["messages"]).count, 0)
        let named = try await callTool("list_attachments", ["chat_id": "chat1"], database: f.database())
        XCTAssertEqual(try decodeJSONArray(named["messages"]).count, 1)
    }

    // MARK: - awaiting_reply ignores group events

    func testGroupEventIsNotAwaitingReplyOrAnExchange() async throws {
        let f = try ToolTestDatabase(name: "awaiting-events")
        try f.insertHandle(rowId: 1, handle: "+15550000001")
        try f.insertHandle(rowId: 2, handle: "+15550000002")
        try f.insertChat(rowId: 1, guid: "iMessage;+;chat-g", displayName: "Group")
        for h in 1...2 { try f.joinChatHandle(chatId: 1, handleId: h) }
        let recent = Int64(Date().timeIntervalSinceReferenceDate) * 1_000_000_000 - 3_600_000_000_000
        try f.insertMessage(rowId: 1, guid: "g1", text: "dinner?", date: recent, isFromMe: false, isRead: true, handleId: 1)
        try f.insertMessage(rowId: 2, guid: "g2", text: "yes", date: recent + 1_000, isFromMe: true)
        try f.insertMessage(rowId: 3, guid: "g3", text: nil, date: recent + 2_000, isFromMe: false, isRead: true, handleId: 2, itemType: 3)
        for row in 1...3 { try f.joinChatMessage(chatId: 1, messageId: row) }

        let listed = try await callTool("list_chats", [:], database: f.database())
        let chat = try XCTUnwrap(try decodeJSONArray(listed["chats"]).first)
        XCTAssertNotEqual(chat["awaiting_reply"] as? Bool, true)

        let details = try await callTool("get_chat_details", ["chat_id": "chat1"], database: f.database())
        XCTAssertNotEqual(details["awaiting_reply"] as? Bool, true)

        let active = try await callTool("get_active_conversations", ["min_exchanges": 1], database: f.database())
        let conversation = try XCTUnwrap(try decodeJSONArray(active["conversations"]).first)
        XCTAssertEqual(conversation["awaiting_reply"] as? Bool, false)
        let activity = try XCTUnwrap(conversation["activity"] as? [String: Any])
        XCTAssertEqual(activity["their_msgs"] as? Int, 1)
    }

    func testAwaitingReplyLooksPastAGroupEventToTheirMessage() async throws {
        let f = try ToolTestDatabase(name: "awaiting-past-event")
        try f.insertHandle(rowId: 1, handle: "+15550000001")
        try f.insertHandle(rowId: 2, handle: "+15550000002")
        try f.insertChat(rowId: 1, guid: "iMessage;+;chat-g", displayName: "Group")
        for h in 1...2 { try f.joinChatHandle(chatId: 1, handleId: h) }
        let recent = Int64(Date().timeIntervalSinceReferenceDate) * 1_000_000_000 - 3_600_000_000_000
        try f.insertMessage(rowId: 1, guid: "g1", text: "yes", date: recent, isFromMe: true)
        try f.insertMessage(rowId: 2, guid: "g2", text: "dinner?", date: recent + 1_000, isFromMe: false, isRead: true, handleId: 1)
        try f.insertMessage(rowId: 3, guid: "g3", text: nil, date: recent + 2_000, isFromMe: true, itemType: 2, groupTitle: "Dinner")
        for row in 1...3 { try f.joinChatMessage(chatId: 1, messageId: row) }

        let listed = try await callTool("list_chats", [:], database: f.database())
        XCTAssertEqual(try decodeJSONArray(listed["chats"]).first?["awaiting_reply"] as? Bool, true)
        let active = try await callTool("get_active_conversations", ["min_exchanges": 1], database: f.database())
        XCTAssertEqual(try decodeJSONArray(active["conversations"]).first?["awaiting_reply"] as? Bool, true)
    }

    // MARK: - search and unanswered costs

    func testSearchCountsHiddenChatsOnTheFirstPageOnly() async throws {
        let f = try ToolTestDatabase(name: "search-hidden-pages")
        try f.insertHandle(rowId: 1, handle: "+15550000001")
        try f.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
        try f.insertChat(rowId: 2, guid: "SMS;-;spam", isFiltered: 1)
        for row in 1...3 {
            try f.insertMessage(rowId: row, guid: "g\(row)", text: "hello \(row)", date: base + Int64(row), isFromMe: false, handleId: 1)
            try f.joinChatMessage(chatId: 1, messageId: row)
        }
        try f.insertMessage(rowId: 4, guid: "g4", text: "hello spam", date: base, isFromMe: false, handleId: 1)
        try f.joinChatMessage(chatId: 2, messageId: 4)

        let first = try await callTool("search", ["query": "hello", "limit": 1], database: f.database())
        XCTAssertEqual(first["filtered_hidden"] as? Int, 1)
        let cursor = try XCTUnwrap(first["cursor"] as? String)
        let second = try await callTool("search", ["query": "hello", "limit": 1, "cursor": .string(cursor)], database: f.database())
        XCTAssertEqual(try ids(second, "results"), ["msg_2"])
        XCTAssertNil(second["filtered_hidden"])
    }

    func testUnansweredChecksRepliesPerChunkNotPerRow() async throws {
        func queries(questions: Int) async throws -> Int {
            let f = try ToolTestDatabase(name: "unanswered-\(questions)")
            try f.insertHandle(rowId: 1, handle: "+15550000001")
            try f.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
            try f.joinChatHandle(chatId: 1, handleId: 1)
            for row in 1...questions {
                try f.insertMessage(rowId: row, guid: "g\(row)", text: "free at \(row)?", date: base + Int64(row) * 7_200_000_000_000, isFromMe: true)
                try f.joinChatMessage(chatId: 1, messageId: row)
            }
            let db = f.database()
            return try await countQueries {
                let json = try await callTool("get_messages", ["chat_id": "chat1", "unanswered": true, "unanswered_hours": 1], database: db)
                XCTAssertEqual(try ids(json).count, questions)
            }
        }
        let few = try await queries(questions: 5)
        let many = try await queries(questions: 40)
        XCTAssertEqual(few, many)
    }

    // MARK: - One chat-id resolver

    private func twoChatFixture() throws -> ToolTestDatabase {
        let f = try ToolTestDatabase(name: "chat-ids")
        try f.insertHandle(rowId: 1, handle: "+15550000001")
        try f.insertChat(rowId: 1, guid: "iMessage;+;chat-trip-old", displayName: "Old Trip")
        try f.insertChat(rowId: 2, guid: "iMessage;+;chat-trip-new", displayName: "New Trip")
        for chat in 1...2 {
            try f.joinChatHandle(chatId: chat, handleId: 1)
            try f.insertMessage(rowId: chat, guid: "g\(chat)", text: "trip hello", date: base + Int64(chat), isFromMe: false, handleId: 1)
            try f.joinChatMessage(chatId: chat, messageId: chat)
        }
        return f
    }

    func testEveryChatIdArgumentAnswersChatNotFoundForAnUnknownChat() async throws {
        let f = try twoChatFixture()
        let calls: [(String, [String: Value])] = [
            ("get_messages", ["chat_id": "chat99"]),
            ("get_messages_since", ["since_rowid": 0, "chat_id": "chat99"]),
            ("get_context", ["chat_id": "chat99", "contains": "trip"]),
            ("list_attachments", ["chat_id": "chat99"]),
            ("get_unread", ["chat_id": "chat99"]),
            ("get_chat_details", ["chat_id": "chat99"]),
            ("search", ["query": "trip", "in_chat": "chat99"]),
            ("search", ["query": "trip", "in_chat": "no-such-guid"]),
            ("get_messages_since", ["since_rowid": 0, "chat_id": "no-such-guid"]),
        ]
        for (tool, args) in calls {
            let json = try await callTool(tool, args, database: f.database())
            XCTAssertEqual(json["error"] as? String, "chat_not_found", "\(tool) \(args)")
        }
    }

    func testGuidSubstringNamesOneChatInEveryTool() async throws {
        let f = try twoChatFixture()
        let search = try await callTool("search", ["query": "trip", "in_chat": "chat-trip"], database: f.database())
        let chats = try decodeJSONArray(search["results"]).compactMap { ($0["chat"] as? [String: Any])?["id"] as? String }
        XCTAssertEqual(chats, ["chat2"], "a GUID substring names the most recently active chat, not every match")

        let details = try await callTool("get_chat_details", ["chat_id": "chat-trip-old"], database: f.database())
        XCTAssertEqual((details["chat"] as? [String: Any])?["id"] as? String, "chat1")
    }

    func testChatIdLookupDoesNotHideDatabaseErrors() async throws {
        let missing = Database(path: "/nonexistent/\(UUID().uuidString)/chat.db")
        let tool = GetMessagesTool(db: missing, resolver: ContactResolver(seedCache: [:]))
        do {
            _ = try await tool.execute(args: ["chat_id": "iMessage;-;+1555"])
            XCTFail("expected the database error")
        } catch let failure as ToolFailure {
            XCTAssertNotEqual(failure.code, "chat_not_found")
        } catch {
            XCTAssertTrue(error is DatabaseError, "\(error)")
        }
    }

    // MARK: - find_chat filtered_hidden means one thing

    func testFindChatCountsEveryHiddenChatThatWouldHaveMatched() async throws {
        let f = try ToolTestDatabase(name: "find-hidden")
        for h in 1...4 { try f.insertHandle(rowId: h, handle: "+1555000000\(h)") }
        try f.insertChat(rowId: 1, guid: "iMessage;+;shown", displayName: "Spam Fans")
        try f.insertChat(rowId: 2, guid: "iMessage;+;h1", displayName: "Spam Club 1", isFiltered: 1)
        try f.insertChat(rowId: 3, guid: "iMessage;+;h2", displayName: "Spam Club 2", isFiltered: 1)
        try f.insertChat(rowId: 4, guid: "iMessage;-;+15550000004", isFiltered: 1)
        for (chat, handles) in [(1, [1, 2]), (2, [1, 3]), (3, [2, 3]), (4, [4])] {
            for h in handles { try f.joinChatHandle(chatId: chat, handleId: h) }
            try f.insertMessage(rowId: chat, guid: "g\(chat)", text: "zebra crossing", date: base + Int64(chat), isFromMe: false, handleId: handles[0])
            try f.joinChatMessage(chatId: chat, messageId: chat)
        }
        let resolver = ContactResolver(seedCache: ["+15550000004": "Spam Bot"])

        let byName = try await callTool("find_chat", ["name": "Spam", "limit": 1], database: f.database(), resolver: resolver)
        XCTAssertEqual(try decodeJSONArray(byName["chats"]).count, 1)
        XCTAssertEqual(byName["filtered_hidden"] as? Int, 3, "two named groups and the unnamed DM")

        let byContent = try await callTool("find_chat", ["contains_recent": "zebra", "limit": 1], database: f.database(), resolver: resolver)
        XCTAssertEqual(try decodeJSONArray(byContent["chats"]).count, 1)
        XCTAssertEqual(byContent["filtered_hidden"] as? Int, 3)
    }
}
