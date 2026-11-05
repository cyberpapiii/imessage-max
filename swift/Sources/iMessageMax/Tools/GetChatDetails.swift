import Foundation
import MCP

struct GetChatDetailsResponse: Codable {
    let chat: ChatSummary
    let participants: [ChatParticipant]
    let identity: ChatDetailsIdentity
    let state: ChatDetailsState
    let lastMessage: LastMessageSummary?
    let shared: [SharedMessageItem]?

    enum CodingKeys: String, CodingKey {
        case chat, participants, identity, state, shared
        case lastMessage = "last_message"
    }
}

enum GetChatDetailsTool {
    static let name = "get_chat_details"

    static func definition(db: Database, resolver: ContactResolver) -> ToolDefinition {
        let inputSchema: Value = .object([
            "type": "object",
            "properties": .object([
                "chat_id": .object([
                    "type": "string",
                    "description": "Known chat identifier (for example \"chat123\")"
                ]),
                "include_shared_summary": .object([
                    "type": "boolean",
                    "description": "Include a compact recent shared-items summary",
                    "default": true
                ]),
            ]),
            "required": .array([.string("chat_id")]),
            "additionalProperties": false,
        ])

        return ToolDefinition(
            name: name,
            description: "Get factual details for a known chat. Useful when you already have chat_id and need exact participants, handles, thread state, and recent shared-item context without reading the full conversation. Use chat.id for follow-up tool calls only; when explaining results to the user, refer to chat.name or participant names, not the id.",
            inputSchema: inputSchema,
            outputSchema: OutputSchema.object,
            annotations: Tool.Annotations(
                title: "Get Chat Details",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await execute(arguments: arguments, database: db, resolver: resolver)
        }
    }

    static func execute(
        arguments: [String: Value]?,
        database: Database,
        resolver: ContactResolver
    ) async throws -> [Tool.Content] {
        guard let chatId = arguments?["chat_id"]?.stringValue else {
            throw ToolFailure("validation_error", "chat_id is required")
        }
        let includeShared = arguments?["include_shared_summary"]?.boolValue ?? true

        guard let numericChatId = ChatIdentifier.parseRowId(chatId) else {
            throw ToolFailure.chatNotFound(chatId)
        }
        guard let chatRow = try loadChatRow(chatId: numericChatId, database: database) else {
            throw ToolFailure.chatNotFound(chatId)
        }
        let page = try await ChatPage.build(
            [ChatPage.Chat(id: numericChatId, guid: chatRow.guid, explicitName: chatRow.displayName)],
            lastMessages: ChatPage.LastMessageOptions(previewMaxLength: 80, unknownSenderLabel: "Unknown", agoFallback: nil),
            db: database,
            resolver: resolver
        )
        guard let entry = page[numericChatId] else { throw ToolFailure.chatNotFound(chatId) }
        let identity = entry.identity
        let state = try loadState(
            chatId: numericChatId,
            lastMessageAwaitingReply: entry.lastMessage?.awaitingReply,
            database: database
        )

        let shared: [SharedMessageItem]?
        if includeShared {
            let page = try await SharedMessages.page(
                db: database,
                resolver: resolver,
                chatId: numericChatId,
                sender: nil,
                typeFilter: nil,
                since: nil,
                before: nil,
                limit: 5,
                sort: .recentFirst,
                cursor: nil
            )
            shared = page.messages
        } else {
            shared = nil
        }

        let response = GetChatDetailsResponse(
            chat: entry.summary,
            participants: IdentityDisplayFormatter.participants(identity.participants),
            identity: ChatDetailsIdentity(
                guid: identity.guid,
                explicitName: identity.explicitName,
                isNamed: identity.isNamed,
                aliases: identity.aliases
            ),
            state: state,
            lastMessage: entry.lastMessage?.info,
            shared: shared
        )

        return [.plainText(try FormatUtils.encodeJSON(response))]
    }

    private struct ChatRow {
        let guid: String?
        let displayName: String?
    }

    private static func loadChatRow(chatId: Int64, database: Database) throws -> ChatRow? {
        let rows: [ChatRow] = try database.query(
            "SELECT guid, display_name FROM chat WHERE ROWID = ?",
            params: [chatId]
        ) { row in
            ChatRow(guid: row.string(0), displayName: row.string(1))
        }
        return rows.first
    }

    private static func loadState(
        chatId: Int64,
        lastMessageAwaitingReply: Bool?,
        database: Database
    ) throws -> ChatDetailsState {
        let activityRows = try database.query(
            """
            SELECT
                COUNT(CASE WHEN \(SQLFragments.unreadInbound()) THEN 1 END) as unread_count,
                MIN(m.date) as first_activity,
                MAX(m.date) as last_activity
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            WHERE cmj.chat_id = ?
            AND \(SQLFragments.notReaction())
            """,
            params: [chatId]
        ) { row in
            (
                unreadCount: Int(row.int(0)),
                firstActivity: row.optionalInt(1),
                lastActivity: row.optionalInt(2)
            )
        }

        let row = activityRows.first ?? (unreadCount: 0, firstActivity: nil, lastActivity: nil)
        return ChatDetailsState(
            unreadCount: row.unreadCount,
            awaitingReply: lastMessageAwaitingReply,
            firstActivity: TimeUtils.formatISO(AppleTime.toDate(row.firstActivity)),
            lastActivity: TimeUtils.formatISO(AppleTime.toDate(row.lastActivity))
        )
    }
}
