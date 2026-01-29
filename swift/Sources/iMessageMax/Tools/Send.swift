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
    let success: Bool
    let messageId: String?
    let timestamp: String?
    let deliveredTo: [String]?
    let chatId: String?
    let error: String?
    let ambiguousRecipient: AmbiguousRecipientInfo?

    struct AmbiguousRecipientInfo: Encodable {
        let message: String
        let candidates: [RecipientCandidate]
    }

    enum CodingKeys: String, CodingKey {
        case success
        case messageId = "message_id"
        case timestamp
        case deliveredTo = "delivered_to"
        case chatId = "chat_id"
        case error
        case ambiguousRecipient = "ambiguous_recipient"
    }

    static func success(deliveredTo: [String], chatId: Int?) -> SendResponse {
        SendResponse(
            success: true,
            messageId: nil,  // Cannot reliably retrieve new message ID
            timestamp: TimeUtils.formatISO(Date()),
            deliveredTo: deliveredTo,
            chatId: chatId.map { "chat\($0)" },
            error: nil,
            ambiguousRecipient: nil
        )
    }

    static func error(_ message: String) -> SendResponse {
        SendResponse(
            success: false,
            messageId: nil,
            timestamp: nil,
            deliveredTo: nil,
            chatId: nil,
            error: message,
            ambiguousRecipient: nil
        )
    }

    static func ambiguous(candidates: [RecipientCandidate]) -> SendResponse {
        SendResponse(
            success: false,
            messageId: nil,
            timestamp: nil,
            deliveredTo: nil,
            chatId: nil,
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
                    "reply_to": .string(description: "Message ID to reply to (not yet implemented)"),
                ],
                required: ["text"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)  // send modifies state
        ) { args in
            try await tool.execute(args: args)
        }
    }

    // MARK: - Execution

    func execute(args: [String: Value]?) async throws -> [Tool.Content] {
        let to = args?["to"]?.stringValue
        let chatId = args?["chat_id"]?.stringValue
        let text = args?["text"]?.stringValue
        let replyTo = args?["reply_to"]?.stringValue

        let response = await send(to: to, chatId: chatId, text: text, replyTo: replyTo)
        return [.text(try encodeJSON(response))]
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Send Implementation

    /// Send a message to a person or group chat
    private func send(
        to: String?,
        chatId: String?,
        text: String?,
        replyTo: String?
    ) async -> SendResponse {
        // Validation
        guard to != nil || chatId != nil else {
            return .error("Either 'to' or 'chat_id' must be provided")
        }

        guard let text = text, !text.isEmpty else {
            return .error("Message 'text' is required")
        }

        // reply_to is not yet implemented
        if replyTo != nil {
            return .error("reply_to is not yet implemented")
        }

        // Initialize contacts resolver
        try? await resolver.initialize()

        var recipientHandle: String?
        var targetChatId: Int?
        var deliveredTo: [String] = []

        // Resolve recipient from chat_id
        if let chatId = chatId {
            let result = await resolveChatId(chatId)
            switch result {
            case .success(let info):
                recipientHandle = info.handle
                targetChatId = info.chatId
                deliveredTo = info.deliveredTo
            case .failure(let errorMsg):
                return .error(errorMsg)
            case .ambiguous:
                // Chat ID resolution shouldn't return ambiguous
                return .error("Unexpected ambiguous result from chat_id resolution")
            }
        }
        // Resolve recipient from 'to' parameter
        else if let to = to {
            let result = await resolveRecipient(to)
            switch result {
            case .success(let info):
                recipientHandle = info.handle
                targetChatId = info.chatId
                deliveredTo = info.deliveredTo
            case .failure(let errorMsg):
                return .error(errorMsg)
            case .ambiguous(let candidates):
                return .ambiguous(candidates: candidates)
            }
        }

        guard let handle = recipientHandle else {
            return .error("Could not determine recipient")
        }

        // Send the message via AppleScript
        let sendResult = AppleScriptRunner.send(to: handle, message: text)

        switch sendResult {
        case .success:
            return .success(deliveredTo: deliveredTo, chatId: targetChatId)
        case .failure(let error):
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Private Resolution Types

    private struct RecipientInfo {
        let handle: String
        let chatId: Int?
        let deliveredTo: [String]
    }

    private enum RecipientResolutionResult {
        case success(RecipientInfo)
        case failure(String)
        case ambiguous([RecipientCandidate])
    }

    // MARK: - Chat ID Resolution

    private func resolveChatId(_ chatId: String) async -> RecipientResolutionResult {
        // Extract numeric ID from chat_id (e.g., "chat123" -> 123)
        let numericString = chatId.replacingOccurrences(of: "chat", with: "")
        guard let numericId = Int(numericString) else {
            return .failure("Invalid chat_id format: \(chatId)")
        }

        do {
            // Get chat info - column 0: guid, column 1: display_name
            let chats: [(guid: String, displayName: String?)] = try db.query(
                "SELECT guid, display_name FROM chat WHERE ROWID = ?",
                params: [numericId]
            ) { row in
                (guid: row.string(0) ?? "", displayName: row.string(1))
            }

            guard !chats.isEmpty else {
                return .failure("Chat not found: \(chatId)")
            }

            // Get participants for the chat
            let participants = try await getParticipants(chatId: numericId)

            guard !participants.isEmpty else {
                return .failure("No participants found for chat: \(chatId)")
            }

            // Use first participant's handle for sending
            let recipientHandle = participants[0].handle
            let deliveredTo = participants.map { $0.displayName }

            return .success(RecipientInfo(
                handle: recipientHandle,
                chatId: numericId,
                deliveredTo: deliveredTo
            ))
        } catch {
            return .failure("Database error: \(error.localizedDescription)")
        }
    }

    // MARK: - Recipient Resolution

    private func resolveRecipient(_ to: String) async -> RecipientResolutionResult {
        // Check if it's a phone number
        if PhoneUtils.isPhoneNumber(to) || to.hasPrefix("+") {
            return await resolvePhoneNumber(to)
        }

        // Check if it's an email
        if PhoneUtils.isEmail(to) {
            return await resolveEmail(to)
        }

        // It's a name - search contacts
        return await resolveContactName(to)
    }

    private func resolvePhoneNumber(_ phone: String) async -> RecipientResolutionResult {
        guard let normalized = PhoneUtils.normalizeToE164(phone) else {
            return .failure("Invalid phone number format: \(phone)")
        }

        do {
            // Check if handle exists in database - column 0: id
            var handles: [String] = try db.query(
                "SELECT id FROM handle WHERE id = ?",
                params: [normalized]
            ) { row in
                row.string(0) ?? ""
            }

            // Also try original format
            if handles.isEmpty {
                handles = try db.query(
                    "SELECT id FROM handle WHERE id = ?",
                    params: [phone]
                ) { row in
                    row.string(0) ?? ""
                }
            }

            guard !handles.isEmpty else {
                return .failure("No conversation found with \(phone)")
            }

            let handle = handles[0]
            let chatId = try findChatForHandle(handle)
            let name = await resolver.resolve(handle) ?? PhoneUtils.formatDisplay(handle)

            return .success(RecipientInfo(
                handle: handle,
                chatId: chatId,
                deliveredTo: [name]
            ))
        } catch {
            return .failure("Database error: \(error.localizedDescription)")
        }
    }

    private func resolveEmail(_ email: String) async -> RecipientResolutionResult {
        do {
            // Column 0: id
            let handles: [String] = try db.query(
                "SELECT id FROM handle WHERE LOWER(id) = LOWER(?)",
                params: [email]
            ) { row in
                row.string(0) ?? ""
            }

            guard !handles.isEmpty else {
                return .failure("No conversation found with \(email)")
            }

            let handle = handles[0]
            let chatId = try findChatForHandle(handle)
            let name = await resolver.resolve(handle) ?? email

            return .success(RecipientInfo(
                handle: handle,
                chatId: chatId,
                deliveredTo: [name]
            ))
        } catch {
            return .failure("Database error: \(error.localizedDescription)")
        }
    }

    private func resolveContactName(_ name: String) async -> RecipientResolutionResult {
        let (authorized, _) = ContactResolver.authorizationStatus()
        guard authorized else {
            return .failure("Cannot search by name without contacts access")
        }

        let matches = await resolver.searchByName(name)

        if matches.isEmpty {
            return .failure("No contact found matching '\(name)'")
        }

        if matches.count == 1 {
            let match = matches[0]
            do {
                let chatId = try findChatForHandle(match.handle)
                return .success(RecipientInfo(
                    handle: match.handle,
                    chatId: chatId,
                    deliveredTo: [match.name]
                ))
            } catch {
                return .failure("Database error: \(error.localizedDescription)")
            }
        }

        // Multiple matches - need disambiguation
        var candidates: [(handle: String, name: String, lastContact: Date?)] = []
        for match in matches {
            let lastTime = try? getLastContactTime(handle: match.handle)
            candidates.append((match.handle, match.name, lastTime))
        }

        // Sort by most recent contact (most recent first)
        candidates.sort { lhs, rhs in
            switch (lhs.lastContact, rhs.lastContact) {
            case (nil, nil): return false
            case (nil, _): return false
            case (_, nil): return true
            case (let l?, let r?): return l > r
            }
        }

        let formattedCandidates = candidates.map { candidate in
            RecipientCandidate(
                name: candidate.name,
                handle: candidate.handle,
                lastContact: TimeUtils.formatCompactRelative(candidate.lastContact) ?? "never"
            )
        }

        return .ambiguous(formattedCandidates)
    }

    // MARK: - Database Helpers

    private struct SendParticipantInfo {
        let handle: String
        let displayName: String
    }

    private func getParticipants(chatId: Int) async throws -> [SendParticipantInfo] {
        // Column 0: handle id
        let handles: [String] = try db.query(
            """
            SELECT h.id
            FROM handle h
            JOIN chat_handle_join chj ON h.ROWID = chj.handle_id
            WHERE chj.chat_id = ?
            """,
            params: [chatId]
        ) { row in
            row.string(0) ?? ""
        }

        var participants: [SendParticipantInfo] = []
        for handle in handles {
            let name = await resolver.resolve(handle) ?? PhoneUtils.formatDisplay(handle)
            participants.append(SendParticipantInfo(handle: handle, displayName: name))
        }

        return participants
    }

    private func findChatForHandle(_ handle: String) throws -> Int? {
        // Find 1:1 chat with this handle - column 0: ROWID
        let oneOnOneChats: [Int64] = try db.query(
            """
            SELECT c.ROWID
            FROM chat c
            JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
            JOIN handle h ON chj.handle_id = h.ROWID
            WHERE h.id = ?
            GROUP BY c.ROWID
            HAVING COUNT(DISTINCT chj.handle_id) = 1
            LIMIT 1
            """,
            params: [handle]
        ) { row in
            row.int(0)
        }

        if let first = oneOnOneChats.first {
            return Int(first)
        }

        // If no 1:1 chat, get any chat with this handle
        let anyChats: [Int64] = try db.query(
            """
            SELECT c.ROWID
            FROM chat c
            JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
            JOIN handle h ON chj.handle_id = h.ROWID
            WHERE h.id = ?
            ORDER BY c.ROWID DESC
            LIMIT 1
            """,
            params: [handle]
        ) { row in
            row.int(0)
        }

        return anyChats.first.map { Int($0) }
    }

    private func getLastContactTime(handle: String) throws -> Date? {
        // Column 0: date
        let dates: [Int64?] = try db.query(
            """
            SELECT m.date
            FROM message m
            JOIN handle h ON m.handle_id = h.ROWID
            WHERE h.id = ?
            ORDER BY m.date DESC
            LIMIT 1
            """,
            params: [handle]
        ) { row in
            row.optionalInt(0)
        }

        guard let timestamp = dates.first, let ts = timestamp else { return nil }
        return AppleTime.toDate(ts)
    }
}
