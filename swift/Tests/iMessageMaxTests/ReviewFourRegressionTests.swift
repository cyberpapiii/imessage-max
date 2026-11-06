import Foundation
import MCP
import XCTest
@testable import iMessageMax

/// Regressions for the fourth review: a chat named by id is read through
/// its own index, every count follows the one chat a message is listed
/// under, and every tool picks that chat by the same rule.
final class ReviewFourRegressionTests: XCTestCase {
    /// An hour ago, inside every tool's default window.
    private let recent = Int64(Date().timeIntervalSinceReferenceDate) * 1_000_000_000 - 3_600_000_000_000

    private func ids(_ json: [String: Any], _ key: String = "messages") throws -> [String] {
        try decodeJSONArray(json[key]).compactMap { $0["id"] as? String }
    }

    private func chatIds(_ json: [String: Any], _ key: String = "messages") throws -> [String?] {
        try decodeJSONArray(json[key]).map { ($0["chat"] as? [String: Any])?["id"] as? String }
    }

    // MARK: - A named chat is read from chat_message_join by chat id

    /// chat.db's own indexes on the tables these queries read: the
    /// chat_message_join primary key and message_id index, message_idx_date,
    /// message_idx_is_read, and the join tables' keys.
    private func indexedFixture() throws -> ToolTestDatabase {
        let f = try ToolTestDatabase(name: "named-chat-plan-\(UUID().uuidString)")
        try f.execute("""
            CREATE UNIQUE INDEX cmj_pk ON chat_message_join(chat_id, message_id);
            CREATE INDEX chat_message_join_idx_message_id_only ON chat_message_join(message_id);
            CREATE INDEX message_idx_date ON message(date);
            CREATE INDEX message_idx_is_read ON message(is_read, is_from_me);
            CREATE INDEX message_idx_handle ON message(handle_id, date);
            CREATE UNIQUE INDEX chj_pk ON chat_handle_join(chat_id, handle_id);
            CREATE UNIQUE INDEX maj_pk ON message_attachment_join(message_id, attachment_id);
            CREATE INDEX maj_attachment ON message_attachment_join(attachment_id);
            """)
        try f.insertHandle(rowId: 1, handle: "+15550000001")
        try f.insertHandle(rowId: 2, handle: "spam@example.com")
        try f.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
        try f.insertChat(rowId: 5, guid: "iMessage;-;spam@example.com", isFiltered: 1)
        try f.joinChatHandle(chatId: 1, handleId: 1)
        try f.joinChatHandle(chatId: 5, handleId: 2)
        for row in 1...40 {
            let chat = row % 4 == 0 ? 5 : 1
            try f.insertMessage(
                rowId: row, guid: "g\(row)", text: "hello zebra \(row)",
                date: recent + Int64(row), isFromMe: false, handleId: chat == 5 ? 2 : 1
            )
            try f.joinChatMessage(chatId: chat, messageId: row)
        }
        try f.insertAttachment(rowId: 1, filename: "~/Library/Messages/Attachments/a.jpg", mimeType: "image/jpeg", uti: "public.jpeg", totalBytes: 10)
        try f.joinMessageAttachment(messageId: 4, attachmentId: 1)
        return f
    }

    /// The plans of every query `body` ran.
    private func plans(_ body: () async throws -> Void) async rethrows -> [[String]] {
        Database.queryPlansForTesting = []
        defer { Database.queryPlansForTesting = nil }
        try await body()
        return Database.queryPlansForTesting ?? []
    }

    /// A plan that walks messages by date or by rowid range, or checks a
    /// message's chats one row at a time.
    private func walksMessages(_ plan: [String]) -> Bool {
        plan.contains {
            $0.hasPrefix("SCAN m USING INDEX message_idx_date")
                || $0.hasPrefix("SEARCH m USING INTEGER PRIMARY KEY (rowid>")
                || $0.contains("icmj")
        }
    }

    /// A plan that starts at one chat by id, reads its join rows by chat_id,
    /// then each message by rowid.
    private func readsOneChat(_ plan: [String]) -> Bool {
        let loops = plan.filter { $0.hasPrefix("SCAN") || $0.hasPrefix("SEARCH") }
        return loops.count >= 3
            && loops[0].hasPrefix("SEARCH c USING INTEGER PRIMARY KEY (rowid=?)")
            && loops[1].hasPrefix("SEARCH cmj USING") && loops[1].contains("(chat_id=?")
            && loops[2].hasPrefix("SEARCH m USING INTEGER PRIMARY KEY (rowid=?)")
    }

    /// No query walks every message: a named chat's rows come from
    /// chat_message_join's chat_id key, not message_idx_date plus a per-row
    /// membership check.
    private func assertReadsNamedChatByIndex(
        _ tool: String, _ args: [String: Value], database: Database,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let recorded = try await plans { _ = try await callTool(tool, args, database: database) }
        XCTAssertFalse(
            recorded.contains(where: walksMessages), "\(tool) walks messages: \(recorded)", file: file, line: line
        )
        XCTAssertTrue(
            recorded.contains(where: readsOneChat), "\(tool) never reads the chat by id: \(recorded)", file: file, line: line
        )
    }

    func testEveryToolReadsANamedChatByItsIndex() async throws {
        let f = try indexedFixture()
        let db = f.database()
        for chat in ["chat1", "chat5"] {
            try await assertReadsNamedChatByIndex("search", ["query": "zebra", "in_chat": .string(chat)], database: db)
            try await assertReadsNamedChatByIndex(
                "get_unread", ["format": "messages", "chat_id": .string(chat)], database: db
            )
            try await assertReadsNamedChatByIndex("get_unread", ["chat_id": .string(chat)], database: db)
            try await assertReadsNamedChatByIndex(
                "get_messages_since", ["since_rowid": 0, "chat_id": .string(chat)], database: db
            )
            try await assertReadsNamedChatByIndex("list_attachments", ["chat_id": .string(chat)], database: db)
            try await assertReadsNamedChatByIndex(
                "list_attachments", ["chat_id": .string(chat), "sort": "largest_first"], database: db
            )
        }
    }

    /// The hidden-chat check on a first search page walks each hidden
    /// candidate by its chat id too.
    func testSearchWalksHiddenCandidatesByIndex() async throws {
        let f = try indexedFixture()
        let recorded = try await plans {
            let json = try await callTool("search", ["query": "zebra"], database: f.database())
            XCTAssertEqual(json["filtered_hidden"] as? Int, 1)
        }
        XCTAssertTrue(recorded.contains(where: readsOneChat), "plans: \(recorded)")
        // The one message walk is the unnamed page itself.
        XCTAssertEqual(recorded.filter(walksMessages).count, 1, "plans: \(recorded)")
    }
}
