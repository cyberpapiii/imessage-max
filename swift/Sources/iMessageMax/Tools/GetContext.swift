// Sources/iMessageMax/Tools/GetContext.swift
import Foundation
import MCP

struct GetContextResponse: Codable {
    let chat: ChatInfo
    let people: [String: PersonInfo]
    let message: ContextMessage
    let before: [ContextMessage]
    let after: [ContextMessage]

    struct ContextMessage: Codable {
        let id: String
        let from: String
        let text: String?
        let ago: String?
        let ts: String?
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
        let name: String
    }
}

struct GetContextError: LocalizedError, Codable {
    let error: String
    let message: String

    var errorDescription: String? {
        message
    }
}

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
            description: "Get messages surrounding a specific message. Returns the containing chat id for follow-up tool calls and chat name for user-facing summaries. When explaining results to the user, refer to chats by name, not by id.",
            inputSchema: inputSchema,
            outputSchema: OutputSchema.object,
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

            switch result {
            case .success(let response):
                return [.plainText(try FormatUtils.encodeJSON(response))]
            case .failure(let error):
                throw ToolError(content: [.plainText(try FormatUtils.encodeJSON(error))])
            }
        }
    }

    static func execute(
        messageId: String? = nil,
        chatId: String? = nil,
        contains: String? = nil,
        before: Int = 5,
        after: Int = 10,
        database: Database = Database(),
        resolver: ContactResolver = ContactResolver()
    ) async -> Result<GetContextResponse, GetContextError> {
        let beforeCount = max(0, min(before, 50))
        let afterCount = max(0, min(after, 50))

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

        try? await resolver.initialize()

        do {
            let targetResult: (msgId: Int64, text: String?, attributedBody: Data?, date: Int64, isFromMe: Bool, senderHandle: String?, chatId: Int64, chatName: String?)

            if let msgIdStr = messageId {
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
                guard let cId = chatId, let searchText = contains else {
                    return .failure(GetContextError(
                        error: "invalid_params",
                        message: "chat_id and contains are required"
                    ))
                }

                guard let numericChatId = ChatIdentifier.parseRowId(cId) else {
                    return .failure(GetContextError(
                        error: "invalid_id",
                        message: "Invalid chat ID format: \(cId)"
                    ))
                }

                // attributedBody is a binary blob — cannot search in SQL; filter in Swift
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
                    from: await getPersonKey(isFromMe: isFromMe, handle: senderHandle),
                    text: messageText,
                    ago: TimeUtils.formatCompactRelative(msgDate),
                    ts: TimeUtils.formatISO(msgDate)
                )
            }

            let targetMessage = await formatMessage(
                msgId: targetResult.msgId,
                text: targetResult.text,
                attributedBody: targetResult.attributedBody,
                date: targetResult.date,
                isFromMe: targetResult.isFromMe,
                senderHandle: targetResult.senderHandle
            )

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

            let chatName = try await displayNameForChat(
                chatId: targetChatId,
                explicitName: targetResult.chatName,
                database: database,
                resolver: resolver
            )

            let response = GetContextResponse(
                chat: GetContextResponse.ChatInfo(
                    id: "chat\(targetChatId)",
                    name: chatName
                ),
                people: people,
                message: targetMessage,
                before: beforeMessages,
                after: afterMessages
            )

            return .success(response)

        } catch let error as DatabaseError {
            let mapped = ToolErrorMapping.map(error, context: "get_context")
            return .failure(GetContextError(error: mapped.code, message: mapped.message))
        } catch {
            return .failure(GetContextError(
                error: "internal_error",
                message: ClientErrorMessages.sanitized(error)
            ))
        }
    }

    // MARK: - Private Helpers

    private static func parseMessageId(_ idStr: String) -> Int64? {
        var numStr = idStr
        if numStr.hasPrefix("msg_") {
            numStr = String(numStr.dropFirst(4))
        } else if numStr.hasPrefix("msg") {
            numStr = String(numStr.dropFirst(3))
        }
        return Int64(numStr)
    }

    private static func displayNameForChat(
        chatId: Int64,
        explicitName: String?,
        database: Database,
        resolver: ContactResolver
    ) async throws -> String {
        let trimmed = explicitName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }

        let rows = try await ChatSummaryQueries.participants(
            db: database,
            chatId: chatId,
            resolver: resolver
        ).sorted { $0.handle < $1.handle }

        let names = rows.map {
            IdentityDisplayFormatter.displayName(handle: $0.handle, contactName: $0.name)
        }
        return DisplayNameGenerator.fromNames(names)
    }

}
