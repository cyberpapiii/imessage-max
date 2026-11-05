import Foundation

// MARK: - What to send, and where

/// One item handed to Messages.app. A send with files and text becomes
/// several payloads, files first and text last.
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
            payloads.append(.text(text))
        }

        guard !payloads.isEmpty else {
            return .failure("At least one of 'text' or 'file_paths' must be provided")
        }

        return .success(payloads)
    }

    /// Set when this payload must be refused before it reaches Messages.
    var validationError: SendError? {
        if case .text(let body) = self, body.count > 20_000 {
            return .invalidParams("Message too long (max 20,000 chars)")
        }
        return nil
    }

    /// Client-facing description, for the partial-failure breakdown.
    /// Files are named by filename only, never the full path (plan 023).
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

/// An exact Messages.app destination. `chatId` is the chat.db ROWID the
/// send is expected to land in, used for post-send verification; a
/// participant with no existing 1:1 chat has none.
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

    /// The value the send script resolves inside Messages.app.
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

    /// What a "can't get participant/chat" AppleScript error means for this target.
    var missingTargetError: SendError {
        switch self {
        case .participant(let handle, _): return .recipientNotFound(handle)
        case .chat(let guid, _): return .chatNotFound(guid)
        }
    }

    /// Set when this target must be refused before anything reaches Messages.
    var validationError: SendError? {
        switch self {
        case .participant(let handle, _):
            return handle.count > 100 ? .invalidParams("Recipient too long") : nil
        case .chat(let guid, _):
            return guid.isEmpty ? .invalidParams("Chat guid is required") : nil
        }
    }
}

// MARK: - How a send failed

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

    /// Messages accepted the file but its transfer had not finished when
    /// polling stopped. The send keeps going and reports
    /// pending_confirmation rather than failing.
    var isSoftTransferOutcome: Bool {
        switch self {
        case .transferPending, .transferStatusUnknown: return true
        default: return false
        }
    }
}

/// How far a transport attempt got before it stopped. Mirrors the
/// dispatchPhase tracked inside the send AppleScript.
enum DeliveryDisposition: String, Sendable, Encodable, Equatable {
    /// Messages.app returned from `send` without raising an error.
    case completed
    /// The failure happened before the `send` Apple event was issued.
    /// Retrying cannot produce a duplicate.
    case notStarted = "not_started"
    /// The failure happened after the `send` Apple event was issued, or we
    /// cannot tell (timeout, osascript killed, no structured result).
    case mayHaveCompleted = "may_have_completed"

    /// True only when a retry provably cannot duplicate a message.
    var retrySafe: Bool { self == .notStarted }
}

/// A transport failure plus how far it got.
struct SendFailure: Error, Sendable {
    let error: SendError
    let disposition: DeliveryDisposition

    init(_ error: SendError, disposition: DeliveryDisposition) {
        self.error = error
        self.disposition = disposition
    }
}
