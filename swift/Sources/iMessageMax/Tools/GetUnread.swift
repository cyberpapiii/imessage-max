// Sources/iMessageMax/Tools/GetUnread.swift
import Foundation
import MCP

/// Response format for get_unread tool
enum UnreadFormat: String, CaseIterable {
    case messages
    case summary
}

struct UnreadMessagesResponse: Codable {
    let messages: [UnreadMessageItem]
    let totalUnread: Int
    let chatsWithUnread: Int
    let more: Bool
    let cursor: String?

    enum CodingKeys: String, CodingKey {
        case messages
        case totalUnread = "total_unread"
        case chatsWithUnread = "chats_with_unread"
        case more
        case cursor
    }
}

struct UnreadMessageItem: Codable {
    let id: String
    let chat: ChatReference
    let from: String
    let text: String?
    let ago: String?
    let ts: String?
}

struct UnreadSummaryResponse: Codable {
    let chats: [UnreadChatSummary]
    let totalUnread: Int
    let chatsWithUnread: Int

    enum CodingKeys: String, CodingKey {
        case chats
        case totalUnread = "total_unread"
        case chatsWithUnread = "chats_with_unread"
    }
}

struct UnreadChatSummary: Codable {
    let chat: ChatSummary
    let unreadCount: Int
    let oldestUnread: String?
    let lastMessage: LastMessageSummary?

    enum CodingKeys: String, CodingKey {
        case chat
        case unreadCount = "unread_count"
        case oldestUnread = "oldest_unread"
        case lastMessage = "last_message"
    }
}

/// Get unread messages or summary
final class GetUnread {
    private let database: Database
    private let contactResolver: ContactResolver

    init(database: Database = Database(), contactResolver: ContactResolver = ContactResolver()) {
        self.database = database
        self.contactResolver = contactResolver
    }

    // MARK: - Tool Registration

