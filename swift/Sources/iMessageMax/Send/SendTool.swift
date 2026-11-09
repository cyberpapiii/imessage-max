import Foundation
import IMessageMaxContract
import MCP

struct SendTool: Sendable {
    private let db: Database
    private let resolver: ContactResolver
    private let runner: any ScriptRunning
    private let verifier: SendVerifier
    private let sendResolver: SendResolver
    private let accountStatus: IMessageAccountProbe

    init(
        db: Database = Database(),
        resolver: ContactResolver,
        runner: any ScriptRunning,
        verifier: SendVerifier? = nil,
        accountStatus: @escaping IMessageAccountProbe = { nil }
    ) {
        self.db = db
        self.resolver = resolver
        self.runner = runner
        self.verifier = verifier ?? SendVerifier(db: db)
        self.sendResolver = SendResolver(db: db, resolver: resolver)
        self.accountStatus = accountStatus
    }

    static func definition(db: Database, resolver: ContactResolver, access: MessagesAccess) -> ToolDefinition {
        let tool = SendTool(
            db: db, resolver: resolver, runner: LiveScriptRunner(access: access),
            accountStatus: { await MessagesAccess.offPool { access.account.status() } })

        return ToolDefinition(
            name: "send",
            description: """
                Send a message or file to a person or an existing chat.

                Prefer 'chat_id' when the exact thread matters.
                Use 'to' when it is fine to start from a person.
                chat_id is the exact target for tool calls. When you talk to the user, name the destination by the returned chat.name or the recipient names.

                The status field of a text send takes one of these values:
                  confirmed: an outbound row with error=0 appeared in chat.db within the verification window (about 1 s). This is not a delivery receipt.
                  uncertain: no row appeared within the polling window, either after Messages accepted the send or after Messages failed or timed out once the send had begun (then disposition is may_have_completed and error says what Messages reported). The message may have been sent. Follow up with get_messages before any resend.
                  mismatch: the row appeared in a different chat than the intended one. Alert the user, and do not treat it as success.
                  failed_delivery: the row appeared with a recorded delivery error. The message was NOT delivered.
                  partial_failure: some payloads were dispatched before a later one failed. The message field names them. Never retry the whole call blindly.
                  sent: verification was unavailable because the database could not be read. The only evidence is that the transport accepted the send.
                Every response also includes disposition (completed, not_started, or may_have_completed) and retry_safe.
                retry_safe=true means a retry cannot duplicate the message, because nothing reached Messages or chat.db shows that the row failed.
                retry_safe=false means you must not resend blindly. Check with get_messages first.
                A send runs immediately when the destination is exact. An ambiguous destination returns status 'ambiguous' and sends nothing. A contact name whose number or email has no conversation in Messages is ambiguous too. Invalid input returns status 'failed' and sends nothing. A file transfer may return 'pending_confirmation' while Messages.app finishes the transfer. When text was sent with that file, text_status reports the text's own result (confirmed or uncertain).
                With 'to', the tool sends through the person's existing 1:1 chat (iMessage, SMS or RCS, the one with the newest message) and reports that chat. Only a person with no 1:1 chat yet is sent to over iMessage, or over SMS when Messages has no iMessage account turned on but SMS is. With no account that can send, the send fails with disposition not_started; diagnose's imessage_account has the fix.
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
        let response = await explainingAccount(send(
            to: args?["to"]?.stringValue,
            chatId: args?["chat_id"]?.stringValue,
            text: args?["text"]?.stringValue,
            filePaths: args?["file_paths"]?.arrayValue?.compactMap { $0.stringValue }
        ))
        if response.status.isError {
            throw ToolFailure(code: response.status.rawValue, body: response)
        }
        return [.plainText(try FormatUtils.encodeJSON(response))]
    }

    /// A send that Messages took but chat.db does not confirm, or shows as
    /// failed, most often means iMessage is signed out, which nobody sees
    /// while Messages runs hidden. Such a result names the account state
    /// when it is anything but signed in. Only these results ask, so a
    /// confirmed send never waits on the check.
    func explainingAccount(_ response: SendResponse) async -> SendResponse {
        guard [.uncertain, .failedDelivery].contains(response.status),
              let status = await accountStatus(),
              [.signedOut, .disabled, .noAccount, .connecting].contains(status)
        else { return response }
        return response.adding(
            note: "Messages reports its iMessage account as \(status.rawValue), which may be why. "
                + (DiagnoseTool.accountCapability(status).fix ?? "Run diagnose again in a minute."))
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
        case .ambiguous(let candidates, let reason):
            return .ambiguous(candidates: candidates, reason: reason)
        }
        if let invalid = resolved.target.validationError {
            return .error(ClientErrorMessages.sanitized(invalid))
        }


        let verifiedIndex: Int? = {
            guard case .text? = payloads.last else { return nil }
            return payloads.count - 1
        }()
        var verificationBaseline: Int64? = nil
        /// The error of a final text that failed after the send began. Such a
        /// text may be in chat.db, so it is verified like any other.
        var textTransportError: String? = nil

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
            if index == verifiedIndex, failure.disposition == .mayHaveCompleted, verificationBaseline != nil {
                textTransportError = errorText
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

        let pendingNote = pendingMessages.isEmpty ? nil : pendingMessages.joined(separator: " ")

        guard let verifiedIndex, case .text(let expectedText) = payloads[verifiedIndex],
              let verificationBaseline else {
            if let pendingNote {
                return .pending(pendingNote, deliveredTo: resolved.deliveredTo, chat: resolved.chat)
            }
            return .sent(deliveredTo: resolved.deliveredTo, chat: resolved.chat)
        }

        // A pending file does not skip this: the text's result is reported
        // beside the file's, so the caller knows whether to resend the text.
        let verification: VerificationResult
        do {
            verification = try await verifier.verify(
                intendedChatId: resolved.target.chatId,
                handle: resolved.recipientHandle,
                afterRowId: verificationBaseline,
                expectedText: expectedText
            )
        } catch {
            if let textTransportError {
                if verifiedIndex == 0 {
                    return .error(textTransportError, disposition: .mayHaveCompleted)
                }
                return .partialFailure(
                    sentDescriptions: payloads.prefix(verifiedIndex).map(\.clientDescription),
                    failedDescription: payloads[verifiedIndex].clientDescription,
                    error: textTransportError,
                    deliveredTo: resolved.deliveredTo,
                    chat: resolved.chat,
                    disposition: .mayHaveCompleted
                )
            }
            if let pendingNote {
                return .pending(pendingNote, deliveredTo: resolved.deliveredTo, chat: resolved.chat)
            }
            return .sent(deliveredTo: resolved.deliveredTo, chat: resolved.chat)
        }

        switch verification {
        case .confirmed(let guid, _):
            if let pendingNote {
                return .pending(
                    pendingNote, deliveredTo: resolved.deliveredTo, chat: resolved.chat,
                    text: .confirmed(guid: guid)
                )
            }
            return .confirmed(
                guid: guid, deliveredTo: resolved.deliveredTo, chat: resolved.chat,
                transportError: textTransportError
            )
        case .notFound:
            if let pendingNote {
                return .pending(
                    pendingNote, deliveredTo: resolved.deliveredTo, chat: resolved.chat,
                    text: .notFound, textTransportError: textTransportError
                )
            }
            return .uncertain(
                deliveredTo: resolved.deliveredTo, chat: resolved.chat,
                transportError: textTransportError
            )
        case .mismatch(let actualChatId, _):
            return .mismatch(
                intendedChat: resolved.chat,
                actualChatId: actualChatId,
                deliveredTo: resolved.deliveredTo,
                note: pendingNote
            )
        case .failedDelivery(let guid, let errorCode):
            return .failedDelivery(
                guid: guid, errorCode: errorCode,
                deliveredTo: resolved.deliveredTo, chat: resolved.chat,
                otherPayloadsDispatched: payloads.count > 1,
                note: pendingNote
            )
        }
    }
}
