import Foundation

enum ClientErrorMessages {
    static let databaseNotFound = "iMessage database not found. Run the diagnose tool for setup help."
    static let permissionDenied = "Cannot read the iMessage database. Full Disk Access may be missing. Run the diagnose tool."
    static let internalError = "Internal error. Check the server log for details."
    static let cancelled = "Request cancelled."

    static func chatNotFound(_ chatId: String) -> String {
        "Chat not found: \(chatId). Call list_chats or find_chat for a current chat_id."
    }
    static let messageNotFound = "Target message not found. Call search or get_messages for a current message_id."
    static func attachmentNotFound(_ attachmentId: String) -> String {
        "Attachment not found: \(attachmentId). Call list_attachments for a current attachment_id."
    }

    static func sanitized(_ error: Error) -> String {
        guard let dbError = error as? DatabaseError else {
            return error.localizedDescription
        }
        return dbError.clientMessage(context: "database error")
    }

    static func internalDetail(_ error: Error, context: String) -> String {
        Log.error("\(context): \(error.localizedDescription)")
        return "\(context) failed. Check the server log for details."
    }
}

extension DatabaseError {
    func clientMessage(context: String) -> String {
        let message: String
        switch self {
        case .cancelled: return ClientErrorMessages.cancelled
        case .notFound: message = ClientErrorMessages.databaseNotFound
        case .permissionDenied: message = ClientErrorMessages.permissionDenied
        case .queryFailed, .invalidData: message = ClientErrorMessages.internalError
        }
        Log.error("\(context): \(localizedDescription)")
        return message
    }
}
