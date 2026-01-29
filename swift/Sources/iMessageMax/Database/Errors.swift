// Sources/iMessageMax/Database/Errors.swift
import Foundation

enum DatabaseError: LocalizedError {
    case permissionDenied(String)
    case notFound(String)
    case queryFailed(String)
    case invalidData(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let path):
            return "Permission denied accessing \(path). Grant Full Disk Access in System Settings."
        case .notFound(let path):
            return "Database not found at \(path). Ensure iMessage is set up."
        case .queryFailed(let msg):
            return "Query failed: \(msg)"
        case .invalidData(let msg):
            return "Invalid data: \(msg)"
        }
    }
}
