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

    /// Row found in the intended chat with error ≠ 0. Delivery failed (verified).
    static func failedDelivery(guid: String, errorCode: Int, deliveredTo: [String], chat: ChatReference?) -> SendResponse {
        SendResponse(
            status: "failed_delivery",
            timestamp: TimeUtils.formatISO(Date()),
            chat: chat,
            deliveredTo: deliveredTo,
            chatId: chat?.id,
            message: "Messages.app accepted the send but chat.db recorded a delivery failure (error \(errorCode)). The message was NOT delivered. Do not tell the user it was sent; check the destination can receive iMessages and consider resending.",
            error: nil,
            candidates: nil,
            verifiedMessageGuid: guid,
            verifiedAt: TimeUtils.formatISO(Date()),
            intendedChat: nil,
            actualChatId: nil
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

    /// Some payloads were dispatched to Messages.app before a later payload failed.
    static func partialFailure(
        sentDescriptions: [String], failedDescription: String, error: String,
        deliveredTo: [String], chat: ChatReference?
    ) -> SendResponse {
        SendResponse(
            status: "partial_failure",
            timestamp: TimeUtils.formatISO(Date()),
            chat: chat,
            deliveredTo: deliveredTo,
            chatId: chat?.id,
            message: "PARTIAL SEND: \(sentDescriptions.joined(separator: ", ")) already dispatched to Messages.app (not verified) before \(failedDescription) failed. Do NOT resend the already-dispatched payload(s); retry only the failed one.",
            error: error,
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
    private lazy var sendResolver = SendResolver(db: db, resolver: resolver)

    init(
        db: Database = Database(),
        resolver: ContactResolver,
        runner: any ScriptRunning = LiveScriptRunner(),
        verifier: SendVerifier? = nil
    ) {
        self.db = db
        self.resolver = resolver
        self.runner = runner
        self.verifier = verifier ?? SendVerifier(db: db)
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
                  confirmed: row found in chat.db with error=0. Include verified_message_guid as evidence.
                  uncertain: transport accepted but no row appeared within the polling window. Follow up with get_messages.
                  mismatch: row found in a different chat than intended. Alert the user, do not treat as success.
                  failed_delivery: row found with a delivery error recorded. The message was NOT delivered.
                  partial_failure: some payloads were dispatched before a later one failed. The message lists which. Never blind-retry the whole call.
                  sent: verification unavailable (DB unreadable). Transport accepted only.
                Sends execute immediately when the destination is exact. Ambiguous destinations return status 'ambiguous' without sending. Invalid input returns status 'failed' without sending. File transfers may return 'pending_confirmation' while Messages.app completes the transfer.
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
                    "confirm": .boolean(description: "Deprecated; accepted for compatibility and ignored. Sends do not require confirmation. An ambiguous destination is refused with status 'ambiguous', and the tool verifies results after sending."),
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
        let content: [Tool.Content] = [.plainText(try FormatUtils.encodeJSON(response))]
        if response.status == "failed" || response.status == "ambiguous"
            || response.status == "failed_delivery" || response.status == "partial_failure" {
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

        // Sends are authorized by the user's request to the agent and by
        // harness-level tool approval. The server does not gate exact sends.
        // Ambiguity and validation failures refuse above, and post-send
        // verification reports the truth below. Interactive confirmation (MCP
        // elicitation) was removed 2026-06-11 after it proved unable to
        // round-trip through real agent stacks. See "Elicitation channel
        // findings" in plans/README.md. Do not reintroduce without
        // session-level proof of a working channel.

        // Capture send time before dispatch (design §5.2 option 1).
        let sendTime = Date()

        // Sequential by design: Messages.app ordering matters, so a text that
        // follows a file must be sent after that file. Do not parallelize.
        // Stops at the first hard failure: firing later payloads after one has
        // failed produces out-of-order conversations and compounds the partial
        // reporting below. Soft transfer outcomes keep sending.
        var sendResults: [Result<Void, SendError>] = []
        payloadLoop: for payload in payloads {
            let result = await sendOne(target: resolved.target, payload: payload, runner: runner)
            sendResults.append(result)
            if case .failure(let error) = result {
                switch error {
                case .transferPending, .transferStatusUnknown:
                    break  // soft outcome; keep sending
                default:
                    break payloadLoop
                }
            }
        }

        /// Client-facing description of a payload, for the partial-failure breakdown.
        /// Files are named by filename only, never the full path (plan 023).
        func describePayload(_ payload: SendPayload) -> String {
            switch payload {
            case .text: return "text message"
            case .file(let path): return "file '\((path as NSString).lastPathComponent)'"
            }
        }

        var pendingMessages: [String] = []
        var hardFailure: (index: Int, error: SendError)? = nil
        for (index, result) in sendResults.enumerated() {
            if case .failure(let error) = result {
                switch error {
                case .transferPending, .transferStatusUnknown:
                    pendingMessages.append(ClientErrorMessages.sanitized(error))
                default:
                    hardFailure = (index, error)
                }
            }
        }

        if let failure = hardFailure {
            // Every result before the failing one is a payload that was
            // dispatched without hard-failing (the loop stops at the first).
            let sentCount = failure.index
            if sentCount == 0 {
                // Nothing reached Messages.app: a plain "failed", as before.
                return .error(ClientErrorMessages.sanitized(failure.error))
            }
            return .partialFailure(
                sentDescriptions: payloads.prefix(sentCount).map { describePayload($0) },
                failedDescription: describePayload(payloads[failure.index]),
                error: ClientErrorMessages.sanitized(failure.error),
                deliveredTo: resolved.deliveredTo,
                chat: resolved.chat
            )
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
            // File-only send. Verification does not apply, so status is unchanged.
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
            case .failedDelivery(let guid, let errorCode):
                return .failedDelivery(
                    guid: guid, errorCode: errorCode,
                    deliveredTo: resolved.deliveredTo, chat: resolved.chat
                )
            case .notFound:
                return .uncertain(deliveredTo: resolved.deliveredTo, chat: resolved.chat)
            }
        } catch {
            // DB unreadable or task cancelled → Option D: transport-only fallback.
            return .success(deliveredTo: resolved.deliveredTo, chat: resolved.chat)
        }
    }

    /// Dispatch one payload to a resolved target via the script runner.
    private func sendOne(
        target: SendResolution.Target,
        payload: SendPayload,
        runner: any ScriptRunning
    ) async -> Result<Void, SendError> {
        switch target {
        case .participant(let handle, _):
            switch payload {
            case .text(let body):
                return await runner.sendTextToParticipant(handle: handle, message: body)
            case .file(let path):
                return await runner.sendFileToParticipant(handle: handle, filePath: path)
            }
        case .chat(let guid, _):
            switch payload {
            case .text(let body):
                return await runner.sendTextToChat(guid: guid, message: body)
            case .file(let path):
                return await runner.sendFileToChat(guid: guid, filePath: path)
            }
        }
    }

}
