import XCTest
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
        Database.interruptActiveQueries()

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
}
