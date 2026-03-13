// Sources/iMessageMax/Tools/Send.swift
import Foundation
import MCP

// MARK: - Response Types

/// Candidate for disambiguation when multiple contacts match
struct RecipientCandidate: Encodable {
    let name: String
    let handle: String
    let lastContact: String

    enum CodingKeys: String, CodingKey {
        case name, handle
        case lastContact = "last_contact"
    }
}

/// Response from the send tool
struct SendResponse: Encodable {
    let status: String
    let success: Bool
    let messageId: String?
    let timestamp: String?
    let deliveredTo: [String]?
    let chatId: String?
    let message: String?
    let error: String?
    let ambiguousRecipient: AmbiguousRecipientInfo?

    struct AmbiguousRecipientInfo: Encodable {
        let message: String
        let candidates: [RecipientCandidate]
    }

    enum CodingKeys: String, CodingKey {
        case status
        case success
        case messageId = "message_id"
        case timestamp
        case deliveredTo = "delivered_to"
        case chatId = "chat_id"
        case message
        case error
        case ambiguousRecipient = "ambiguous_recipient"
    }

    static func success(deliveredTo: [String], chatId: Int?) -> SendResponse {
        SendResponse(
            status: "sent",
            success: true,
            messageId: nil,  // Cannot reliably retrieve new message ID
            timestamp: TimeUtils.formatISO(Date()),
            deliveredTo: deliveredTo,
            chatId: chatId.map { "chat\($0)" },
            message: nil,
            error: nil,
            ambiguousRecipient: nil
        )
    }

    static func pending(_ message: String, deliveredTo: [String], chatId: Int?) -> SendResponse {
        SendResponse(
            status: "pending_confirmation",
            success: false,
            messageId: nil,
            timestamp: TimeUtils.formatISO(Date()),
            deliveredTo: deliveredTo,
            chatId: chatId.map { "chat\($0)" },
            message: message,
            error: nil,
            ambiguousRecipient: nil
        )
    }

    static func error(_ message: String) -> SendResponse {
        SendResponse(
            status: "failed",
            success: false,
            messageId: nil,
            timestamp: nil,
            deliveredTo: nil,
            chatId: nil,
            message: nil,
            error: message,
            ambiguousRecipient: nil
        )
    }

    static func ambiguous(candidates: [RecipientCandidate]) -> SendResponse {
        SendResponse(
            status: "ambiguous",
            success: false,
            messageId: nil,
            timestamp: nil,
            deliveredTo: nil,
            chatId: nil,
            message: nil,
            error: nil,
            ambiguousRecipient: AmbiguousRecipientInfo(
                message: "Multiple contacts match. Please specify using a phone number, email, or chat_id.",
                candidates: candidates
            )
        )
    }
}

// MARK: - Send Tool

/// Send tool implementation
actor SendTool {
    private let db: Database
    private let resolver: ContactResolver
    private lazy var sendResolver = SendResolver(db: db, resolver: resolver)

    init(db: Database = Database(), resolver: ContactResolver) {
        self.db = db
        self.resolver = resolver
    }

    // MARK: - Tool Registration

    static func register(on server: Server, resolver: ContactResolver) {
        let tool = SendTool(resolver: resolver)

        server.registerTool(
            name: "send",
            description: """
                Send a message to a person or group chat.

                Use 'to' for individual recipients (name, phone, or email).
                Use 'chat_id' for group chats or when disambiguation is needed.
                """,
            inputSchema: InputSchema.object(
                properties: [
                    "to": .string(description: "Contact name, phone number, or email"),
                    "chat_id": .string(description: "Existing chat ID (for groups or disambiguation)"),
                    "text": .string(description: "Message content to send"),
                    "file_paths": .array(
                        description: "Local file paths to send as attachments. If combined with text, files are sent first and text is sent last.",
                        items: .string(description: "Absolute or ~/expanded local file path")
                    ),
                    "reply_to": .string(description: "Message ID to reply to (not yet implemented)"),
                ]
            ),
            annotations: Tool.Annotations(
                title: "Send Message",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: true
            )
        ) { args in
            try await tool.execute(args: args)
        }
    }

    // MARK: - Execution

    func execute(args: [String: Value]?) async throws -> [Tool.Content] {
        let to = args?["to"]?.stringValue
        let chatId = args?["chat_id"]?.stringValue
        let text = args?["text"]?.stringValue
        let filePaths = args?["file_paths"]?.arrayValue?.compactMap { $0.stringValue }
        let replyTo = args?["reply_to"]?.stringValue

        let response = await send(
            to: to,
            chatId: chatId,
            text: text,
            filePaths: filePaths,
            replyTo: replyTo
        )
        let content: [Tool.Content] = [.text(try FormatUtils.encodeJSON(response))]
        if !response.success && response.status != "pending_confirmation" {
            throw ToolError(content: content)
        }
        return content
    }

    // MARK: - Send Implementation

    /// Send a message to a person or group chat
    private func send(
        to: String?,
        chatId: String?,
        text: String?,
        filePaths: [String]?,
        replyTo: String?
    ) async -> SendResponse {
        // Validation
        guard to != nil || chatId != nil else {
            return .error("Either 'to' or 'chat_id' must be provided")
        }

        // reply_to is not yet implemented
        if replyTo != nil {
            return .error("reply_to is not yet implemented")
        }

        let payloads: [SendPayload]
        switch SendPayload.build(text: text, filePaths: filePaths) {
        case .success(let built):
            payloads = built
        case .failure(let message):
            return .error(message)
        }

        // Initialize contacts resolver
        try? await resolver.initialize()

        let resolution = await sendResolver.resolve(chatId: chatId, to: to)
        let resolved: SendResolution.ResolvedTarget
        switch resolution {
        case .success(let target):
            resolved = target
        case .failure(let errorMsg):
            return .error(errorMsg)
        case .ambiguous(let candidates):
            return .ambiguous(candidates: candidates)
        }

        let targetChatId: Int?
        let sendResults: [Result<Void, SendError>]
        switch resolved.target {
        case .participant(let handle, let resolvedChatId):
            targetChatId = resolvedChatId
            sendResults = payloads.map { payload in
                switch payload {
                case .text(let body):
                    return AppleScriptRunner.sendTextToParticipant(handle: handle, message: body)
                case .file(let path):
                    return AppleScriptRunner.sendFileToParticipant(handle: handle, filePath: path)
                }
            }
        case .chat(let guid, let resolvedChatId):
            targetChatId = resolvedChatId
            sendResults = payloads.map { payload in
                switch payload {
                case .text(let body):
                    return AppleScriptRunner.sendTextToChat(guid: guid, message: body)
                case .file(let path):
                    return AppleScriptRunner.sendFileToChat(guid: guid, filePath: path)
                }
            }
        }

        var pendingMessages: [String] = []
        for result in sendResults {
            if case .failure(let error) = result {
                switch error {
                case .transferPending, .transferStatusUnknown:
                    pendingMessages.append(error.localizedDescription)
                default:
                    return .error(error.localizedDescription)
                }
            }
        }

        if !pendingMessages.isEmpty {
            return .pending(
                pendingMessages.joined(separator: " "),
                deliveredTo: resolved.deliveredTo,
                chatId: targetChatId
            )
        }

        return .success(deliveredTo: resolved.deliveredTo, chatId: targetChatId)
    }
}
