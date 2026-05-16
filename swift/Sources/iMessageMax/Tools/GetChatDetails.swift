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

struct GetChatDetailsError: Codable {
    let error: String
    let message: String
}

enum GetChatDetailsTool {
    static let name = "get_chat_details"

    static func register(on server: Server, db: Database, resolver: ContactResolver) {
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

        server.registerTool(
            name: name,
            description: "Get factual details for a known chat. Useful when you already have chat_id and need exact participants, handles, thread state, and recent shared-item context without reading the full conversation. Use chat.id for follow-up tool calls only; when explaining results to the user, refer to chat.name or participant names, not the id.",
            inputSchema: inputSchema,
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
            let error = GetChatDetailsError(error: "validation_error", message: "chat_id is required")
            throw ToolError(content: [.plainText(try FormatUtils.encodeJSON(error))])
        }
        let includeShared = arguments?["include_shared_summary"]?.boolValue ?? true

        try? await resolver.initialize()

        do {
            guard let numericChatId = try resolveChatId(chatId, database: database) else {
                let error = GetChatDetailsError(error: "chat_not_found", message: "Chat not found: \(chatId)")
                throw ToolError(content: [.plainText(try FormatUtils.encodeJSON(error))])
            }

            let chatRow = try loadChatRow(chatId: numericChatId, database: database)
            let participants = try await loadParticipants(chatId: numericChatId, resolver: resolver, database: database)
            let identity = ChatIdentity(
                mcpId: "chat\(numericChatId)",
                guid: chatRow.guid,
                explicitName: chatRow.displayName,
                participants: participants
            )
            let chatSummary = try ChatSummaryBuilder.buildSummary(
                db: database,
                chatId: numericChatId,
                identity: identity
            )

            let lastMessageResult = try await loadLastMessage(chatId: numericChatId, resolver: resolver, database: database)
            let state = try loadState(
                chatId: numericChatId,
                lastMessageAwaitingReply: lastMessageResult.awaitingReply,
                database: database
            )

            let shared: [SharedMessageItem]?
            if includeShared {
                shared = try await ListAttachments(db: database, resolver: resolver).browseSharedMessages(
                    chatId: numericChatId,
                    fromPerson: nil,
                    typeFilter: nil,
                    since: nil,
                    before: nil,
                    limit: 5,
                    sort: .recentFirst
                )
            } else {
                shared = nil
            }

            let response = GetChatDetailsResponse(
                chat: chatSummary,
                participants: IdentityDisplayFormatter.participants(identity.participants),
                identity: ChatDetailsIdentity(
                    guid: identity.guid,
                    explicitName: identity.explicitName,
                    isNamed: identity.isNamed,
                    aliases: identity.aliases
                ),
                state: state,
                lastMessage: lastMessageResult.summary,
                shared: shared
            )

            return [.plainText(try FormatUtils.encodeJSON(response))]
        } catch let error as ToolError {
            throw error
        } catch let error as DatabaseError {
            let payload: GetChatDetailsError
            switch error {
            case .notFound(let path):
                payload = GetChatDetailsError(error: "database_not_found", message: "Database not found at \(path)")
            case .permissionDenied(let path):
                payload = GetChatDetailsError(error: "permission_denied", message: "Permission denied for \(path)")
            case .queryFailed(let message):
                payload = GetChatDetailsError(error: "query_failed", message: message)
            case .invalidData(let message):
                payload = GetChatDetailsError(error: "invalid_data", message: message)
            }
            throw ToolError(content: [.plainText(try FormatUtils.encodeJSON(payload))])
        } catch {
            let payload = GetChatDetailsError(error: "internal_error", message: error.localizedDescription)
            throw ToolError(content: [.plainText(try FormatUtils.encodeJSON(payload))])
        }
    }

    private struct ChatRow {
        let guid: String?
        let displayName: String?
    }

    private struct LastMessageResult {
        let summary: LastMessageSummary?
        let awaitingReply: Bool?
    }

    private static func resolveChatId(_ chatId: String, database: Database) throws -> Int64? {
        if chatId.hasPrefix("chat"), let numeric = Int64(String(chatId.dropFirst(4))) {
            return numeric
        }

        let rows: [Int64] = try database.query(
            "SELECT ROWID FROM chat WHERE guid LIKE ? ESCAPE '\\' LIMIT 1",
            params: ["%\(QueryBuilder.escapeLike(chatId))%"]
        ) { row in
            row.int(0)
        }

        return rows.first
    }

    private static func loadChatRow(chatId: Int64, database: Database) throws -> ChatRow {
        let rows: [ChatRow] = try database.query(
            "SELECT guid, display_name FROM chat WHERE ROWID = ?",
            params: [chatId]
        ) { row in
            ChatRow(guid: row.string(0), displayName: row.string(1))
        }

        guard let row = rows.first else {
            throw DatabaseError.queryFailed("Chat not found: \(chatId)")
        }
        return row
    }

    private static func loadParticipants(
        chatId: Int64,
        resolver: ContactResolver,
        database: Database
    ) async throws -> [ChatIdentity.Participant] {
        let handles: [String] = try database.query(
            """
            SELECT h.id
            FROM handle h
            JOIN chat_handle_join chj ON h.ROWID = chj.handle_id
            WHERE chj.chat_id = ?
            ORDER BY h.id ASC
            """,
            params: [chatId]
        ) { row in
            row.string(0) ?? ""
        }

        var participants: [ChatIdentity.Participant] = []
        for handle in handles {
            participants.append(
                ChatIdentity.makeParticipant(
                    handle: handle,
                    contactName: await resolver.resolve(handle)
                )
            )
        }
        return participants
    }

    private static func loadLastMessage(
        chatId: Int64,
        resolver: ContactResolver,
        database: Database
    ) async throws -> LastMessageResult {
        let rows = try database.query(
            """
            SELECT m.ROWID, m.text, m.attributedBody, m.date, m.is_from_me, h.id
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE cmj.chat_id = ?
            AND m.associated_message_type = 0
            ORDER BY m.date DESC
            LIMIT 1
            """,
            params: [chatId]
        ) { row in
            (
                messageId: row.int(0),
                text: row.string(1),
                attributedBody: row.blob(2),
                date: row.optionalInt(3),
                isFromMe: row.int(4) == 1,
                senderHandle: row.string(5)
            )
        }

        guard let row = rows.first else {
            return LastMessageResult(summary: nil, awaitingReply: nil)
        }

        let from: String
        if row.isFromMe {
            from = "Me"
        } else if let handle = row.senderHandle {
            from = await IdentityDisplayFormatter.displayName(handle: handle, resolver: resolver)
        } else {
            from = "Unknown"
        }

        let date = AppleTime.toDate(row.date)
        let summary = LastMessageSummary(
            from: from,
            text: try MessagePreviewResolver.messageSummary(
                db: database,
                messageId: row.messageId,
                text: row.text,
                attributedBody: row.attributedBody,
                maxLength: 80
            ),
            ago: TimeUtils.formatCompactRelative(date),
            ts: TimeUtils.formatISO(date)
        )

        return LastMessageResult(summary: summary, awaitingReply: !row.isFromMe)
    }

    private static func loadState(
        chatId: Int64,
        lastMessageAwaitingReply: Bool?,
        database: Database
    ) throws -> ChatDetailsState {
        let activityRows = try database.query(
            """
            SELECT
                COUNT(CASE WHEN m.is_read = 0 AND m.is_from_me = 0 THEN 1 END) as unread_count,
                MIN(m.date) as first_activity,
                MAX(m.date) as last_activity
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            WHERE cmj.chat_id = ?
            AND m.associated_message_type = 0
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
