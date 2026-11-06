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
    static let before = IntArgument(name: "before", defaultValue: 5, range: 0...50)
    static let after = IntArgument(name: "after", defaultValue: 10, range: 0...50)

    private static let noHandle = "unknown"

    static func definition(db: Database, resolver: ContactResolver) -> ToolDefinition {
        let inputSchema: Value = .object([
            "type": "object",
            "properties": .object([
                "message_id": .object([
                    "type": "string",
                    "description": "Message ID to get context around (e.g., \"msg_1\")",
                ]),
                "chat_id": .object([
                    "type": "string",
                    "description": "Chat ID (required if using contains)",
                ]),
                "contains": .object([
                    "type": "string",
                    "description": "Find the newest message that contains this text (case-insensitive), then get its context. The scan checks up to 5000 candidate messages, newest first, and returns not_found_in_window if it reaches that cap.",
                ]),
                "before": .object([
                    "type": "integer",
                    "description": "Number of messages before the target (\(before.defaultAndMax))",
                ]),
                "after": .object([
                    "type": "integer",
                    "description": "Number of messages after the target (\(after.defaultAndMax))",
                ]),
            ]),
            "additionalProperties": false,
        ])

        return ToolDefinition(
            name: "get_context",
            description: "Get the messages before and after a specific message. Returns the id of the chat that contains it for follow-up tool calls and the chat name for user-facing summaries. When you explain results to the user, refer to chats by name, not by id.",
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
            let before = Self.before.read(arguments)
            let after = Self.after.read(arguments)

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
        before: Int = GetContext.before.defaultValue,
        after: Int = GetContext.after.defaultValue,
        database: Database,
        resolver: ContactResolver
    ) async throws -> GetContextResponse {
        let beforeCount = Self.before.clamp(before)
        let afterCount = Self.after.clamp(after)

        if messageId == nil && (chatId == nil || contains == nil) {
            throw ToolFailure("invalid_params", "Either message_id OR (chat_id + contains) is required")
        }

        if contains != nil && chatId == nil {
            throw ToolFailure("invalid_params", "chat_id is required when using contains")
        }

        enum Target {
            case message(Int64)
            case text(String, inChat: Int64)
        }
        let target: Target
        if let msgIdStr = messageId {
            guard let numericId = MessageIdentifier.parse(msgIdStr) else {
                throw ToolFailure("invalid_id", "Invalid message ID format: \(msgIdStr)")
            }
            target = .message(numericId)
        } else if let cId = chatId, let searchText = contains {
            target = .text(searchText, inChat: try ChatIdentifier.resolve(cId, db: database))
        } else {
            throw ToolFailure("invalid_params", "chat_id and contains are required")
        }

        let schema = try database.schema()
        let targetQuery = """
            SELECT \(MessageRecord.selectList(schema)), \(MessageInChat.chatColumns)
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            JOIN chat c ON cmj.chat_id = c.ROWID
            \(MessageRecord.handleJoinsSQL)
            """
        let targetResult: MessageInChat

        switch target {
        case .message(let numericId):
            guard let found = try database.query("\(targetQuery)\nWHERE m.ROWID = ? AND c.ROWID = \(ChatScope.byMessage.listedChat())", params: [numericId], map: MessageInChat.init).first else {
                throw ToolFailure("not_found", ClientErrorMessages.messageNotFound)
            }
            targetResult = found

        case .text(let searchText, let numericChatId):
            let pageSize = 500
            let scanCap = 5000
            let match = SQLFragments.textMayContain(searchText)
            let searchLower = searchText.lowercased()
            var scanned = 0
            var resumeAfter: TimelineCursor?
            var foundRow: MessageInChat?
            var exhausted = false

            while foundRow == nil && !exhausted && scanned < scanCap {
                var sql = """
                    \(targetQuery)
                    WHERE c.ROWID = ?
                      AND \(SQLFragments.notReaction())
                      AND \(match.sql)
                    """
                var params: [Any] = [numericChatId] + match.bindings
                if let older = resumeAfter?.predicate(descending: true) {
                    sql += "\n  AND \(older.sql)"
                    params += older.params
                }
                sql += "\nORDER BY m.date DESC, m.ROWID DESC\nLIMIT ?"
                params.append(pageSize)

                let rows = try database.query(sql, params: params, map: MessageInChat.init)
                scanned += rows.count
                foundRow = rows.first { $0.message.text?.lowercased().contains(searchLower) ?? false }
                if let last = rows.last?.message, let date = last.date, rows.count == pageSize {
                    resumeAfter = TimelineCursor(date: date, messageId: last.id)
                } else {
                    exhausted = true
                }
            }

            guard let found = foundRow else {
                if exhausted {
                    throw ToolFailure("not_found", "No message found containing '\(searchText)'")
                }
                throw ToolFailure("not_found_in_window", "No message containing '\(searchText)' in the newest \(scanned) candidate messages of this chat (scan cap \(scanCap)). Narrow the phrase or use search with in_chat to find the message id, then call get_context with message_id.")
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

        let chat = try await ChatReferences([targetResult].chats, db: database, resolver: resolver)[targetChatId]

        let response = GetContextResponse(
            chat: chat,
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
