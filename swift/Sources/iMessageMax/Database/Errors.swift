// Sources/iMessageMax/Database/Errors.swift
import Foundation

enum DatabaseError: LocalizedError {
    case permissionDenied(String)
    case notFound(String)
    case queryFailed(String)
    case invalidData(String)
    case cancelled

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
        case .cancelled:
            return "Query cancelled"
        }
    }

    var clientCode: String {
        switch self {
        case .notFound: "database_not_found"
        case .permissionDenied: "permission_denied"
        case .queryFailed: "query_failed"
        case .invalidData: "invalid_data"
        case .cancelled: "cancelled"
        }
    }

    /// Fixed guidance for the client. The description, which carries
    /// filesystem paths, goes to the log under `context`.
    func clientMessage(context: String) -> String {
        if case .cancelled = self { return ClientErrorMessages.cancelled }
        Log.error("\(context): \(localizedDescription)")
        switch self {
        case .notFound: return ClientErrorMessages.databaseNotFound
        case .permissionDenied: return ClientErrorMessages.permissionDenied
        case .queryFailed, .invalidData, .cancelled: return ClientErrorMessages.internalError
        }
    }
}
