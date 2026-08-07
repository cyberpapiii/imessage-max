import Foundation

enum ClientErrorMessages {
    static let databaseNotFound = "iMessage database not found. Run the diagnose tool for setup help."
    static let permissionDenied = "Cannot read the iMessage database (Full Disk Access may be missing). Run the diagnose tool."
    static let internalError = "Internal error. Check the server log for details."

    /// Client-safe rendering of an arbitrary error. DatabaseError carries
    /// filesystem paths in its description (useful in logs, not for clients);
    /// map it to the fixed guidance strings and log the detailed form to
    /// stderr. All other errors pass through unchanged.
    static func sanitized(_ error: Error) -> String {
        guard let dbError = error as? DatabaseError else {
            return error.localizedDescription
        }
        FileHandle.standardError.write(
            Data("[imessage-max] database error: \(dbError.localizedDescription)\n".utf8)
        )
        switch dbError {
        case .permissionDenied: return permissionDenied
        case .notFound: return databaseNotFound
        case .queryFailed, .invalidData: return internalError
        }
    }
}
