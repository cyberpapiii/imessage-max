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

    /// Client-safe rendering of an error that may embed internal filesystem
    /// paths: staged-attachment directories, tool binaries, temp files.
    /// Unlike `sanitized`, this never passes the underlying description
    /// through. The detail goes to stderr for the operator and the client
    /// gets a fixed string plus the caller-supplied context.
    ///
    /// Use this at `catch` sites whose errors come from FileManager, Process,
    /// or AppleScript execution. Use `sanitized` when the error may be a
    /// `DatabaseError` and its guidance strings are what the client needs.
    static func internalDetail(_ error: Error, context: String) -> String {
        FileHandle.standardError.write(
            Data("[imessage-max] \(context): \(error.localizedDescription)\n".utf8)
        )
        return "\(context) failed. Check the server log for details."
    }
}
