import MCP
import XCTest
@testable import iMessageMax

final class QueryPlanTests: XCTestCase {
    func testEveryToolReadsANamedChatByItsIndex() async throws {
        let fixture = try indexedHiddenChatFixture()
        let db = fixture.database()
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

    func testSearchReadsHiddenChatsByIndex() async throws {
        let fixture = try indexedHiddenChatFixture()
        let recorded = try await plans {
            let json = try await callTool("search", ["query": "zebra"], database: fixture.database())
            XCTAssertEqual(json["filtered_hidden"] as? Int, 1)
        }
        XCTAssertTrue(recorded.contains(where: readsChatsByIndex), "plans: \(recorded)")
        XCTAssertEqual(recorded.filter(walksMessages).count, 1, "plans: \(recorded)")
    }

    /// The query reads the activity window by message date. Given a real
    /// chat.db's statistics and the hidden-chat predicate, SQLite otherwise
    /// starts at chats and walks every message.
    func testActiveConversationsReadsTheWindowByDate() async throws {
        let fixture = try indexedHiddenChatFixture()
        try fixture.execute("""
            ANALYZE;
            DELETE FROM sqlite_stat1;
            INSERT INTO sqlite_stat1 VALUES
                ('message', 'message_idx_date', '300000 1'),
                ('chat_message_join', 'cmj_pk', '300000 150 1'),
                ('chat_message_join', 'chat_message_join_idx_message_id_only', '300000 1'),
                ('chat_handle_join', 'chj_pk', '3450 2 1'),
                ('chat', NULL, '2000');
            """)
        let recorded = try await plans {
            _ = try await callTool("get_active_conversations", [:], database: fixture.database())
        }
        let activity = try XCTUnwrap(recorded.first, "plans: \(recorded)")
        XCTAssertEqual(
            activity.first { $0.hasPrefix("S") }, "SEARCH m USING INDEX message_idx_date (date>?)",
            "plans: \(recorded)"
        )
    }

    private func plans(_ body: () async throws -> Void) async rethrows -> [[String]] {
        Database.queryPlansForTesting = []
        defer { Database.queryPlansForTesting = nil }
        try await body()
        return Database.queryPlansForTesting ?? []
    }

    private func walksMessages(_ plan: [String]) -> Bool {
        plan.contains {
            $0.hasPrefix("SCAN m USING INDEX message_idx_date")
                || $0.hasPrefix("SEARCH m USING INTEGER PRIMARY KEY (rowid>")
                || $0.contains("icmj")
        }
    }

    private func readsOneChat(_ plan: [String]) -> Bool {
        readsChatsByIndex(plan) && plan.first { $0.hasPrefix("S") }?.hasPrefix("SEARCH c USING INTEGER PRIMARY KEY (rowid=?)") == true
    }

    private func readsChatsByIndex(_ plan: [String]) -> Bool {
        let loops = plan.filter { $0.hasPrefix("SCAN") || $0.hasPrefix("SEARCH") }
        return loops.count >= 3
            && (loops[0].hasPrefix("SCAN c") || loops[0].hasPrefix("SEARCH c "))
            && loops[1].hasPrefix("SEARCH cmj USING") && loops[1].contains("(chat_id=?")
            && loops[2].hasPrefix("SEARCH m USING INTEGER PRIMARY KEY (rowid=?)")
    }

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
}
