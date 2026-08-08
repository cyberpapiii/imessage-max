import SQLite3
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

    // MARK: - Failed-open handle release

    func testFailedOpensDoNotAccumulateSQLiteMemory() throws {
        // A failed sqlite3_open_v2 still allocates a connection handle that
        // must be passed to sqlite3_close. Skipping the close leaked ~1.5 KiB
        // per call on the permission_denied path.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("chat.db").path
        FileManager.default.createFile(atPath: path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)

        let db = Database(path: path)

        // Settle sqlite's one-time/global allocations before measuring.
        // sqlite3_memory_used() cannot be the meter here: Apple's sqlite
        // build does not account these allocations (measured delta 0 even
        // when leaking), so measure live malloc bytes across all zones.
        for _ in 0..<20 {
            XCTAssertThrowsError(try db.query("SELECT 1") { _ in 0 })
        }

        func liveMallocBytes() -> Int {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            return stats.size_in_use
        }

        let before = liveMallocBytes()
        let calls = 200
        var deniedCount = 0
        for _ in 0..<calls {
            // Plain do/catch inside an autoreleasepool: XCTAssert* helpers
            // accumulate autoreleased bookkeeping that would drown the signal.
            autoreleasepool {
                do {
                    _ = try db.query("SELECT 1") { _ in 0 }
                } catch DatabaseError.permissionDenied {
                    deniedCount += 1
                } catch {
                    // Counted mismatch reported below.
                }
            }
        }
        let growth = liveMallocBytes() - before
        XCTAssertEqual(deniedCount, calls, "expected every query to fail permission_denied")

        // Pre-fix this retained ~1.4 KiB per failed open (~285 KB across the
        // measured calls; post-fix delta is 0). The threshold leaves room for
        // allocator noise while still catching any per-call retention.
        XCTAssertLessThan(
            growth, 64 * 1024,
            "live malloc bytes grew \(growth) across \(calls) failed opens; "
                + "failed sqlite3_open_v2 handles are not being closed"
        )
    }
}
