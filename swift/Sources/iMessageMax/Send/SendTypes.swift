import Foundation

enum SendPayload: Sendable, Equatable {
    case text(String)
    case file(path: String)

    enum BuildResult {
        case success([SendPayload])
        case failure(String)
    }

    static func build(
        text: String?,
        filePaths: [String]?
    ) -> BuildResult {
        var payloads: [SendPayload] = []

        if let filePaths, !filePaths.isEmpty {
            for path in filePaths where !path.isEmpty {
                payloads.append(.file(path: path))
            }
        }

        if let text, !text.isEmpty {
            guard text.count <= 20_000 else {
                return .failure("Message too long (max 20,000 chars)")
            }
            payloads.append(.text(text))
        }

        guard !payloads.isEmpty else {
            return .failure("At least one of 'text' or 'file_paths' must be provided")
        }

        return .success(payloads)
    }

    var clientDescription: String {
        switch self {
        case .text: return "text message"
        case .file(let path): return "file '\((path as NSString).lastPathComponent)'"
        }
    }

    var scriptKind: SendScript.PayloadKind {
        switch self {
        case .text: return .text
        case .file: return .file
        }
    }
}

enum SendTarget: Sendable, Equatable {
    case participant(handle: String, chatId: Int64?)
    case chat(guid: String, chatId: Int64)

    var chatId: Int64? {
        switch self {
        case .participant(_, let chatId): return chatId
        case .chat(_, let chatId): return chatId
        }
    }

    var participantHandle: String? {
        if case .participant(let handle, _) = self { return handle }
        return nil
    }

    var scriptArgument: String {
        switch self {
        case .participant(let handle, _): return handle
        case .chat(let guid, _): return guid
        }
    }

    var scriptKind: SendScript.TargetKind {
        switch self {
        case .participant: return .participant
        case .chat: return .chat
        }
    }

    var missingTargetError: SendError {
        switch self {
        case .participant(let handle, _): return .recipientNotFound(handle)
        case .chat(let guid, _): return .chatNotFound(guid)
        }
    }

    var validationError: SendError? {
        switch self {
        case .participant(let handle, _):
            return handle.count > 100 ? .invalidParams("Recipient too long") : nil
        case .chat(let guid, _):
            return guid.isEmpty ? .invalidParams("Chat guid is required") : nil
        }
    }
}

enum SendError: LocalizedError {
    case automationPermissionRequired
    case messagesAppUnavailable
    case recipientNotFound(String)
    case chatNotFound(String)
    case fileNotFound(String)
    case transferPending(String)
    case transferFailed(String)
    case transferStatusUnknown(String)
    case timeout
    case failed(String)
    case invalidParams(String)

    var errorDescription: String? {
        switch self {
        case .automationPermissionRequired:
            return """
                Messages.app Automation permission required. \
                When prompted, click 'OK' to allow iMessage Max to send messages. \
                If you missed the prompt: System Settings → Privacy & Security → \
                Automation → Enable Messages.app for your terminal/application.
                """
        case .messagesAppUnavailable:
            return "Messages.app is not responding. Please open Messages.app and try again."
        case .recipientNotFound(let recipient):
            return "Could not find recipient '\(recipient)' in Messages.app."
        case .chatNotFound(let guid):
            return "Could not find chat '\(guid)' in Messages.app."
        case .fileNotFound(let path):
            return "Could not read file at '\(path)'."
        case .transferPending(let filename):
            return "Messages accepted '\(filename)', but the transfer is still pending and could not be confirmed as delivered yet."
        case .transferFailed(let filename):
            return "Messages created a transfer for '\(filename)', but it failed."
        case .transferStatusUnknown(let filename):
            return "Messages accepted '\(filename)', but no reliable transfer status could be confirmed."
        case .timeout:
            return "Send operation timed out. Messages.app may be unresponsive."
        case .failed(let message):
            return "Send failed: \(message)"
        case .invalidParams(let message):
            return message
        }
    }

    var isSoftTransferOutcome: Bool {
        switch self {
        case .transferPending, .transferStatusUnknown: return true
        default: return false
        }
    }
}

enum DeliveryDisposition: String, Sendable, Encodable, Equatable {
    case completed
    case notStarted = "not_started"
    case mayHaveCompleted = "may_have_completed"

    var retrySafe: Bool { self == .notStarted }
}

struct SendFailure: Error, Sendable {
    let error: SendError
    let disposition: DeliveryDisposition

    init(_ error: SendError, disposition: DeliveryDisposition) {
        self.error = error
        self.disposition = disposition
    }
}
