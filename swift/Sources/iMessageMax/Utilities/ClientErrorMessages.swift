import Foundation

enum ClientErrorMessages {
    static let databaseNotFound = "iMessage database not found. Run the diagnose tool for setup help."
    static let permissionDenied = "Cannot read the iMessage database (Full Disk Access may be missing). Run the diagnose tool."
    static let internalError = "Internal error. Check the server log for details."
    static let cancelled = "Request cancelled."

    // Not-found errors name the tool that returns a current id, so the
    // caller can recover without guessing.
    static func chatNotFound(_ chatId: String) -> String {
        "Chat not found: \(chatId). Call list_chats or find_chat for a current chat_id."
    }
    static let messageNotFound = "Target message not found. Call search or get_messages for a current message_id."
    static func attachmentNotFound(_ attachmentId: String) -> String {
        "Attachment not found: \(attachmentId). Call list_attachments for a current attachment_id."
    }

    /// Client-safe rendering of an arbitrary error. DatabaseError carries
    /// filesystem paths in its description (useful in logs, not for clients);
    /// map it to the fixed guidance strings and log the detailed form to
    /// stderr. All other errors pass through unchanged.
    static func sanitized(_ error: Error) -> String {
        guard let dbError = error as? DatabaseError else {
            return error.localizedDescription
        }
        Log.error("database error: \(dbError.localizedDescription)")
        switch dbError {
        case .permissionDenied: return permissionDenied
        case .notFound: return databaseNotFound
        case .queryFailed, .invalidData: return internalError
        case .cancelled: return cancelled
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
        Log.error("\(context): \(error.localizedDescription)")
        return "\(context) failed. Check the server log for details."
    }
}
