import XCTest
import MCP
@testable import iMessageMax

final class DatabaseCancellationTests: XCTestCase {
    func testQueryStopsWhenTaskIsCancelled() async throws {
        let fixture = try ToolTestDatabase(name: "db-cancel")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 1, guid: "cancel-chat")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)

        var batch = "BEGIN;"
        for n in 1...200 {
            batch += """
                INSERT INTO message (ROWID, guid, text, date, is_from_me, associated_message_type)
                VALUES (\(n), 'c-\(n)', 'x', \(n), 0, 0);
                INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, \(n));
                """
        }
        batch += "COMMIT;"
        try fixture.execute(batch)

        let db = fixture.database()
        let task = Task {
            try db.query(
                "SELECT m1.ROWID FROM message m1 CROSS JOIN message m2 CROSS JOIN message m3"
            ) { $0.int(0) }
        }
        await AsyncTimeout.sleep(.milliseconds(15))
        task.cancel()
        Database.interruptActiveQueries()  // no scope set: interrupt everything

        do {
            _ = try await task.value
            XCTFail("cross-join should not finish after cancel")
        } catch let error as DatabaseError {
            guard case .cancelled = error else {
                return XCTFail("expected DatabaseError.cancelled, got \(error)")
            }
        } catch is CancellationError {
            // Task.value can surface cancellation if the work observed it first.
        }
    }

    /// Cancelling one tool call must not abort another client's query. At
    /// 33e20cb the cancel handler interrupted every open connection in the
    /// process, so the bystander below failed with `DatabaseError.cancelled`.
    func testInterruptOnlyReachesTheCancelledCall() async throws {
        let fixture = try ToolTestDatabase(name: "db-cancel-scope")
        try fixture.insertChat(rowId: 1, guid: "scope-chat")
        let db = fixture.database()
        let slowCount = """
            WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 3000000)
            SELECT count(*) FROM c
            """

        let cancelled = Database.CallScope()
        let bystander = Database.CallScope()
        let victim = Task {
            try Database.$currentCall.withValue(cancelled) {
                try db.query(slowCount) { $0.int(0) }
            }
        }
        let survivor = Task {
            try Database.$currentCall.withValue(bystander) {
                try db.query(slowCount) { $0.int(0) }
            }
        }
        await AsyncTimeout.sleep(.milliseconds(15))
        Database.interruptActiveQueries(in: cancelled)

        do {
            _ = try await victim.value
            XCTFail("the interrupted call should not finish")
        } catch DatabaseError.cancelled {}
        let counted = try await survivor.value
        XCTAssertEqual(counted, [3_000_000])
    }

    /// The same guarantee through the real dispatch path both lanes use.
    func testCancellingOneToolCallLeavesAConcurrentCallRunning() async throws {
        let fixture = try ToolTestDatabase(name: "db-cancel-dispatch")
        try fixture.insertChat(rowId: 1, guid: "dispatch-chat")
        let db = fixture.database()
        ToolHandlerRegistry.shared.resetForTesting()
        defer { ToolHandlerRegistry.shared.resetForTesting() }
        ToolHandlerRegistry.shared.register(
            tool: Tool(name: "slow_count", description: "test", inputSchema: InputSchema.object(properties: [:]))
        ) { _ in
            let rows = try db.query("""
                WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 3000000)
                SELECT count(*) FROM c
                """) { $0.int(0) }
            return [.plainText("\(rows[0])")]
        }

        let cancelled = Task { await ToolCallDispatch.execute(name: "slow_count", arguments: nil, lane: .legacyStdio) }
        let bystander = Task { await ToolCallDispatch.execute(name: "slow_count", arguments: nil, lane: .legacyStdio) }
        await AsyncTimeout.sleep(.milliseconds(15))
        cancelled.cancel()

        guard case .completed(_, isError: true) = await cancelled.value else {
            return XCTFail("the cancelled call should end in a tool error")
        }
        guard case .completed(let content, isError: false) = await bystander.value,
            case .text(let text, _, _) = content.first
        else {
            return XCTFail("the concurrent call should finish normally")
        }
        XCTAssertEqual(text, "3000000")
    }
}
