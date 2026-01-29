// Sources/iMessageMax/Database/SQLiteRow.swift
import Foundation
import SQLite3

struct SQLiteRow {
    private let stmt: OpaquePointer

    init(_ stmt: OpaquePointer) {
        self.stmt = stmt
    }

    func int(_ column: Int32) -> Int64 {
        sqlite3_column_int64(stmt, column)
    }

    func optionalInt(_ column: Int32) -> Int64? {
        if sqlite3_column_type(stmt, column) == SQLITE_NULL {
            return nil
        }
        return sqlite3_column_int64(stmt, column)
    }

    func string(_ column: Int32) -> String? {
        guard let cstr = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: cstr)
    }

    func blob(_ column: Int32) -> Data? {
        guard let ptr = sqlite3_column_blob(stmt, column) else { return nil }
        let size = sqlite3_column_bytes(stmt, column)
        return Data(bytes: ptr, count: Int(size))
    }

    func double(_ column: Int32) -> Double {
        sqlite3_column_double(stmt, column)
    }
}
