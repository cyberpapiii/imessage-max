import Foundation
import MCP

enum UnreadFormat: String, CaseIterable {
    case messages
    case summary
}

struct UnreadMessagesResponse: Encodable {
    let messages: [UnreadMessageItem]
    let totalUnread: Int
    let chatsWithUnread: Int
    let more: Bool
    let cursor: String?
    let filteredHidden: Int?

    enum CodingKeys: String, CodingKey {
        case messages
        case totalUnread = "total_unread"
        case chatsWithUnread = "chats_with_unread"
        case more
        case cursor
        case filteredHidden = "filtered_hidden"
    }
}

struct UnreadMessageItem: Encodable {
    let id: String
    let chat: ChatReference
    let from: String
    let text: String?
    let ago: String?
    let ts: String?
}

struct UnreadSummaryResponse: Encodable {
    let chats: [UnreadChatSummary]
    let totalUnread: Int
    let chatsWithUnread: Int
    let more: Bool
    let filteredHidden: Int?

    enum CodingKeys: String, CodingKey {
        case chats
        case totalUnread = "total_unread"
        case chatsWithUnread = "chats_with_unread"
        case more
        case filteredHidden = "filtered_hidden"
    }
}

struct UnreadChatSummary: Encodable {
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
    static let limit = IntArgument(name: "limit", defaultValue: 50, range: 1...100)
    static let defaultSince = "7d"

    private let database: Database
    private let contactResolver: ContactResolver

    init(database: Database, contactResolver: ContactResolver) {
        self.database = database
        self.contactResolver = contactResolver
    }

    static func definition(db: Database, resolver: ContactResolver) -> ToolDefinition {
        let inputSchema: Value = .object([
            "type": "object",
            "properties": .object([
                "chat_id": .object([
                    "type": "string",
                    "description": "Filter to specific chat (e.g., \"chat123\")",
                ]),
                "since": .object([
                    "type": "string",
                    "description": "Time window for unread messages (default \"\(defaultSince)\"; use \"all\" for all time)",
                ]),
                "format": .object([
                    "type": "string",
                    "description": "Response format (default summary)",
                    "enum": ["messages", "summary"],
                ]),
                "limit": .object([
                    "type": "integer",
                    "description": "Maximum messages to return (\(Self.limit.defaultAndMax))",
                ]),
                "include_filtered": .object([
                    "type": "boolean",
                    "description": "Include chats Messages.app has filtered as junk or unknown senders (default false)",
                ]),
                "cursor": .object([
                    "type": "string",
                    "description": "Pagination cursor from a previous get_unread response (messages format only)",
                ]),
            ]),
            "additionalProperties": false,
        ])

        return ToolDefinition(
            name: "get_unread",
            description: "Get the messages that are still unread, or a summary of unread activity. Returns chat ids for follow-up tool calls and chat names for user-facing summaries. When you explain results to the user, refer to chats by name, not by id. Use it as a narrow follow-up check, not as a complete overview of recent conversations.",
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
            let since = arguments?["since"]?.stringValue ?? defaultSince
            let formatStr = arguments?["format"]?.stringValue ?? "summary"
            let limit = Self.limit.read(arguments)
            let includeFiltered = arguments?["include_filtered"]?.boolValue ?? false
            let cursor = arguments?["cursor"]?.stringValue

            let format = UnreadFormat(rawValue: formatStr) ?? .summary
            let params = Parameters(
                chatId: chatId,
                since: since,
                format: format,
                limit: limit,
                includeFiltered: includeFiltered,
                cursor: cursor
            )

            let tool = GetUnread(database: db, contactResolver: resolver)
            let result = try await tool.execute(params: params)
            return [.plainText(try FormatUtils.encodeJSON(result))]
        }
    }

    struct Parameters {
        var chatId: String?
        var since: String
        var format: UnreadFormat
        var limit: Int
        var includeFiltered: Bool
        var cursor: String?

        init(
            chatId: String? = nil,
            since: String = GetUnread.defaultSince,
            format: UnreadFormat = .summary,
            limit: Int = GetUnread.limit.defaultValue,
            includeFiltered: Bool = false,
            cursor: String? = nil
        ) {
            self.chatId = chatId
            self.since = since
            self.format = format
            self.limit = GetUnread.limit.clamp(limit)
            self.includeFiltered = includeFiltered
            self.cursor = cursor
        }
    }

    func execute(params: Parameters) async throws -> any Encodable {
        var sinceApple: Int64?
        if params.since.lowercased() != "all" {
            sinceApple = AppleTime.parse(params.since)
        }

        let scope = ChatScope(
            named: try params.chatId.map { try ChatIdentifier.resolve($0, db: database) },
            includeFiltered: params.includeFiltered
        )

        switch params.format {
        case .summary:
            return try await getUnreadSummary(scope: scope, sinceApple: sinceApple, limit: params.limit)
        case .messages:
            return try await getUnreadMessages(
                scope: scope,
                sinceApple: sinceApple,
                limit: params.limit,
                cursor: params.cursor.flatMap(TimelineCursor.decode)
            )
        }
    }

    private static func unread(
        _ query: QueryBuilder,
        scope: ChatScope,
        sinceApple: Int64?
    ) -> QueryBuilder {
        scope.read(query)
        query.where(SQLFragments.unreadInbound())
        if let sinceApple {
            query.where("m.date >= ?", sinceApple)
        }
        return query
    }

