import Foundation
import MCP

struct SendTool: Sendable {
    private let db: Database
    private let resolver: ContactResolver
    private let runner: any ScriptRunning
    private let verifier: SendVerifier
    private let sendResolver: SendResolver

    init(
        db: Database = Database(),
        resolver: ContactResolver,
        runner: any ScriptRunning,
        verifier: SendVerifier? = nil
    ) {
        self.db = db
        self.resolver = resolver
        self.runner = runner
        self.verifier = verifier ?? SendVerifier(db: db)
        self.sendResolver = SendResolver(db: db, resolver: resolver)
    }

    static func definition(db: Database, resolver: ContactResolver, access: MessagesAccess) -> ToolDefinition {
        let tool = SendTool(db: db, resolver: resolver, runner: LiveScriptRunner(access: access))

        return ToolDefinition(
            name: "send",
            description: """
                Send a message or file to a person or an existing chat.

                Prefer 'chat_id' when the exact thread matters.
                Use 'to' when it is fine to start from a person.
                chat_id is the exact target for tool calls. When you talk to the user, name the destination by the returned chat.name or the recipient names.

                The status field of a text send takes one of these values:
                  confirmed: an outbound row with error=0 appeared in chat.db within the verification window (about 1 s). This is not a delivery receipt.
                  uncertain: the transport accepted the send, but no row appeared within the polling window. Follow up with get_messages.
                  mismatch: the row appeared in a different chat than the intended one. Alert the user, and do not treat it as success.
                  failed_delivery: the row appeared with a recorded delivery error. The message was NOT delivered.
                  partial_failure: some payloads were dispatched before a later one failed. The message field names them. Never retry the whole call blindly.
                  sent: verification was unavailable because the database could not be read. The only evidence is that the transport accepted the send.
                Every response also includes disposition (completed, not_started, or may_have_completed) and retry_safe.
                retry_safe=true means a retry cannot duplicate the message, because nothing reached Messages or chat.db shows that the row failed.
                retry_safe=false means you must not resend blindly. Check with get_messages first.
                A send runs immediately when the destination is exact. An ambiguous destination returns status 'ambiguous' and sends nothing. Invalid input returns status 'failed' and sends nothing. A file transfer may return 'pending_confirmation' while Messages.app finishes the transfer.
                """,
            inputSchema: InputSchema.object(
                properties: [
                    "to": .string(description: "Contact name, phone number, or email"),
                    "chat_id": .string(description: "Existing chat ID. Use it for groups or to resolve an ambiguous recipient."),
                    "text": .string(description: "Message content to send"),
                    "file_paths": .array(
                        description: "Local file paths to send as attachments. With text, the tool sends the files first and the text last.",
                        items: .string(description: "Absolute local file path, or a path that starts with ~/")
                    ),
                    "confirm": .boolean(description: "Deprecated. The tool accepts it for compatibility and ignores it. Sends need no confirmation. The tool refuses an ambiguous destination with status 'ambiguous' and verifies results after sending."),
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
            return .error("Provide either 'to' or 'chat_id'")
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


        let verifiedIndex: Int? = {
            guard case .text? = payloads.last else { return nil }
            return payloads.count - 1
        }()
        var verificationBaseline: Int64? = nil

        var pendingMessages: [String] = []
        for (index, payload) in payloads.enumerated() {
            if Task.isCancelled {
                let cancelled = "The send was cancelled before \(payload.clientDescription) was dispatched."
                if index == 0 {
                    return .error(cancelled)
                }
                return .partialFailure(
                    sentDescriptions: payloads.prefix(index).map(\.clientDescription),
                    failedDescription: payload.clientDescription,
                    error: cancelled,
                    deliveredTo: resolved.deliveredTo,
                    chat: resolved.chat,
                    disposition: .notStarted
                )
            }
            if index == verifiedIndex {
                verificationBaseline = try? verifier.baseline()
            }
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

        guard let verifiedIndex, case .text(let expectedText) = payloads[verifiedIndex],
              let verificationBaseline else {
            return .sent(deliveredTo: resolved.deliveredTo, chat: resolved.chat)
        }

        do {
            let verification = try await verifier.verify(
                intendedChatId: resolved.target.chatId,
                handle: resolved.target.participantHandle,
                afterRowId: verificationBaseline,
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
            return .sent(deliveredTo: resolved.deliveredTo, chat: resolved.chat)
        }
    }
}
