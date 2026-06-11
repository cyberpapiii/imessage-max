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
    // Verification fields (non-nil only for "confirmed")
    let verifiedMessageGuid: String?
    let verifiedAt: String?
    // Mismatch fields (non-nil only for "mismatch")
    let intendedChat: ChatReference?
    let actualChatId: String?

    enum CodingKeys: String, CodingKey {
        case status
        case timestamp
        case chat
        case deliveredTo = "delivered_to"
        case chatId = "chat_id"
        case message
        case error
        case candidates
        case verifiedMessageGuid = "verified_message_guid"
        case verifiedAt = "verified_at"
        case intendedChat = "intended_chat"
        case actualChatId = "actual_chat_id"
    }

    // MARK: - Transport-only fallback ("sent")
    // Returned only when verification cannot run (DB unreadable). Option D §4.3.
    static func success(deliveredTo: [String], chat: ChatReference?) -> SendResponse {
        SendResponse(
            status: "sent",
            timestamp: TimeUtils.formatISO(Date()),
            chat: chat,
            deliveredTo: deliveredTo,
            chatId: chat?.id,
            message: nil,
            error: nil,
            candidates: nil,
            verifiedMessageGuid: nil,
            verifiedAt: nil,
            intendedChat: nil,
            actualChatId: nil
        )
    }

    // MARK: - Verified-send proof states (design §4.1)

    /// DB re-read found the outbound row in the intended chat with error = 0.
    static func confirmed(guid: String, deliveredTo: [String], chat: ChatReference?) -> SendResponse {
        SendResponse(
            status: "confirmed",
            timestamp: TimeUtils.formatISO(Date()),
            chat: chat,
            deliveredTo: deliveredTo,
            chatId: chat?.id,
            message: nil,
            error: nil,
            candidates: nil,
            verifiedMessageGuid: guid,
            verifiedAt: TimeUtils.formatISO(Date()),
            intendedChat: nil,
            actualChatId: nil
        )
    }

    /// Transport succeeded but row not found in DB within the polling window.
    static func uncertain(deliveredTo: [String], chat: ChatReference?) -> SendResponse {
        let id = chat?.id
        let name = chat?.name ?? id ?? "the intended chat"
        let followUp = id.map { "Use get_messages on \($0) to confirm." }
            ?? "Use get_messages on \(name) to confirm."
        return SendResponse(
            status: "uncertain",
            timestamp: TimeUtils.formatISO(Date()),
            chat: chat,
            deliveredTo: deliveredTo,
            chatId: id,
            message: "Send accepted by Messages.app but could not be verified in chat.db within the polling window. The message was probably sent. \(followUp)",
            error: nil,
            candidates: nil,
            verifiedMessageGuid: nil,
            verifiedAt: nil,
            intendedChat: nil,
            actualChatId: nil
        )
    }

    /// Row found in a different chat than intended. Routing mismatch (R5).
    static func mismatch(intendedChat: ChatReference?, actualChatId: Int64, deliveredTo: [String]) -> SendResponse {
        SendResponse(
            status: "mismatch",
            timestamp: TimeUtils.formatISO(Date()),
            chat: nil,
            deliveredTo: deliveredTo,
            chatId: nil,
            message: "Message was found in a different chat than intended. This is a routing mismatch. Do not treat as confirmed.",
            error: nil,
            candidates: nil,
            verifiedMessageGuid: nil,
            verifiedAt: nil,
            intendedChat: intendedChat,
            actualChatId: "chat\(actualChatId)"
        )
    }

    // MARK: - Existing statuses (unchanged)

    static func pending(_ message: String, deliveredTo: [String], chat: ChatReference?) -> SendResponse {
        SendResponse(
            status: "pending_confirmation",
            timestamp: TimeUtils.formatISO(Date()),
            chat: chat,
            deliveredTo: deliveredTo,
            chatId: chat?.id,
            message: message,
            error: nil,
            candidates: nil,
            verifiedMessageGuid: nil,
            verifiedAt: nil,
            intendedChat: nil,
            actualChatId: nil
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
            candidates: nil,
            verifiedMessageGuid: nil,
            verifiedAt: nil,
            intendedChat: nil,
            actualChatId: nil
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
            candidates: nil,
            verifiedMessageGuid: nil,
            verifiedAt: nil,
            intendedChat: nil,
            actualChatId: nil
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
            candidates: candidates,
            verifiedMessageGuid: nil,
            verifiedAt: nil,
            intendedChat: nil,
            actualChatId: nil
        )
    }
}

