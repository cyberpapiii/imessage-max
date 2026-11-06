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
}
