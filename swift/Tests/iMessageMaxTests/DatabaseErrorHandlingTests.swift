import XCTest
@testable import iMessageMax

final class DatabaseErrorHandlingTests: XCTestCase {

    // MARK: - Happy path

    func testQueryReturnsRowsOnHappyPath() throws {
        let fixture = try ToolTestDatabase()
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")

        let db = fixture.database()
        let rows = try db.query("SELECT id FROM handle") { row in
            row.string(0) ?? ""
        }

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first, "+15550000001")
    }

    // MARK: - Parameter binder

    func testUnsupportedParamTypeThrows() throws {
        let fixture = try ToolTestDatabase()
        let db = fixture.database()

        XCTAssertThrowsError(
            try db.query("SELECT 1 WHERE 1 = ?", params: [["array", "is", "unsupported"]]) { _ in 0 }
        ) { error in
            guard case DatabaseError.invalidData = error else {
                XCTFail("Expected DatabaseError.invalidData, got \(error)")
                return
            }
        }
    }

    func testBoolParamBindsAsInteger() throws {
        let fixture = try ToolTestDatabase()
        let db = fixture.database()

        let trueRows = try db.query("SELECT 1 WHERE ? = 1", params: [true]) { _ in 0 }
        XCTAssertEqual(trueRows.count, 1, "true should bind as 1 and match WHERE ? = 1")

        let falseRows = try db.query("SELECT 1 WHERE ? = 1", params: [false]) { _ in 0 }
        XCTAssertEqual(falseRows.count, 0, "false should bind as 0 and not match WHERE ? = 1")
    }

    // MARK: - Missing database

    func testQueryAgainstMissingDatabaseThrowsNotFound() throws {
        let db = Database(path: "/nonexistent/nope.sqlite")

        XCTAssertThrowsError(
            try db.query("SELECT 1") { _ in 0 }
        ) { error in
            guard case DatabaseError.notFound = error else {
                XCTFail("Expected DatabaseError.notFound, got \(error)")
                return
            }
        }
    }
}
