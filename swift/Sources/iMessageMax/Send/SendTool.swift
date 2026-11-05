import Foundation
import MCP

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

    static func definition(db: Database, resolver: ContactResolver) -> ToolDefinition {
        let tool = SendTool(db: db, resolver: resolver)

        return ToolDefinition(
            name: "send",
            description: """
                Send a message or file to a person or an existing chat.

                Prefer 'chat_id' when the exact thread matters.
                Use 'to' when starting from a person is acceptable.
                chat_id is an exact tool-call target; when talking to the user, refer to the destination by the returned chat.name or recipient names.

                Proof vocabulary for text sends (status field):
                  confirmed: outbound row found in chat.db within the verification window (about 1 s) with error=0. Not a delivery receipt.
                  uncertain: transport accepted but no row appeared within the polling window. Follow up with get_messages.
                  mismatch: row found in a different chat than intended. Alert the user, do not treat as success.
                  failed_delivery: row found with a delivery error recorded. The message was NOT delivered.
                  partial_failure: some payloads were dispatched before a later one failed. The message lists which. Never blind-retry the whole call.
                  sent: verification unavailable (DB unreadable). Transport accepted only.
                Every response also carries disposition (completed | not_started | may_have_completed) and retry_safe.
                retry_safe=true means a retry cannot duplicate the message (nothing reached Messages, or chat.db shows the row failed).
                retry_safe=false means do not resend blindly; check with get_messages first.
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

    func execute(args: [String: Value]?) async throws -> [Tool.Content] {
        let response = await send(
            to: args?["to"]?.stringValue,
            chatId: args?["chat_id"]?.stringValue,
            text: args?["text"]?.stringValue,
            filePaths: args?["file_paths"]?.arrayValue?.compactMap { $0.stringValue }
        )
        if response.status.isError {
            throw ToolFailure(code: response.status.rawValue, body: response)
        }
        return [.plainText(try FormatUtils.encodeJSON(response))]
    }

    private func send(
        to: String?,
        chatId: String?,
        text: String?,
        filePaths: [String]?
    ) async -> SendResponse {
        let destination: SendDestination
        if let chatId {
            destination = .chatId(chatId)
        } else if let to {
            destination = .recipient(to)
        } else {
            return .error("Either 'to' or 'chat_id' must be provided")
        }

        let payloads: [SendPayload]
        switch SendPayload.build(text: text, filePaths: filePaths) {
        case .success(let built):
            payloads = built
        case .failure(let message):
            return .error(message)
        }


        let resolved: ResolvedSendTarget
        switch await sendResolver.resolve(destination) {
        case .success(let target):
            resolved = target
        case .failure(let errorMsg):
            return .error(errorMsg)
        case .ambiguous(let candidates):
            return .ambiguous(candidates: candidates)
        }
        if let invalid = resolved.target.validationError {
            return .error(ClientErrorMessages.sanitized(invalid))
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
        var pendingMessages: [String] = []
        for (index, payload) in payloads.enumerated() {
            guard case .failure(let failure) = await runner.send(payload, to: resolved.target) else {
                continue
            }
            let errorText = ClientErrorMessages.sanitized(failure.error)
            if failure.error.isSoftTransferOutcome {
                pendingMessages.append(errorText)
                continue
            }
            if index == 0 {
                return .error(errorText, disposition: failure.disposition)
            }
            return .partialFailure(
                sentDescriptions: payloads.prefix(index).map(\.clientDescription),
                failedDescription: payload.clientDescription,
                error: errorText,
                deliveredTo: resolved.deliveredTo,
                chat: resolved.chat,
                disposition: failure.disposition
            )
        }

        if !pendingMessages.isEmpty {
            return .pending(
                pendingMessages.joined(separator: " "),
                deliveredTo: resolved.deliveredTo,
                chat: resolved.chat
            )
        }

        // Only text is verified against chat.db. A file-only send keeps the
        // transfer-observation status.
        guard case .text(let expectedText)? = payloads.last(where: { if case .text = $0 { return true }; return false }) else {
            return .sent(deliveredTo: resolved.deliveredTo, chat: resolved.chat)
        }

        do {
            let verification = try await verifier.verify(
                intendedChatId: resolved.target.chatId,
                handle: resolved.target.participantHandle,
                sendTime: sendTime,
                expectedText: expectedText
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
            return .sent(deliveredTo: resolved.deliveredTo, chat: resolved.chat)
        }
    }
}
