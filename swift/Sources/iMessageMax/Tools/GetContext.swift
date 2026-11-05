// Sources/iMessageMax/Tools/GetContext.swift
import Foundation
import MCP

struct GetContextResponse: Codable {
    let chat: ChatReference
    let people: [String: PersonInfo]
    let message: ContextMessage
    let before: [ContextMessage]
    let after: [ContextMessage]

    struct PersonInfo: Codable {
        let name: String
        let handle: String?
        let isMe: Bool?

        enum CodingKeys: String, CodingKey {
            case name, handle
            case isMe = "is_me"
        }
    }
}

enum GetContext {
    /// Stands in for a received message's NULL sender handle in `people`.
    private static let noHandle = "unknown"

    // MARK: - Tool Registration

    static func definition(db: Database, resolver: ContactResolver) -> ToolDefinition {
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
                    "description": "Find the newest message containing this text (case-insensitive), then get context. Scans up to 5000 candidate messages newest-first; returns not_found_in_window if the cap is reached.",
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

        return ToolDefinition(
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

            let result = try await execute(
                messageId: messageId,
                chatId: chatId,
                contains: contains,
                before: before,
                after: after,
                database: db,
                resolver: resolver
            )

            return [.plainText(try FormatUtils.encodeJSON(result))]
        }
    }

