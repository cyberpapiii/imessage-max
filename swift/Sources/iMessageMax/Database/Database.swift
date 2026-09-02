// Sources/iMessageMax/Database/Database.swift
import Foundation
import SQLite3
import Synchronization

// Safe as @unchecked Sendable because instances only hold an immutable path
// string plus a Mutex-guarded schema cache. Every query opens its own
// short-lived read-only SQLite connection, so there is no shared mutable
// connection state crossing actor/task boundaries.
final class Database: @unchecked Sendable {
    static let defaultPath: String = {
        ("~/Library/Messages/chat.db" as NSString).expandingTildeInPath
    }()

    private let path: String
    private let schemaCache: Mutex<SchemaCapabilities?>

    init(path: String = Database.defaultPath) {
        self.path = path
        self.schemaCache = Mutex(nil)
    }

    /// Test-only: skip the probe and use `schema` as the answer.
    init(path: String, schemaOverride: SchemaCapabilities) {
        self.path = path
        self.schemaCache = Mutex(schemaOverride)
    }

    /// The probed schema, cached after the first successful open. A failed
    /// open throws and caches nothing, so the next call probes again.
    func schema() throws -> SchemaCapabilities {
        if let cached = schemaCache.withLock({ $0 }) { return cached }
        let conn = try openReadOnly()
        defer { sqlite3_close(conn) }
        let probed = try SchemaCapabilities(probing: conn)
        schemaCache.withLock { $0 = probed }
        return probed
    }

    // MARK: - Access Check

    static func checkAccess(path: String = defaultPath) -> (ok: Bool, status: String) {
        let fm = FileManager.default

        guard fm.fileExists(atPath: path) else {
            return (false, "database_not_found")
        }

        guard fm.isReadableFile(atPath: path) else {
            return (false, "permission_denied")
        }

        var db: OpaquePointer?
        let result = sqlite3_open_v2(
            "file:\(path)?mode=ro",
            &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
            nil
        )

        if let db = db {
            sqlite3_close(db)
        }

        if result == SQLITE_OK {
            return (true, "accessible")
        } else {
            return (false, "permission_denied")
        }
    }

    // MARK: - Query Execution

    /// Opt-in query counter for tests. Incremented at the start of `query` when non-nil.
    nonisolated(unsafe) static var queryCountForTesting: Int?

    func query<T>(
        _ sql: String,
        params: [Any] = [],
        map: (SQLiteRow) throws -> T
    ) throws -> [T] {
        if Database.queryCountForTesting != nil {
            Database.queryCountForTesting! += 1
        }

        let conn = try openReadOnly()
        defer { sqlite3_close(conn) }

        let stmt = try prepare(conn, sql: sql, params: params)
        defer { sqlite3_finalize(stmt) }

        var results: [T] = []
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            try results.append(map(SQLiteRow(stmt)))
            stepResult = sqlite3_step(stmt)
        }
        guard stepResult == SQLITE_DONE else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(conn)))
        }
        return results
    }

    // MARK: - Private

    private func openReadOnly() throws -> OpaquePointer {
        guard FileManager.default.fileExists(atPath: path) else {
            throw DatabaseError.notFound(path)
        }

        var db: OpaquePointer?
        let result = sqlite3_open_v2(
            "file:\(path)?mode=ro",
            &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
            nil
        )

        guard result == SQLITE_OK, let db = db else {
            // SQLite allocates a connection handle even when open fails and
            // requires sqlite3_close to free it. Skipping this leaked ~1.5 KiB
            // per failed open on the permission_denied path.
            if let db = db {
                sqlite3_close(db)
            }
            throw DatabaseError.permissionDenied(path)
        }

        sqlite3_busy_timeout(db, 1000)
        var errMsg: UnsafeMutablePointer<CChar>?
        let pragmaResult = sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, &errMsg)
        if pragmaResult != SQLITE_OK {
            let detail = errMsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errMsg)
            sqlite3_close(db)
            throw DatabaseError.queryFailed("Failed to enforce read-only mode: \(detail)")
        }

        return db
    }

    private func prepare(
        _ conn: OpaquePointer,
        sql: String,
        params: [Any]
    ) throws -> OpaquePointer {
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt = stmt else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(conn)))
        }

        for (index, param) in params.enumerated() {
            let idx = Int32(index + 1)
            let rc: Int32
            switch param {
            case let value as Bool:
                rc = sqlite3_bind_int64(stmt, idx, value ? 1 : 0)
            case let value as Int:
                rc = sqlite3_bind_int64(stmt, idx, Int64(value))
            case let value as Int64:
                rc = sqlite3_bind_int64(stmt, idx, value)
            case let value as String:
                rc = sqlite3_bind_text(stmt, idx, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let value as Double:
                rc = sqlite3_bind_double(stmt, idx, value)
            case let value as Data:
                rc = value.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, idx, ptr.baseAddress, Int32(value.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            case is NSNull:
                rc = sqlite3_bind_null(stmt, idx)
            default:
                sqlite3_finalize(stmt)
                throw DatabaseError.invalidData(
                    "Unsupported SQL parameter type at index \(index): \(type(of: param))"
                )
            }
            guard rc == SQLITE_OK else {
                let message = String(cString: sqlite3_errmsg(conn))
                sqlite3_finalize(stmt)
                throw DatabaseError.queryFailed("bind failed at index \(index): \(message)")
            }
        }

        return stmt
    }
}
