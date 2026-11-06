import SQLite3
import XCTest
@testable import iMessageMax

final class DatabaseErrorHandlingTests: XCTestCase {

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

    func testExtraParameterFailsBindInsteadOfRunning() throws {
        let fixture = try ToolTestDatabase()
        let db = fixture.database()
        XCTAssertThrowsError(
            try db.query("SELECT 1", params: [1]) { _ in 0 }
        ) { error in
            guard case DatabaseError.queryFailed = error else {
                return XCTFail("expected queryFailed, got \(error)")
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

    func testCheckAccessOnAReadableDatabaseIsAccessible() throws {
        let fixture = try ToolTestDatabase(name: "check-access")
        let access = Database.checkAccess(path: fixture.path)
        XCTAssertEqual(access.status, .accessible)
        XCTAssertTrue(access.ok)
    }

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

    func testFailedOpensDoNotAccumulateSQLiteMemory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("chat.db").path
        FileManager.default.createFile(atPath: path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)

        let db = Database(path: path)

        // Settle sqlite's one-time/global allocations before measuring.
        // sqlite3_memory_used() does not work as the measure here. Apple's
        // sqlite build does not count these allocations (the measured delta
        // was 0 even when leaking), so measure live malloc bytes across all
        // zones.
        for _ in 0..<20 {
            XCTAssertThrowsError(try db.query("SELECT 1") { _ in 0 })
        }

        func liveMallocBytes() -> Int {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            return stats.size_in_use
        }

        let before = liveMallocBytes()
        // malloc_zone_statistics is process-wide, so other tests running in the
        // same process contribute about 150 KiB of ambient growth over this
        // test's lifetime. 200 calls put the leak signal (about 285 KiB) too
        // close to that noise floor, and the assertion flaked in full-suite
        // runs. 2000 calls raise the signal to about 2.8 MiB while the noise
        // floor stays the same.
        let calls = 2000
        var deniedCount = 0
        for _ in 0..<calls {
            // Use a plain do/catch inside an autoreleasepool. XCTAssert* helpers
            // accumulate autoreleased bookkeeping that would hide the leak signal.
            autoreleasepool {
                do {
                    _ = try db.query("SELECT 1") { _ in 0 }
                } catch DatabaseError.permissionDenied {
                    deniedCount += 1
                } catch {
                }
            }
        }
        let growth = liveMallocBytes() - before
        XCTAssertEqual(deniedCount, calls, "expected every query to fail permission_denied")

        XCTAssertLessThan(
            growth, 1024 * 1024,
            "live malloc bytes grew \(growth) across \(calls) failed opens; "
                + "failed sqlite3_open_v2 handles are not being closed"
        )
    }

    func testPermissionDeniedIsRetriedOnTheNextQuery() throws {
        try XCTSkipIf(getuid() == 0, "root ignores POSIX mode bits")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("self-heal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("chat.db").path
        FileManager.default.createFile(atPath: path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)

        let db = Database(path: path)

        XCTAssertThrowsError(try db.query("SELECT 1") { _ in 0 }) { error in
            guard case DatabaseError.permissionDenied = error else {
                return XCTFail("expected permissionDenied, got \(error)")
            }
        }
        XCTAssertEqual(Database.checkAccess(path: path).status, "permission_denied")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)

        let rows = try db.query("SELECT 1") { row in row.int(0) }
        XCTAssertEqual(rows, [1], "same Database instance must recover once the file is readable")
        XCTAssertEqual(Database.checkAccess(path: path).status, "accessible")
    }
}
