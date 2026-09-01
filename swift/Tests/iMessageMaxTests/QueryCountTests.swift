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
}