    static func execute(
        messageId: String? = nil,
        chatId: String? = nil,
        contains: String? = nil,
        before: Int = 5,
        after: Int = 10,
        database: Database,
        resolver: ContactResolver
    ) async throws -> GetContextResponse {
        let beforeCount = max(0, min(before, 50))
        let afterCount = max(0, min(after, 50))

        if messageId == nil && (chatId == nil || contains == nil) {
            throw ToolFailure("invalid_params", "Either message_id OR (chat_id + contains) is required")
        }

        if contains != nil && chatId == nil {
            throw ToolFailure("invalid_params", "chat_id is required when using contains")
        }

        // Reject malformed ids before touching chat.db, so a bad id reads as
        // invalid_id even when the database cannot be opened.
        if let msgIdStr = messageId {
            if MessageIdentifier.parse(msgIdStr) == nil {
                throw ToolFailure("invalid_id", "Invalid message ID format: \(msgIdStr)")
            }
        } else if let cId = chatId, ChatIdentifier.parseRowId(cId) == nil {
            throw ToolFailure("invalid_id", "Invalid chat ID format: \(cId)")
        }

        let schema = try database.schema()
        let targetQuery = """
            SELECT \(MessageRecord.selectList(schema)), c.ROWID AS chat_id, c.display_name AS chat_name
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            JOIN chat c ON cmj.chat_id = c.ROWID
            \(MessageRecord.handleJoinsSQL)
            """
        func target(_ row: SQLiteRow) -> (message: MessageRecord, chatId: Int64, chatName: String?) {
            (MessageRecord(row), row.int(MessageRecord.columnCount), row.string(MessageRecord.columnCount + 1))
        }
        let targetResult: (message: MessageRecord, chatId: Int64, chatName: String?)

        if let msgIdStr = messageId {
            guard let numericId = MessageIdentifier.parse(msgIdStr) else {
                throw ToolFailure("invalid_id", "Invalid message ID format: \(msgIdStr)")
            }
            guard let found = try database.query("\(targetQuery)\nWHERE m.ROWID = ?", params: [numericId], map: target).first else {
                throw ToolFailure("not_found", ClientErrorMessages.messageNotFound)
            }
            targetResult = found

        } else {
            guard let cId = chatId, let searchText = contains else {
                throw ToolFailure("invalid_params", "chat_id and contains are required")
            }

            guard let numericChatId = ChatIdentifier.parseRowId(cId) else {
                throw ToolFailure("invalid_id", "Invalid chat ID format: \(cId)")
            }

            // Page newest-first through the chat. LIKE prefilters rows with
            // plain text; rows whose text is NULL (attributedBody-only) are
            // always admitted so the Swift decode can check them. LIKE is
            // ASCII-case-insensitive; the Swift check below is the one
            // that decides, so the prefilter can only remove non-matches.
            let pageSize = 500
            let scanCap = 5000
            let pattern = "%\(QueryBuilder.escapeLike(searchText))%"
            let searchLower = searchText.lowercased()
            var scanned = 0
            var offset = 0
            var foundRow: (message: MessageRecord, chatId: Int64, chatName: String?)?
            var exhausted = false

            while foundRow == nil && !exhausted && scanned < scanCap {
                let rows = try database.query(
                    """
                    \(targetQuery)
                    WHERE c.ROWID = ?
                      AND \(SQLFragments.notReaction())
                      AND (m.text LIKE ? ESCAPE '\\' OR (m.text IS NULL AND m.attributedBody IS NOT NULL))
                    ORDER BY m.date DESC
                    LIMIT ? OFFSET ?
                    """,
                    params: [numericChatId, pattern, pageSize, offset],
                    map: target
                )
                scanned += rows.count
                offset += pageSize
                exhausted = rows.count < pageSize
                foundRow = rows.first { $0.message.text?.lowercased().contains(searchLower) ?? false }
            }

            guard let found = foundRow else {
                if exhausted {
                    throw ToolFailure("not_found", "No message found containing '\(searchText)'")
                }
                throw ToolFailure("not_found_in_window", "No message containing '\(searchText)' in the newest \(scanned) candidate messages of this chat (scan cap \(scanCap)). Narrow the phrase or use search with chat_id to find the message id, then call get_context with message_id.")
            }
            targetResult = found
        }

        let targetChatId = targetResult.chatId
        let window = try MessageWindow.around(
            [MessageWindow.Anchor(chatId: targetChatId, message: targetResult.message)],
            before: beforeCount,
            after: afterCount,
            db: database
        ).values.first ?? MessageWindow.Context()
        let beforeRows = window.before
        let afterRows = window.after

        let shown = [targetResult.message] + beforeRows + afterRows
        let annotations = try MessageAnnotations.load(for: shown, include: [.reactions, .replies], db: database)

        // Keys go to reactors first, then senders, each in window order.
        var people = PeopleMap(rules: .seen)
        func see(_ handle: String?) async {
            guard let handle else { return people.addMe() }
            people.add(handle: handle, name: await resolver.resolve(handle))
        }
        for message in shown {
            for reaction in annotations.reactions[message.guid] ?? [] {
                await see(reaction.fromHandle)
            }
        }
        for message in shown {
            await see(message.isFromMe ? nil : message.senderHandle ?? noHandle)
        }
        let renderer = MessageRenderer(
            annotations: annotations,
            labels: people.labels(noHandle: people.keyByHandle[noHandle] ?? noHandle)
        )
        func context(_ rows: [MessageRecord]) -> [ContextMessage] {
            rows.map { ContextMessage(renderer.render($0), showAgo: true) }
        }

        let chatName = try await ChatPage.identities(
            [ChatPage.Chat(id: targetChatId, explicitName: targetResult.chatName)],
            db: database,
            resolver: resolver
        )[targetChatId]?.displayName ?? DisplayNameGenerator.fromNames([])

        let response = GetContextResponse(
            chat: ChatReference(id: ChatIdentifier.format(targetChatId), name: chatName),
            people: Dictionary(uniqueKeysWithValues: people.people.map { person in
                (person.key, GetContextResponse.PersonInfo(
                    name: person.name ?? person.handle ?? "Me",
                    handle: person.handle,
                    isMe: person.isMe ? true : nil
                ))
            }),
            message: ContextMessage(renderer.render(targetResult.message), showAgo: true),
            before: context(beforeRows),
            after: context(afterRows)
        )

        return response
    }
}
