// Sources/iMessageMax/Database/Database.swift
import Foundation
import SQLite3

final class Database: @unchecked Sendable {
    static let defaultPath: String = {
        ("~/Library/Messages/chat.db" as NSString).expandingTildeInPath
    }()

    private let path: String

    init(path: String = Database.defaultPath) {
        self.path = path
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

        // Try to actually open
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

    func query<T>(
        _ sql: String,
        params: [Any] = [],
        map: (SQLiteRow) throws -> T
    ) throws -> [T] {
        let conn = try openReadOnly()
        defer { sqlite3_close(conn) }

        let stmt = try prepare(conn, sql: sql, params: params)
        defer { sqlite3_finalize(stmt) }

        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            try results.append(map(SQLiteRow(stmt)))
        }
        return results
    }

    func execute(_ sql: String, params: [Any] = []) throws {
        let conn = try openReadOnly()
        defer { sqlite3_close(conn) }

        let stmt = try prepare(conn, sql: sql, params: params)
        defer { sqlite3_finalize(stmt) }

        let result = sqlite3_step(stmt)
        if result != SQLITE_DONE && result != SQLITE_ROW {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(conn)))
        }
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
            throw DatabaseError.permissionDenied(path)
        }

        // Safety settings
        sqlite3_busy_timeout(db, 1000)
        var errMsg: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, &errMsg)

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

        // Bind parameters
        for (index, param) in params.enumerated() {
            let idx = Int32(index + 1)
            switch param {
            case let value as Int:
                sqlite3_bind_int64(stmt, idx, Int64(value))
            case let value as Int64:
                sqlite3_bind_int64(stmt, idx, value)
            case let value as String:
                sqlite3_bind_text(stmt, idx, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let value as Double:
                sqlite3_bind_double(stmt, idx, value)
            case let value as Data:
                value.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, idx, ptr.baseAddress, Int32(value.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            case is NSNull:
                sqlite3_bind_null(stmt, idx)
            default:
                sqlite3_bind_null(stmt, idx)
            }
        }

        return stmt
    }
}
