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
    let timestamp: String?
    let chat: ChatReference?
    let deliveredTo: [String]?
    let chatId: String?
    let message: String?
    let error: String?
    let candidates: [RecipientCandidate]?

    enum CodingKeys: String, CodingKey {
        case status
        case timestamp
        case chat
        case deliveredTo = "delivered_to"
        case chatId = "chat_id"
        case message
        case error
        case candidates
    }

    static func success(deliveredTo: [String], chat: ChatReference?) -> SendResponse {
        SendResponse(
            status: "sent",
            timestamp: TimeUtils.formatISO(Date()),
            chat: chat,
            deliveredTo: deliveredTo,
            chatId: chat?.id,
            message: nil,
            error: nil,
            candidates: nil
        )
    }

    static func pending(_ message: String, deliveredTo: [String], chat: ChatReference?) -> SendResponse {
        SendResponse(
            status: "pending_confirmation",
            timestamp: TimeUtils.formatISO(Date()),
            chat: chat,
            deliveredTo: deliveredTo,
            chatId: chat?.id,
            message: message,
            error: nil,
            candidates: nil
        )
    }

    static func cancelled(_ message: String, deliveredTo: [String], chat: ChatReference?) -> SendResponse {
        SendResponse(
            status: "cancelled",
            timestamp: TimeUtils.formatISO(Date()),
            chat: chat,
            deliveredTo: deliveredTo,
            chatId: chat?.id,
            message: message,
            error: nil,
            candidates: nil
        )
    }

    static func error(_ message: String) -> SendResponse {
        SendResponse(
            status: "failed",
            timestamp: nil,
            chat: nil,
            deliveredTo: nil,
            chatId: nil,
            message: nil,
            error: message,
            candidates: nil
        )
    }

    static func ambiguous(candidates: [RecipientCandidate]) -> SendResponse {
        SendResponse(
            status: "ambiguous",
            timestamp: nil,
            chat: nil,
            deliveredTo: nil,
            chatId: nil,
            message: "Multiple contacts match. Please specify using a phone number, email, or chat_id.",
            error: nil,
            candidates: candidates
        )
    }
}

// MARK: - Send Tool

/// Send tool implementation
actor SendTool {
    private let db: Database
    private let resolver: ContactResolver
    private let runner: any ScriptRunning
    private lazy var sendResolver = SendResolver(db: db, resolver: resolver)

    init(db: Database = Database(), resolver: ContactResolver, runner: any ScriptRunning = LiveScriptRunner()) {
        self.db = db
        self.resolver = resolver
        self.runner = runner
    }

    // MARK: - Tool Registration

    static func register(on server: Server, resolver: ContactResolver) {
        let tool = SendTool(resolver: resolver)

        server.registerTool(
            name: "send",
            description: """
                Send a message or file to a person or an existing chat.

                Prefer 'chat_id' when the exact thread matters.
                Use 'to' when starting from a person is acceptable.
                chat_id is an exact tool-call target; when talking to the user, refer to the destination by the returned chat.name or recipient names.
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
                    "confirm": .boolean(description: "Explicitly confirm risky sends when elicitation is unavailable"),
                ]
            ),
            outputSchema: OutputSchema.object,
            annotations: Tool.Annotations(
                title: "Send Message",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: true
            )
        ) { args in
            try await tool.execute(args: args, server: server)
        }
    }

    // MARK: - Execution

    func execute(args: [String: Value]?, server: Server? = nil) async throws -> [Tool.Content] {
        let to = args?["to"]?.stringValue
        let chatId = args?["chat_id"]?.stringValue
        let text = args?["text"]?.stringValue
        let filePaths = args?["file_paths"]?.arrayValue?.compactMap { $0.stringValue }
        let replyTo = args?["reply_to"]?.stringValue
        let confirm = args?["confirm"]?.boolValue ?? false

        let response = await send(
            to: to,
            chatId: chatId,
            text: text,
            filePaths: filePaths,
            replyTo: replyTo,
            confirm: confirm,
            server: server
        )
        let content: [Tool.Content] = [.plainText(try FormatUtils.encodeJSON(response))]
        if response.status == "failed" || response.status == "ambiguous" {
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
        replyTo: String?,
        confirm: Bool,
        server: Server?
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

        if shouldConfirmSend(resolved: resolved, text: text, filePaths: filePaths), !confirm {
            switch await confirmSendWithClientIfAvailable(server: server, resolved: resolved, text: text, filePaths: filePaths) {
            case .confirmed:
                break
            case .declined:
                return .cancelled("Send cancelled by user confirmation.", deliveredTo: resolved.deliveredTo, chat: resolved.chat)
            case .unavailable:
                return .pending(
                    "This send requires confirmation. Call send again with confirm: true after reviewing the destination and content.",
                    deliveredTo: resolved.deliveredTo,
                    chat: resolved.chat
                )
            }
        }

        let sendResults: [Result<Void, SendError>]
        switch resolved.target {
        case .participant(let handle, _):
            sendResults = payloads.map { payload in
                switch payload {
                case .text(let body):
                    return runner.sendTextToParticipant(handle: handle, message: body)
                case .file(let path):
                    return runner.sendFileToParticipant(handle: handle, filePath: path)
                }
            }
        case .chat(let guid, _):
            sendResults = payloads.map { payload in
                switch payload {
                case .text(let body):
                    return runner.sendTextToChat(guid: guid, message: body)
                case .file(let path):
                    return runner.sendFileToChat(guid: guid, filePath: path)
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
                chat: resolved.chat
            )
        }

        return .success(deliveredTo: resolved.deliveredTo, chat: resolved.chat)
    }

    private enum ConfirmationDecision {
        case confirmed
        case declined
        case unavailable
    }

    private func shouldConfirmSend(
        resolved: SendResolution.ResolvedTarget,
        text: String?,
        filePaths: [String]?
    ) -> Bool {
        if resolved.deliveredTo.count > 1 { return true }
        if filePaths?.isEmpty == false { return true }
        if let text, text.count > 500 { return true }
        if case .chat = resolved.target { return true }
        return false
    }

    private func confirmSendWithClientIfAvailable(
        server: Server?,
        resolved: SendResolution.ResolvedTarget,
        text: String?,
        filePaths: [String]?
    ) async -> ConfirmationDecision {
        guard let server else { return .unavailable }

        let destination = resolved.chat?.name ?? resolved.deliveredTo.joined(separator: ", ")
        let fileCount = filePaths?.count ?? 0
        let textPreview = (text?.isEmpty == false) ? text! : "(no text)"
        let clippedPreview = textPreview.count > 240
            ? String(textPreview.prefix(240)) + "..."
            : textPreview

        do {
            let result = try await server.requestElicitation(
                message: """
                    Confirm sending this iMessage to \(destination).

                    Text: \(clippedPreview)
                    Attachments: \(fileCount)
                    """,
                requestedSchema: .init(
                    title: "Confirm iMessage Send",
                    description: "Review the destination and content before sending.",
                    properties: [
                        "confirm": .object([
                            "type": .string("boolean"),
                            "description": .string("Set true to send this message."),
                        ]),
                    ],
                    required: ["confirm"]
                ),
                mode: .form
            )

            guard result.action == .accept else { return .declined }
            return result.content?["confirm"]?.boolValue == true ? .confirmed : .declined
        } catch {
            return .unavailable
        }
    }
}
