// Sources/iMessageMax/Tools/GetContext.swift
import Foundation
import MCP

/// Response for the get_context tool
struct GetContextResponse: Codable {
    let target: ContextMessage
    let before: [ContextMessage]
    let after: [ContextMessage]
    let people: [String: PersonInfo]
    let chat: ChatInfo

    struct ContextMessage: Codable {
        let id: String
        let ts: String?
        let ago: String?
        let from: String
        let text: String?
    }

    struct PersonInfo: Codable {
        let name: String
        let handle: String?
        let isMe: Bool?

        enum CodingKeys: String, CodingKey {
            case name, handle
            case isMe = "is_me"
        }
    }

    struct ChatInfo: Codable {
        let id: String
        let name: String?
    }
}

/// Error response for get_context tool
struct GetContextError: LocalizedError, Codable {
    let error: String
    let message: String

    var errorDescription: String? {
        message
    }
}

/// GetContext tool implementation
enum GetContext {
    // MARK: - Tool Registration

    static func register(on server: Server, db: Database, resolver: ContactResolver) {
        let inputSchema: Value = .object([
            "type": "object",
            "properties": .object([
                "message_id": .object([
                    "type": "string",
                    "description": "Specific message ID to get context around (e.g., \"msg_1\")",
                ]),
                "chat_id": .object([
                    "type": "string",
                    "description": "Chat ID (required if using contains)",
                ]),
                "contains": .object([
                    "type": "string",
                    "description": "Find message containing this text, then get context",
                ]),
                "before": .object([
                    "type": "integer",
                    "description": "Number of messages before the target (default 5, max 50)",
                ]),
                "after": .object([
                    "type": "integer",
                    "description": "Number of messages after the target (default 10, max 50)",
                ]),
            ]),
            "additionalProperties": false,
        ])

        server.registerTool(
            name: "get_context",
            description: "Get messages surrounding a specific message. Use to see the conversation context around a particular message.",
            inputSchema: inputSchema,
            annotations: Tool.Annotations(
                title: "Get Context",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let messageId = arguments?["message_id"]?.stringValue
            let chatId = arguments?["chat_id"]?.stringValue
            let contains = arguments?["contains"]?.stringValue
            let before = arguments?["before"]?.intValue ?? 5
            let after = arguments?["after"]?.intValue ?? 10

            let result = await execute(
                messageId: messageId,
                chatId: chatId,
                contains: contains,
                before: before,
                after: after,
                database: db,
                resolver: resolver
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            switch result {
            case .success(let response):
                let json = try encoder.encode(response)
                return [.text(String(data: json, encoding: .utf8) ?? "{}")]
            case .failure(let error):
                let json = try encoder.encode(error)
                return [.text(String(data: json, encoding: .utf8) ?? "{}")]
            }
        }
    }

    /// Get messages surrounding a specific message
    /// - Parameters:
    ///   - messageId: Specific message ID to get context around (e.g., "msg_1" or "1")
    ///   - chatId: Chat ID (required if using contains)
    ///   - contains: Find message containing this text, then get context
    ///   - before: Number of messages before the target (default 5, max 50)
    ///   - after: Number of messages after the target (default 10, max 50)
    ///   - database: Database instance (optional, for testing)
    ///   - resolver: ContactResolver instance (optional, for testing)
    static func execute(
        messageId: String? = nil,
        chatId: String? = nil,
        contains: String? = nil,
        before: Int = 5,
        after: Int = 10,
        database: Database = Database(),
        resolver: ContactResolver = ContactResolver()
    ) async -> Result<GetContextResponse, GetContextError> {
        // Clamp before/after to reasonable bounds
        let beforeCount = max(0, min(before, 50))
        let afterCount = max(0, min(after, 50))

        // Validate inputs
        if messageId == nil && (chatId == nil || contains == nil) {
            return .failure(GetContextError(
                error: "invalid_params",
                message: "Either message_id OR (chat_id + contains) is required"
            ))
        }

        if contains != nil && chatId == nil {
            return .failure(GetContextError(
                error: "invalid_params",
                message: "chat_id is required when using contains"
            ))
        }

        // Initialize contact resolver
        try? await resolver.initialize()

        do {
            // Find target message
            let targetResult: (msgId: Int64, text: String?, attributedBody: Data?, date: Int64, isFromMe: Bool, senderHandle: String?, chatId: Int64, chatName: String?)

            if let msgIdStr = messageId {
                // Find by message ID
                guard let numericId = parseMessageId(msgIdStr) else {
                    return .failure(GetContextError(
                        error: "invalid_id",
                        message: "Invalid message ID format: \(msgIdStr)"
                    ))
                }

                let sql = """
                    SELECT
                        m.ROWID as msg_id,
                        m.text,
                        m.attributedBody,
                        m.date,
                        m.is_from_me,
                        h.id as sender_handle,
                        c.ROWID as chat_id,
                        c.display_name as chat_name
                    FROM message m
                    JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
                    JOIN chat c ON cmj.chat_id = c.ROWID
                    LEFT JOIN handle h ON m.handle_id = h.ROWID
                    WHERE m.ROWID = ?
                    """

                let rows = try database.query(sql, params: [numericId]) { row in
                    (
                        msgId: row.int(0),
                        text: row.string(1),
                        attributedBody: row.blob(2),
                        date: row.int(3),
                        isFromMe: row.int(4) != 0,
                        senderHandle: row.string(5),
                        chatId: row.int(6),
                        chatName: row.string(7)
                    )
                }

                guard let found = rows.first else {
                    return .failure(GetContextError(
                        error: "not_found",
                        message: "Target message not found"
                    ))
                }
                targetResult = found

            } else {
                // Find by contains in chat
                guard let cId = chatId, let searchText = contains else {
                    return .failure(GetContextError(
                        error: "invalid_params",
                        message: "chat_id and contains are required"
                    ))
                }

                guard let numericChatId = parseChatId(cId) else {
                    return .failure(GetContextError(
                        error: "invalid_id",
                        message: "Invalid chat ID format: \(cId)"
                    ))
                }

                // Fetch recent messages and search in Swift (to handle attributedBody)
                // Note: We can't search attributedBody in SQL since it's a binary blob
                let sql = """
                    SELECT
                        m.ROWID as msg_id,
                        m.text,
                        m.attributedBody,
                        m.date,
                        m.is_from_me,
                        h.id as sender_handle,
                        c.ROWID as chat_id,
                        c.display_name as chat_name
                    FROM message m
                    JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
                    JOIN chat c ON cmj.chat_id = c.ROWID
                    LEFT JOIN handle h ON m.handle_id = h.ROWID
                    WHERE c.ROWID = ?
                    AND (m.text IS NOT NULL OR m.attributedBody IS NOT NULL)
                    AND m.associated_message_type = 0
                    ORDER BY m.date DESC
                    LIMIT 500
                    """

                let rows = try database.query(sql, params: [numericChatId]) { row in
                    (
                        msgId: row.int(0),
                        text: row.string(1),
                        attributedBody: row.blob(2),
                        date: row.int(3),
                        isFromMe: row.int(4) != 0,
                        senderHandle: row.string(5),
                        chatId: row.int(6),
                        chatName: row.string(7)
                    )
                }

                // Search in Swift after extracting text from both columns
                let searchLower = searchText.lowercased()
                guard let found = rows.first(where: { row in
                    let extractedText = MessageTextExtractor.extract(text: row.text, attributedBody: row.attributedBody)
                    return extractedText?.lowercased().contains(searchLower) ?? false
                }) else {
                    return .failure(GetContextError(
                        error: "not_found",
                        message: "No message found containing '\(searchText)'"
                    ))
                }
                targetResult = found
            }

            let targetDate = targetResult.date
            let targetChatId = targetResult.chatId

            // Get messages before the target
            let beforeSql = """
                SELECT
                    m.ROWID as msg_id,
                    m.text,
                    m.attributedBody,
                    m.date,
                    m.is_from_me,
                    h.id as sender_handle
                FROM message m
                JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
                LEFT JOIN handle h ON m.handle_id = h.ROWID
                WHERE cmj.chat_id = ?
                AND m.date < ?
                AND m.associated_message_type = 0
                ORDER BY m.date DESC
                LIMIT ?
                """

            let beforeRows = try database.query(beforeSql, params: [targetChatId, targetDate, beforeCount]) { row in
                (
                    msgId: row.int(0),
                    text: row.string(1),
                    attributedBody: row.blob(2),
                    date: row.int(3),
                    isFromMe: row.int(4) != 0,
                    senderHandle: row.string(5)
                )
            }.reversed()

            // Get messages after the target
            let afterSql = """
                SELECT
                    m.ROWID as msg_id,
                    m.text,
                    m.attributedBody,
                    m.date,
                    m.is_from_me,
                    h.id as sender_handle
                FROM message m
                JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
                LEFT JOIN handle h ON m.handle_id = h.ROWID
                WHERE cmj.chat_id = ?
                AND m.date > ?
                AND m.associated_message_type = 0
                ORDER BY m.date ASC
                LIMIT ?
                """

            let afterRows = try database.query(afterSql, params: [targetChatId, targetDate, afterCount]) { row in
                (
                    msgId: row.int(0),
                    text: row.string(1),
                    attributedBody: row.blob(2),
                    date: row.int(3),
                    isFromMe: row.int(4) != 0,
                    senderHandle: row.string(5)
                )
            }

            // Build people map
            var people: [String: GetContextResponse.PersonInfo] = [:]
            var handleToKey: [String: String] = [:]
            var personCounter = 1

            func generateUniqueKey(baseName: String, existing: [String: GetContextResponse.PersonInfo]) -> String {
                if existing[baseName] == nil { return baseName }
                var suffix = 2
                while existing["\(baseName)\(suffix)"] != nil {
                    suffix += 1
                }
                return "\(baseName)\(suffix)"
            }

            func getPersonKey(isFromMe: Bool, handle: String?) async -> String {
                if isFromMe {
                    if people["me"] == nil {
                        people["me"] = GetContextResponse.PersonInfo(name: "Me", handle: nil, isMe: true)
                    }
                    return "me"
                } else {
                    let h = handle ?? "unknown"
                    if let existingKey = handleToKey[h] {
                        return existingKey
                    }

                    // Try to resolve contact name
                    let name = await resolver.resolve(h)

                    let key: String
                    if let resolvedName = name {
                        let firstName = resolvedName.split(separator: " ").first.map(String.init) ?? resolvedName
                        key = generateUniqueKey(baseName: firstName.lowercased(), existing: people)
                    } else {
                        key = "p\(personCounter)"
                        personCounter += 1
                    }
                    handleToKey[h] = key

                    people[key] = GetContextResponse.PersonInfo(
                        name: name ?? h,
                        handle: h,
                        isMe: nil
                    )
                    return key
                }
            }

            func formatMessage(
                msgId: Int64,
                text: String?,
                attributedBody: Data?,
                date: Int64,
                isFromMe: Bool,
                senderHandle: String?
            ) async -> GetContextResponse.ContextMessage {
                let messageText = MessageTextExtractor.extract(text: text, attributedBody: attributedBody)
                let msgDate = AppleTime.toDate(date)

                return GetContextResponse.ContextMessage(
                    id: "msg_\(msgId)",
                    ts: TimeUtils.formatISO(msgDate),
                    ago: TimeUtils.formatCompactRelative(msgDate),
                    from: await getPersonKey(isFromMe: isFromMe, handle: senderHandle),
                    text: messageText
                )
            }

            // Format target message
            let targetMessage = await formatMessage(
                msgId: targetResult.msgId,
                text: targetResult.text,
                attributedBody: targetResult.attributedBody,
                date: targetResult.date,
                isFromMe: targetResult.isFromMe,
                senderHandle: targetResult.senderHandle
            )

            // Format before messages
            var beforeMessages: [GetContextResponse.ContextMessage] = []
            for row in beforeRows {
                let msg = await formatMessage(
                    msgId: row.msgId,
                    text: row.text,
                    attributedBody: row.attributedBody,
                    date: row.date,
                    isFromMe: row.isFromMe,
                    senderHandle: row.senderHandle
                )
                beforeMessages.append(msg)
            }

            // Format after messages
            var afterMessages: [GetContextResponse.ContextMessage] = []
            for row in afterRows {
                let msg = await formatMessage(
                    msgId: row.msgId,
                    text: row.text,
                    attributedBody: row.attributedBody,
                    date: row.date,
                    isFromMe: row.isFromMe,
                    senderHandle: row.senderHandle
                )
                afterMessages.append(msg)
            }

            let response = GetContextResponse(
                target: targetMessage,
                before: beforeMessages,
                after: afterMessages,
                people: people,
                chat: GetContextResponse.ChatInfo(
                    id: "chat\(targetChatId)",
                    name: targetResult.chatName
                )
            )

            return .success(response)

        } catch let error as DatabaseError {
            switch error {
            case .notFound(let path):
                return .failure(GetContextError(
                    error: "database_not_found",
                    message: "Database not found at \(path)"
                ))
            case .permissionDenied(let path):
                return .failure(GetContextError(
                    error: "permission_denied",
                    message: "Permission denied accessing \(path)"
                ))
            default:
                return .failure(GetContextError(
                    error: "internal_error",
                    message: error.localizedDescription
                ))
            }
        } catch {
            return .failure(GetContextError(
                error: "internal_error",
                message: error.localizedDescription
            ))
        }
    }

    // MARK: - Private Helpers

    /// Parse message ID from "msg_XXX", "msgXXX", or "XXX" format
    private static func parseMessageId(_ idStr: String) -> Int64? {
        var numStr = idStr
        if numStr.hasPrefix("msg_") {
            numStr = String(numStr.dropFirst(4))  // Handle "msg_" with underscore
        } else if numStr.hasPrefix("msg") {
            numStr = String(numStr.dropFirst(3))  // Handle "msg" without underscore
        }
        return Int64(numStr)
    }

    /// Parse chat ID from "chatXXX" or "XXX" format
    private static func parseChatId(_ idStr: String) -> Int64? {
        var numStr = idStr
        if numStr.hasPrefix("chat") {
            numStr = String(numStr.dropFirst(4))
        }
        return Int64(numStr)
    }

}
