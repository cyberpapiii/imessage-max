// Sources/iMessageMax/Tools/GetUnread.swift
import Foundation
import MCP

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
    let more: Bool

    enum CodingKeys: String, CodingKey {
        case chats
        case totalUnread = "total_unread"
        case chatsWithUnread = "chats_with_unread"
        case more
    }
}

struct UnreadError: Codable {
    let error: String
    let message: String
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
            outputSchema: OutputSchema.object,
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

            let format = UnreadFormat(rawValue: formatStr) ?? .summary
            let params = Parameters(
                chatId: chatId,
                since: since,
                format: format,
                limit: limit
            )

            let tool = GetUnread(database: db, contactResolver: resolver)
            do {
                let result = try await tool.execute(params: params)
                return [.plainText(try FormatUtils.encodeJSON(result))]
            } catch let error as ToolError {
                throw error
            } catch let error as DatabaseError {
                let mapped = ToolErrorMapping.map(error, context: "get_unread")
                let payload = UnreadError(error: mapped.code, message: mapped.message)
                throw ToolError(content: [.plainText(try FormatUtils.encodeJSON(payload))])
            } catch {
                let payload = UnreadError(error: "internal_error", message: ClientErrorMessages.sanitized(error))
                throw ToolError(content: [.plainText(try FormatUtils.encodeJSON(payload))])
            }
        }
    }

    struct Parameters {
        var chatId: String?
        var since: String
        var format: UnreadFormat
        var limit: Int

        init(
            chatId: String? = nil,
            since: String = "7d",
            format: UnreadFormat = .summary,
            limit: Int = 50
        ) {
            self.chatId = chatId
            self.since = since
            self.format = format
            self.limit = max(1, min(limit, 100))
        }
    }

    func execute(params: Parameters) async throws -> any Encodable {
        try await contactResolver.initialize()

        // "all" means no time filter
        var sinceApple: Int64?
        if params.since.lowercased() != "all" {
            sinceApple = AppleTime.parse(params.since)
        }

        var numericChatId: Int64?
        if let chatId = params.chatId {
            numericChatId = ChatIdentifier.parseRowId(chatId)
            if numericChatId == nil {
                let payload = UnreadError(error: "chat_not_found", message: "Chat not found: \(chatId)")
                throw ToolError(content: [.plainText(try FormatUtils.encodeJSON(payload))])
            }
        }

        switch params.format {
        case .summary:
            return try await getUnreadSummary(
                chatId: numericChatId,
                sinceApple: sinceApple,
                limit: params.limit
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

    private func getUnreadMessages(
        chatId: Int64?,
        sinceApple: Int64?,
        limit: Int
    ) async throws -> UnreadMessagesResponse {
        // Unread = is_read = 0 AND is_from_me = 0
        var queryBuilder = QueryBuilder()
            .select(
                "m.ROWID as id",
                "m.text",
                "m.attributedBody",
                "m.date",
                "h.id as sender_handle",
                "c.ROWID as chat_id",
                "c.display_name as chat_display_name"
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
            .limit(limit + 1)

        let (sql, params) = queryBuilder.build()

        var rows: [UnreadMessageRow] = try database.query(sql, params: params) { row in
            UnreadMessageRow(
                id: row.int(0),
                text: row.string(1),
                attributedBody: row.blob(2),
                date: row.optionalInt(3),
                senderHandle: row.string(4),
                chatId: row.int(5),
                chatDisplayName: row.string(6)
            )
        }
        let more = rows.count > limit
        if more {
            rows = Array(rows.prefix(limit))
        }

        let (totalUnread, chatsWithUnread) = try getUnreadCounts(
            chatId: chatId,
            sinceApple: sinceApple
        )

        let uniqueChatIds = Array(Set(rows.map(\.chatId)))
        let participantsByChat = try await ChatSummaryQueries.participantsByChat(
            db: database,
            chatIds: uniqueChatIds,
            resolver: contactResolver
        )

        var unreadMessages: [UnreadMessageItem] = []

        for row in rows {
            let msgChatId = row.chatId
            let senderHandle = row.senderHandle

            let participants = participantsByChat[msgChatId] ?? []
            let identity = makeChatIdentity(
                chatId: msgChatId,
                explicitName: row.chatDisplayName,
                participants: participants
            )

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
            // Pagination is by limit only (no cursor); more reports truncation honestly.
            more: more,
            cursor: nil
        )
    }

    private func getUnreadSummary(
        chatId: Int64?,
        sinceApple: Int64?,
        limit: Int
    ) async throws -> UnreadSummaryResponse {
        var queryBuilder = QueryBuilder()
            .select(
                "cmj.chat_id",
                "c.display_name as chat_display_name",
                "COUNT(*) as unread_count",
                "MIN(m.date) as oldest_unread_date",
                // Free alongside the MIN, and it saves the preview lookup from
                // searching each chat's history for the message it names.
                "MAX(m.date) as newest_unread_date"
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
            .limit(limit + 1)

        let (sql, params) = queryBuilder.build()

        var rows: [SummaryRow] = try database.query(sql, params: params) { row in
            SummaryRow(
                chatId: row.int(0),
                chatDisplayName: row.string(1),
                unreadCount: Int(row.int(2)),
                oldestUnreadDate: row.optionalInt(3),
                newestUnreadDate: row.optionalInt(4)
            )
        }
        let more = rows.count > limit
        if more {
            rows = Array(rows.prefix(limit))
        }

        var totalUnread = 0
        var chats: [UnreadChatSummary] = []

        // Batched lookups: one participants query and one latest-unread query
        // for all chats, instead of 2+ queries per unread chat.
        let chatIds = rows.map(\.chatId)
        let participantsByChat = try await ChatSummaryQueries.participantsByChat(
            db: database,
            chatIds: chatIds,
            resolver: contactResolver
        )
        var newestUnreadDates: [Int64: Int64] = [:]
        for row in rows {
            if let newest = row.newestUnreadDate {
                newestUnreadDates[row.chatId] = newest
            }
        }
        let lastByChat = try await ChatSummaryQueries.lastMessagesByChat(
            db: database,
            chatIds: chatIds,
            resolver: contactResolver,
            sinceApple: sinceApple,
            previewMaxLength: 50,
            unknownSenderLabel: "Unknown",
            agoFallback: nil,
            onlyUnreadInbound: true,
            newestDates: newestUnreadDates
        )
        let recentSenderChatIds = rows.compactMap { row -> Int64? in
            let trimmed = row.chatDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isNamed = trimmed?.isEmpty == false
            let count = (participantsByChat[row.chatId] ?? []).count
            return (isNamed && count > 4) ? row.chatId : nil
        }
        let recentSendersByChat = try ChatSummaryQueries.recentSendersByChat(
            db: database,
            chatIds: recentSenderChatIds
        )

        for row in rows {
            let msgChatId = row.chatId
            let unreadCount = row.unreadCount
            totalUnread += unreadCount

            let oldestDt = AppleTime.toDate(row.oldestUnreadDate)
            let participants = participantsByChat[msgChatId] ?? []
            let identity = makeChatIdentity(
                chatId: msgChatId,
                explicitName: row.chatDisplayName,
                participants: participants
            )
            let summary = try ChatSummaryBuilder.buildSummary(
                db: database,
                chatId: msgChatId,
                identity: identity,
                recentSenders: recentSendersByChat[msgChatId]
            )

            let lastMessage = lastByChat[msgChatId]?.info

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
            chatsWithUnread: chats.count,
            more: more
        )
    }

    private func makeChatIdentity(
        chatId: Int64,
        explicitName: String?,
        participants: [ChatSummaryQueries.Participant]
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

}

// MARK: - Helper Types

private struct UnreadMessageRow {
    let id: Int64
    let text: String?
    let attributedBody: Data?
    let date: Int64?
    let senderHandle: String?
    let chatId: Int64
    let chatDisplayName: String?
}

private struct SummaryRow {
    let chatId: Int64
    let chatDisplayName: String?
    let unreadCount: Int
    let oldestUnreadDate: Int64?
    let newestUnreadDate: Int64?
}

