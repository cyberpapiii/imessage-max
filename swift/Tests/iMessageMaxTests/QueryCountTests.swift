import XCTest
@testable import iMessageMax

final class QueryCountTests: XCTestCase {
    func testQueryCounterIncrements() throws {
        let fixture = try ToolTestDatabase(name: "query-counter")
        try fixture.insertChat(rowId: 1, guid: "counter-chat")

        Database.queryCountForTesting = 0
        defer { Database.queryCountForTesting = nil }

        _ = try fixture.database().query("SELECT ROWID FROM chat", params: []) { row in
            row.int(0)
        }
        XCTAssertEqual(Database.queryCountForTesting, 1)
    }

    func testQueryCountIsExactUnderConcurrency() async throws {
        let fixture = try ToolTestDatabase(name: "query-count-concurrent")
        let db = fixture.database()
        Database.queryCountForTesting = 0
        defer { Database.queryCountForTesting = nil }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask { _ = try db.query("SELECT 1") { $0.int(0) } }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(Database.queryCountForTesting, 200)
    }
}