    private func getUnreadMessages(
        scope: ChatScope,
        sinceApple: Int64?,
        limit: Int,
        cursor: TimelineCursor?
    ) async throws -> UnreadMessagesResponse {
        let query = Self.unread(
            QueryBuilder().selectMessages(try database.schema(), MessageInChat.chatColumns),
            scope: scope,
            sinceApple: sinceApple
        )
        .joinMessageHandles()
        if let after = cursor?.predicate(descending: false) {
            query.where(after.sql, params: after.params)
        }
        let (sql, params) = query
            .orderBy("m.date ASC", "m.ROWID ASC")
            .limit(limit + 1)
            .build()

        let fetched = try database.query(sql, params: params, map: MessageInChat.init)
        let rows = Array(fetched.prefix(limit))
        let nextCursor = TimelineCursor.next(after: rows.last?.message, pageFull: fetched.count > limit)

        let counts = try getUnreadCounts(scope: scope, sinceApple: sinceApple)
        let filteredHidden = try scope.filteredHidden(firstPage: cursor == nil) {
            try getFilteredHiddenCount(sinceApple: sinceApple)
        }

        let chatByID = try await ChatReferences(rows.chats, db: database, resolver: contactResolver)
        let renderer = MessageRenderer(
            annotations: .none,
            labels: await SenderLabels.displayNames(
                me: "Me", unknown: "Unknown", for: rows.map(\.message), resolver: contactResolver
            )
        )

        let unreadMessages = rows.map { row in
            let message = renderer.render(row.message)
            return UnreadMessageItem(
                id: message.id,
                chat: chatByID[row.chatId],
                from: message.from,
                text: message.text,
                ago: message.ago,
                ts: message.ts
            )
        }

        return UnreadMessagesResponse(
            messages: unreadMessages,
            totalUnread: counts.totalUnread,
            chatsWithUnread: counts.chatsWithUnread,
            more: nextCursor != nil,
            cursor: nextCursor,
            filteredHidden: filteredHidden
        )
    }

    private func getUnreadSummary(
        scope: ChatScope,
        sinceApple: Int64?,
        limit: Int
    ) async throws -> UnreadSummaryResponse {
        let (sql, params) = Self.unread(
            QueryBuilder().select(
                "c.ROWID",
                "c.display_name as chat_display_name",
                "COUNT(*) as unread_count",
                "MIN(m.date) as oldest_unread_date",
                "MAX(m.date) as newest_unread_date"
            ),
            scope: scope,
            sinceApple: sinceApple
        )
        .groupBy("c.ROWID")
        .orderBy("unread_count DESC", "newest_unread_date DESC", "c.ROWID DESC")
        .limit(limit + 1)
        .build()

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

        let page = try await ChatPage.build(
            rows.map { ChatPage.Chat(id: $0.chatId, explicitName: $0.chatDisplayName, newestDate: $0.newestUnreadDate) },
            lastMessages: ChatPage.LastMessageOptions(
                sinceApple: sinceApple,
                unknownSenderLabel: "Unknown",
                agoFallback: nil,
                onlyUnreadInbound: true
            ),
            db: database,
            resolver: contactResolver
        )
        let chats = rows.compactMap { row -> UnreadChatSummary? in
            guard let entry = page[row.chatId] else { return nil }
            return UnreadChatSummary(
                chat: entry.summary,
                unreadCount: row.unreadCount,
                oldestUnread: TimeUtils.formatCompactRelative(AppleTime.toDate(row.oldestUnreadDate)),
                lastMessage: entry.lastMessage?.info
            )
        }

        let counts = try getUnreadCounts(scope: scope, sinceApple: sinceApple)
        let filteredHidden = try scope.filteredHidden {
            try getFilteredHiddenCount(sinceApple: sinceApple)
        }

        return UnreadSummaryResponse(
            chats: chats,
            totalUnread: counts.totalUnread,
            chatsWithUnread: counts.chatsWithUnread,
            more: more,
            filteredHidden: filteredHidden
        )
    }

    private func getUnreadCounts(
        scope: ChatScope,
        sinceApple: Int64?
    ) throws -> (totalUnread: Int, chatsWithUnread: Int) {
        let (sql, params) = Self.unread(
            QueryBuilder().select(
                "COUNT(*) as total_unread",
                "COUNT(DISTINCT c.ROWID) as chats_with_unread"
            ),
            scope: scope,
            sinceApple: sinceApple
        ).build()

        let rows: [(Int, Int)] = try database.query(sql, params: params) { row in
            (Int(row.int(0)), Int(row.int(1)))
        }
        return rows.first ?? (0, 0)
    }

    private func getFilteredHiddenCount(sinceApple: Int64?) throws -> Int {
        let query = QueryBuilder()
            .select("COUNT(DISTINCT cmj.chat_id)")
            .from("message m")
            .join("chat_message_join cmj ON m.ROWID = cmj.message_id")
            .join("chat c ON cmj.chat_id = c.ROWID")
            .where(SQLFragments.unreadInbound())
            .where(SQLFragments.hiddenChat())
        if let sinceApple {
            query.where("m.date >= ?", sinceApple)
        }
        let (sql, params) = query.build()
        let rows: [Int] = try database.query(sql, params: params) { row in
            Int(row.int(0))
        }
        return rows.first ?? 0
    }

}

private struct SummaryRow {
    let chatId: Int64
    let chatDisplayName: String?
    let unreadCount: Int
    let oldestUnreadDate: Int64?
    let newestUnreadDate: Int64?
}

