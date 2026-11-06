import MCP
import XCTest
@testable import iMessageMax

/// A chat named by id is read from chat_message_join by its chat_id key,
/// never by walking every message.
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

    /// The hidden-chat check on a first search page walks each hidden
    /// candidate by its chat id too.
    func testSearchWalksHiddenCandidatesByIndex() async throws {
        let fixture = try indexedHiddenChatFixture()
        let recorded = try await plans {
            let json = try await callTool("search", ["query": "zebra"], database: fixture.database())
            XCTAssertEqual(json["filtered_hidden"] as? Int, 1)
        }
        XCTAssertTrue(recorded.contains(where: readsOneChat), "plans: \(recorded)")
        // The one message walk is the unnamed page itself.
        XCTAssertEqual(recorded.filter(walksMessages).count, 1, "plans: \(recorded)")
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
}
