import Foundation

enum ToolErrorMapping {
    struct Mapped {
        let code: String
        let message: String
    }

    /// Shared `DatabaseError` → tool-error mapping. All four cases; no `default`.
    static func map(_ error: DatabaseError, context _: String) -> Mapped {
        switch error {
        case .notFound:
            return Mapped(code: "database_not_found", message: ClientErrorMessages.databaseNotFound)
        case .permissionDenied:
            return Mapped(code: "permission_denied", message: ClientErrorMessages.permissionDenied)
        case .queryFailed(let msg):
            return Mapped(code: "query_failed", message: msg)
        case .invalidData(let msg):
            return Mapped(code: "invalid_data", message: msg)
        }
    }
}