// MARK: - Send Tool

/// Send tool implementation
actor SendTool {
    private let db: Database
    private let resolver: ContactResolver
    private let runner: any ScriptRunning
    private let verifier: SendVerifier
    private let confirmationTimeout: Duration
    private lazy var sendResolver = SendResolver(db: db, resolver: resolver)

    init(
        db: Database = Database(),
        resolver: ContactResolver,
        runner: any ScriptRunning = LiveScriptRunner(),
        verifier: SendVerifier? = nil,
        confirmationTimeout: Duration = .seconds(25)
    ) {
        self.db = db
        self.resolver = resolver
        self.runner = runner
        self.verifier = verifier ?? SendVerifier(db: db)
        self.confirmationTimeout = confirmationTimeout
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

                Proof vocabulary for text sends (status field):
                  confirmed — row found in chat.db with error=0; include verified_message_guid as evidence.
                  uncertain — transport accepted but row not found within polling window; follow up with get_messages.
                  mismatch  — row found in a different chat than intended; alert the user, do not treat as success.
                  sent      — verification unavailable (DB unreadable); transport accepted only.
                File sends and failed/cancelled/ambiguous states are unchanged.
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

        // Capture send time before dispatch (design §5.2 option 1).
        let sendTime = Date()

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

        // All payloads succeeded. For text payloads, run post-send DB verification.
        // File payloads keep the unchanged transfer-observation status.
        let textBodies: [String] = payloads.compactMap {
            if case .text(let body) = $0 { return body }
            return nil
        }

        guard let lastText = textBodies.last else {
            // File-only send — verification does not apply; status unchanged.
            return .success(deliveredTo: resolved.deliveredTo, chat: resolved.chat)
        }

        // Extract chatId and handle from the resolved target for the verifier.
        let intendedChatId: Int64?
        let participantHandle: String?
        switch resolved.target {
        case .participant(let handle, let cid):
            participantHandle = handle
            intendedChatId = cid.map(Int64.init)
        case .chat(_, let cid):
            participantHandle = nil
            intendedChatId = Int64(cid)
        }

        do {
            let verification = try await verifier.verify(
                intendedChatId: intendedChatId,
                handle: participantHandle,
                sendTime: sendTime,
                expectedText: lastText
            )
            switch verification {
            case .confirmed(let guid, _):
                return .confirmed(guid: guid, deliveredTo: resolved.deliveredTo, chat: resolved.chat)
            case .mismatch(let actualChatId, _):
                return .mismatch(
                    intendedChat: resolved.chat,
                    actualChatId: actualChatId,
                    deliveredTo: resolved.deliveredTo
                )
            case .notFound:
                return .uncertain(deliveredTo: resolved.deliveredTo, chat: resolved.chat)
            }
        } catch {
            // DB unreadable or task cancelled → Option D: transport-only fallback.
            return .success(deliveredTo: resolved.deliveredTo, chat: resolved.chat)
        }
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

        let result = await AsyncTimeout.withTimeout(confirmationTimeout) {
            try await server.requestElicitation(
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
        }
        guard let result else { return .unavailable }   // timeout or transport error
        guard result.action == .accept else { return .declined }
        return result.content?["confirm"]?.boolValue == true ? .confirmed : .declined
    }
}
