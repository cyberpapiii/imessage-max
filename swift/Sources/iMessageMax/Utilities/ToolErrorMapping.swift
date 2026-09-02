import Foundation

enum ToolErrorMapping {
    struct Mapped {
        let code: String
        let message: String
    }

    /// Shared `DatabaseError` → tool-error mapping. All four cases; no `default`.
    /// `.queryFailed` and `.invalidData` log the detail under `context` and
    /// return `ClientErrorMessages.internalError`.
    static func map(_ error: DatabaseError, context: String) -> Mapped {
        switch error {
        case .notFound:
            return Mapped(code: "database_not_found", message: ClientErrorMessages.databaseNotFound)
        case .permissionDenied:
            return Mapped(code: "permission_denied", message: ClientErrorMessages.permissionDenied)
        case .queryFailed(let msg):
            Log.error("\(context): query failed: \(msg)")
            return Mapped(code: "query_failed", message: ClientErrorMessages.internalError)
        case .invalidData(let msg):
            Log.error("\(context): invalid data: \(msg)")
            return Mapped(code: "invalid_data", message: ClientErrorMessages.internalError)
        }
    }
}