    static func register(on server: Server, db: Database, resolver: ContactResolver) {
        let inputSchema: Value = .object([
            "type": "object",
            "properties": .object([
                "chat_id": .object([
                    "type": "string",
                    "description": "Filter to specific chat (e.g., \"chat123\")",
                ]),
                "since": .object([
                    "type": "string",
                    "description": "Time window for unread-only results (default \"7d\", use \"all\" for all time)",
                ]),
                "format": .object([
                    "type": "string",
                    "description": "Response format for unread data (default summary)",
                    "enum": ["messages", "summary"],
                ]),
                "limit": .object([
                    "type": "integer",
                    "description": "Max messages (default 50, max 100)",
                ]),
            ]),
            "additionalProperties": false,
        ])

        server.registerTool(
            name: "get_unread",
            description: "Get a narrower view of still-unread messages or unread activity summary. Returns chat ids for follow-up tool calls and chat names for user-facing summaries. When explaining results to the user, refer to chats by name, not by id. Useful as a follow-up check, not a complete recent conversation overview.",
            inputSchema: inputSchema,
            annotations: Tool.Annotations(
                title: "Get Unread Messages",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let chatId = arguments?["chat_id"]?.stringValue
            let since = arguments?["since"]?.stringValue ?? "7d"
            let formatStr = arguments?["format"]?.stringValue ?? "summary"
            let limit = arguments?["limit"]?.intValue ?? 50

            let format = UnreadFormat(rawValue: formatStr) ?? .messages
            let params = Parameters(
                chatId: chatId,
                since: since,
                format: format,
                limit: limit,
                cursor: nil
            )

            let tool = GetUnread(database: db, contactResolver: resolver)
            do {
                let result = try await tool.execute(params: params)
                return [.plainText(try FormatUtils.encodeJSON(result))]
            } catch let error as ToolError {
                throw error
            } catch {
                let errorResponse = ["error": "execution_error", "message": error.localizedDescription]
                throw ToolError(content: [.plainText(try FormatUtils.encodeJSONObject(errorResponse))])
            }
        }
    }

    /// Parameters for get_unread tool
    struct Parameters {
        var chatId: String?         // Filter to specific chat (e.g., "chat123")
        var since: String           // Time window (default "7d", accepts "all")
        var format: UnreadFormat    // "messages" or "summary"
        var limit: Int              // Max messages (default 50, max 100)
        var cursor: String?         // Pagination cursor

        init(
            chatId: String? = nil,
            since: String = "7d",
            format: UnreadFormat = .summary,
            limit: Int = 50,
            cursor: String? = nil
        ) {
            self.chatId = chatId
            self.since = since
            self.format = format
            self.limit = max(1, min(limit, 100))  // Clamp to 1-100
            self.cursor = cursor
        }
    }

    /// Execute get_unread with given parameters
    func execute(params: Parameters) async throws -> any Encodable {
        // Initialize contact resolver
        try await contactResolver.initialize()

        // Parse since parameter - "all" means no time filter
        var sinceApple: Int64?
        if params.since.lowercased() != "all" {
            sinceApple = AppleTime.parse(params.since)
        }

        // Resolve chat_id to numeric ID if provided
        var numericChatId: Int64?
        if let chatId = params.chatId {
            numericChatId = try resolveChatId(chatId)
            if numericChatId == nil {
                throw ToolError(content: [.plainText("{\"error\":\"chat_not_found\",\"message\":\"Chat not found: \(chatId)\"}")])
            }
        }

        switch params.format {
        case .summary:
            return try await getUnreadSummary(
                chatId: numericChatId,
                sinceApple: sinceApple
            )
        case .messages:
            return try await getUnreadMessages(
                chatId: numericChatId,
                sinceApple: sinceApple,
                limit: params.limit
            )
        }
    }

    // MARK: - Private Methods

    private func resolveChatId(_ chatId: String) throws -> Int64? {
        // Try parsing "chatXXX" format
        if chatId.hasPrefix("chat") {
            let numStr = String(chatId.dropFirst(4))
            if let num = Int64(numStr) {
                return num
            }
        }

        // Try to find by GUID
        let escapedChatId = QueryBuilder.escapeLike(chatId)
        let rows: [(Int64, String?)] = try database.query(
            "SELECT ROWID, guid FROM chat WHERE guid LIKE ? ESCAPE '\\'",
            params: ["%\(escapedChatId)%"]
        ) { row in
            (row.int(0), row.string(1))
        }

        return rows.first?.0
    }

    private func getUnreadMessages(
        chatId: Int64?,
        sinceApple: Int64?,
        limit: Int
    ) async throws -> UnreadMessagesResponse {
        // Build query for unread messages
        // Unread = is_read = 0 AND is_from_me = 0
        var queryBuilder = QueryBuilder()
            .select(
                "m.ROWID as id",
                "m.guid",
                "m.text",
                "m.attributedBody",
                "m.date",
                "m.is_from_me",
                "m.handle_id",
                "h.id as sender_handle",
                "c.ROWID as chat_id",
                "c.display_name as chat_display_name",
                "c.guid as chat_guid"
            )
            .from("message m")
            .join("chat_message_join cmj ON m.ROWID = cmj.message_id")
            .join("chat c ON cmj.chat_id = c.ROWID")
            .leftJoin("handle h ON m.handle_id = h.ROWID")
            .where("m.is_read = 0")
            .where("m.is_from_me = 0")
            .where("m.associated_message_type = 0")

        // Apply time window filter (default 7 days to match Messages.app)
        if let sinceApple = sinceApple {
            queryBuilder = queryBuilder.where("m.date >= ?", sinceApple)
        }

        if let chatId = chatId {
            queryBuilder = queryBuilder.where("cmj.chat_id = ?", chatId)
        }

        queryBuilder = queryBuilder
            .orderBy("m.date ASC")
            .limit(limit)

        let (sql, params) = queryBuilder.build()

        // Fetch unread messages
        let rows: [UnreadMessageRow] = try database.query(sql, params: params) { row in
            UnreadMessageRow(
                id: row.int(0),
                guid: row.string(1),
                text: row.string(2),
                attributedBody: row.blob(3),
                date: row.optionalInt(4),
                isFromMe: row.int(5) == 1,
                handleId: row.optionalInt(6),
                senderHandle: row.string(7),
                chatId: row.int(8),
                chatDisplayName: row.string(9),
                chatGuid: row.string(10)
            )
        }

        // Get total count and chat count
        let (totalUnread, chatsWithUnread) = try getUnreadCounts(
            chatId: chatId,
            sinceApple: sinceApple
        )

        // Cache for chat participants
        var chatParticipantsCache: [Int64: [ParticipantInfo]] = [:]

        var unreadMessages: [UnreadMessageItem] = []

        for row in rows {
            let msgChatId = row.chatId
            let senderHandle = row.senderHandle

            // Ensure participants are cached for this chat
            if chatParticipantsCache[msgChatId] == nil {
                chatParticipantsCache[msgChatId] = try await getChatParticipants(chatId: msgChatId)
            }
            let participants = chatParticipantsCache[msgChatId] ?? []
            let identity = makeChatIdentity(
                chatId: msgChatId,
                explicitName: row.chatDisplayName,
                participants: participants
            )

            // Get message text
            let text = MessageTextExtractor.extract(text: row.text, attributedBody: row.attributedBody)
            let msgDate = AppleTime.toDate(row.date)

            let senderName: String
            if let handle = senderHandle {
                senderName = await IdentityDisplayFormatter.displayName(handle: handle, resolver: contactResolver)
            } else {
                senderName = "Unknown"
            }

            unreadMessages.append(
                UnreadMessageItem(
                    id: "msg_\(row.id)",
                    chat: ChatReference(id: identity.mcpId, name: identity.displayName),
                    from: senderName,
                    text: text,
                    ago: TimeUtils.formatCompactRelative(msgDate),
                    ts: TimeUtils.formatISO(msgDate)
                )
            )
        }

        return UnreadMessagesResponse(
            messages: unreadMessages,
            totalUnread: totalUnread,
            chatsWithUnread: chatsWithUnread,
            more: unreadMessages.count < totalUnread,
            cursor: nil
        )
    }

    private func getUnreadSummary(
        chatId: Int64?,
        sinceApple: Int64?
    ) async throws -> UnreadSummaryResponse {
        // Build query for summary by chat
        var queryBuilder = QueryBuilder()
            .select(
                "cmj.chat_id",
                "c.display_name as chat_display_name",
                "COUNT(*) as unread_count",
                "MIN(m.date) as oldest_unread_date",
                "MAX(m.date) as latest_unread_date"
            )
            .from("message m")
            .join("chat_message_join cmj ON m.ROWID = cmj.message_id")
            .join("chat c ON cmj.chat_id = c.ROWID")
            .where("m.is_read = 0")
            .where("m.is_from_me = 0")
            .where("m.associated_message_type = 0")

        if let sinceApple = sinceApple {
            queryBuilder = queryBuilder.where("m.date >= ?", sinceApple)
        }

        if let chatId = chatId {
            queryBuilder = queryBuilder.where("cmj.chat_id = ?", chatId)
        }

        queryBuilder = queryBuilder
            .groupBy("cmj.chat_id")
            .orderBy("unread_count DESC")

        let (sql, params) = queryBuilder.build()

        let rows: [SummaryRow] = try database.query(sql, params: params) { row in
            SummaryRow(
                chatId: row.int(0),
                chatDisplayName: row.string(1),
                unreadCount: Int(row.int(2)),
                oldestUnreadDate: row.optionalInt(3),
                latestUnreadDate: row.optionalInt(4)
            )
        }

        var totalUnread = 0
        var chats: [UnreadChatSummary] = []

        for row in rows {
            let msgChatId = row.chatId
            let unreadCount = row.unreadCount
            totalUnread += unreadCount

            let oldestDt = AppleTime.toDate(row.oldestUnreadDate)
            let participants = try await getChatParticipants(chatId: msgChatId)
            let identity = makeChatIdentity(
                chatId: msgChatId,
                explicitName: row.chatDisplayName,
                participants: participants
            )
            let summary = try ChatSummaryBuilder.buildSummary(
                db: database,
                chatId: msgChatId,
                identity: identity
            )

            let lastMessage = try await getLatestUnreadMessageSummary(chatId: msgChatId, sinceApple: sinceApple)

            chats.append(
                UnreadChatSummary(
                    chat: summary,
                    unreadCount: unreadCount,
                    oldestUnread: TimeUtils.formatCompactRelative(oldestDt),
                    lastMessage: lastMessage
                )
            )
        }

        return UnreadSummaryResponse(
            chats: chats,
            totalUnread: totalUnread,
            chatsWithUnread: chats.count
        )
    }

    private func makeChatIdentity(
        chatId: Int64,
        explicitName: String?,
        participants: [ParticipantInfo]
    ) -> ChatIdentity {
        ChatIdentity(
            mcpId: "chat\(chatId)",
            guid: nil,
            explicitName: explicitName,
            participants: participants.map {
                ChatIdentity.makeParticipant(handle: $0.handle, contactName: $0.name)
            }
        )
    }

    private func getUnreadCounts(
        chatId: Int64?,
        sinceApple: Int64?
    ) throws -> (totalUnread: Int, chatsWithUnread: Int) {
        var queryBuilder = QueryBuilder()
            .select(
                "COUNT(DISTINCT m.ROWID) as total_unread",
                "COUNT(DISTINCT cmj.chat_id) as chats_with_unread"
            )
            .from("message m")
            .join("chat_message_join cmj ON m.ROWID = cmj.message_id")
            .where("m.is_read = 0")
            .where("m.is_from_me = 0")
            .where("m.associated_message_type = 0")

        if let sinceApple = sinceApple {
            queryBuilder = queryBuilder.where("m.date >= ?", sinceApple)
        }

        if let chatId = chatId {
            queryBuilder = queryBuilder.where("cmj.chat_id = ?", chatId)
        }

        let (sql, params) = queryBuilder.build()

        let rows: [(Int, Int)] = try database.query(sql, params: params) { row in
            (Int(row.int(0)), Int(row.int(1)))
        }

        guard let first = rows.first else {
            return (0, 0)
        }

        return first
    }

    private func getLatestUnreadMessageSummary(
        chatId: Int64,
        sinceApple: Int64?
    ) async throws -> LastMessageSummary? {
        var queryBuilder = QueryBuilder()
            .select(
                "m.ROWID",
                "m.text",
                "m.attributedBody",
                "m.date",
                "h.id as sender_handle"
            )
            .from("message m")
            .join("chat_message_join cmj ON m.ROWID = cmj.message_id")
            .leftJoin("handle h ON m.handle_id = h.ROWID")
            .where("cmj.chat_id = ?", chatId)
            .where("m.is_read = 0")
            .where("m.is_from_me = 0")
            .where("m.associated_message_type = 0")
            .orderBy("m.date DESC")
            .limit(1)

        if let sinceApple {
            queryBuilder = queryBuilder.where("m.date >= ?", sinceApple)
        }

        let (sql, params) = queryBuilder.build()
        let rows = try database.query(sql, params: params) { row in
            (
                messageId: row.int(0),
                text: row.string(1),
                attributedBody: row.blob(2),
                date: row.optionalInt(3),
                senderHandle: row.string(4)
            )
        }

        guard let row = rows.first else { return nil }
        let date = AppleTime.toDate(row.date)
        let sender: String
        if let handle = row.senderHandle {
            sender = await IdentityDisplayFormatter.displayName(handle: handle, resolver: contactResolver)
        } else {
            sender = "Unknown"
        }

        return LastMessageSummary(
            from: sender,
            text: try MessagePreviewResolver.messageSummary(
                db: database,
                messageId: row.messageId,
                text: row.text,
                attributedBody: row.attributedBody,
                maxLength: 50
            ),
            ago: TimeUtils.formatCompactRelative(date),
            ts: TimeUtils.formatISO(date)
        )
    }

    private func getChatParticipants(chatId: Int64) async throws -> [ParticipantInfo] {
        let rows: [(Int64, String, String?)] = try database.query("""
            SELECT h.ROWID, h.id as handle, h.service
            FROM chat_handle_join chj
            JOIN handle h ON chj.handle_id = h.ROWID
            WHERE chj.chat_id = ?
        """, params: [chatId]) { row in
            (row.int(0), row.string(1) ?? "", row.string(2))
        }

        var participants: [ParticipantInfo] = []
        for (_, handle, service) in rows {
            let name = await contactResolver.resolve(handle)
            participants.append(ParticipantInfo(
                handle: handle,
                name: name,
                service: service
            ))
        }

        return participants
    }

}

// MARK: - Helper Types

private struct UnreadMessageRow {
    let id: Int64
    let guid: String?
    let text: String?
    let attributedBody: Data?
    let date: Int64?
    let isFromMe: Bool
    let handleId: Int64?
    let senderHandle: String?
    let chatId: Int64
    let chatDisplayName: String?
    let chatGuid: String?
}

private struct SummaryRow {
    let chatId: Int64
    let chatDisplayName: String?
    let unreadCount: Int
    let oldestUnreadDate: Int64?
    let latestUnreadDate: Int64?
}

private struct ParticipantInfo {
    let handle: String
    let name: String?
    let service: String?
}
