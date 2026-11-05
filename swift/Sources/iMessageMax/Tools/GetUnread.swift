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
    /// Matches the window Messages.app treats as recent.
    static let defaultSince = "7d"

    private let database: Database
    private let contactResolver: ContactResolver

    init(database: Database, contactResolver: ContactResolver) {
        self.database = database
        self.contactResolver = contactResolver
    }

    // MARK: - Tool Registration

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
                    "description": "Time window for unread-only results (default \"\(defaultSince)\", use \"all\" for all time)",
                ]),
                "format": .object([
                    "type": "string",
                    "description": "Response format for unread data (default summary)",
                    "enum": ["messages", "summary"],
                ]),
                "limit": .object([
                    "type": "integer",
                    "description": "Max messages (\(Self.limit.defaultAndMax))",
                ]),
                "include_filtered": .object([
                    "type": "boolean",
                    "description": "Include chats Messages.app has filtered as junk or unknown senders (default false)",
                ]),
            ]),
            "additionalProperties": false,
        ])

        return ToolDefinition(
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
            let since = arguments?["since"]?.stringValue ?? defaultSince
            let formatStr = arguments?["format"]?.stringValue ?? "summary"
            let limit = Self.limit.read(arguments)
            let includeFiltered = arguments?["include_filtered"]?.boolValue ?? false

            let format = UnreadFormat(rawValue: formatStr) ?? .summary
            let params = Parameters(
                chatId: chatId,
                since: since,
                format: format,
                limit: limit,
                includeFiltered: includeFiltered
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

        init(
            chatId: String? = nil,
            since: String = GetUnread.defaultSince,
            format: UnreadFormat = .summary,
            limit: Int = GetUnread.limit.defaultValue,
            includeFiltered: Bool = false
        ) {
            self.chatId = chatId
            self.since = since
            self.format = format
            self.limit = GetUnread.limit.clamp(limit)
            self.includeFiltered = includeFiltered
        }
    }

    func execute(params: Parameters) async throws -> any Encodable {

        // "all" means no time filter
        var sinceApple: Int64?
        if params.since.lowercased() != "all" {
            sinceApple = AppleTime.parse(params.since)
        }

        var numericChatId: Int64?
        if let chatId = params.chatId {
            numericChatId = ChatIdentifier.parseRowId(chatId)
            if numericChatId == nil {
                throw ToolFailure.chatNotFound(chatId)
            }
        }

        switch params.format {
        case .summary:
            return try await getUnreadSummary(
                chatId: numericChatId,
                sinceApple: sinceApple,
                limit: params.limit,
                includeFiltered: params.includeFiltered
            )
        case .messages:
            return try await getUnreadMessages(
                chatId: numericChatId,
                sinceApple: sinceApple,
                limit: params.limit,
                includeFiltered: params.includeFiltered
            )
        }
    }

    // MARK: - Private Methods

    /// Unread inbound messages and their chats, narrowed by the tool's
    /// filters. `chats` is the shown/hidden chat predicate, nil for all.
    private static func unread(
        _ query: QueryBuilder,
        chatId: Int64?,
        sinceApple: Int64?,
        chats: String?
    ) -> QueryBuilder {
        query
            .from("message m")
            .join("chat_message_join cmj ON m.ROWID = cmj.message_id")
            .join("chat c ON cmj.chat_id = c.ROWID")
            .where(SQLFragments.unreadInbound())
        if let chats {
            query.where(chats)
        }
        if let sinceApple {
            query.where("m.date >= ?", sinceApple)
        }
        if let chatId {
            query.where("cmj.chat_id = ?", chatId)
        }
        return query
    }

    private static func shownChats(_ includeFiltered: Bool) -> String? {
        includeFiltered ? nil : SQLFragments.shownChat()
    }

    private func getUnreadMessages(
        chatId: Int64?,
        sinceApple: Int64?,
        limit: Int,
        includeFiltered: Bool
    ) async throws -> UnreadMessagesResponse {
        let (sql, params) = Self.unread(
            QueryBuilder().selectMessages(try database.schema(), MessageInChat.chatColumns),
            chatId: chatId,
            sinceApple: sinceApple,
            chats: Self.shownChats(includeFiltered)
        )
        .joinMessageHandles()
        .orderBy("m.date ASC", "m.ROWID ASC")
        .limit(limit + 1)
        .build()

        var rows = try database.query(sql, params: params, map: MessageInChat.init)
        let more = rows.count > limit
        if more {
            rows = Array(rows.prefix(limit))
        }

        let counts = try getUnreadCounts(chatId: chatId, sinceApple: sinceApple, includeFiltered: includeFiltered)
        let filteredHidden = includeFiltered
            ? nil
            : try getFilteredHiddenCount(chatId: chatId, sinceApple: sinceApple)

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
            // Pagination is by limit only (no cursor); more reports truncation honestly.
            more: more,
            cursor: nil,
            filteredHidden: filteredHidden
        )
    }

    private func getUnreadSummary(
        chatId: Int64?,
        sinceApple: Int64?,
        limit: Int,
        includeFiltered: Bool
    ) async throws -> UnreadSummaryResponse {
        let (sql, params) = Self.unread(
            QueryBuilder().select(
                "cmj.chat_id",
                "c.display_name as chat_display_name",
                "COUNT(*) as unread_count",
                "MIN(m.date) as oldest_unread_date",
                // Free alongside the MIN, and it saves the preview lookup from
                // searching each chat's history for the message it names.
                "MAX(m.date) as newest_unread_date"
            ),
            chatId: chatId,
            sinceApple: sinceApple,
            chats: Self.shownChats(includeFiltered)
        )
        .groupBy("cmj.chat_id")
        .orderBy("unread_count DESC", "newest_unread_date DESC", "cmj.chat_id DESC")
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

        // Totals cover every unread chat, not just this page, as in the
        // messages format.
        let counts = try getUnreadCounts(chatId: chatId, sinceApple: sinceApple, includeFiltered: includeFiltered)
        let filteredHidden = includeFiltered
            ? nil
            : try getFilteredHiddenCount(chatId: chatId, sinceApple: sinceApple)

        return UnreadSummaryResponse(
            chats: chats,
            totalUnread: counts.totalUnread,
            chatsWithUnread: counts.chatsWithUnread,
            more: more,
            filteredHidden: filteredHidden
        )
    }

    private func getUnreadCounts(
        chatId: Int64?,
        sinceApple: Int64?,
        includeFiltered: Bool
    ) throws -> (totalUnread: Int, chatsWithUnread: Int) {
        let (sql, params) = Self.unread(
            QueryBuilder().select(
                "COUNT(DISTINCT m.ROWID) as total_unread",
                "COUNT(DISTINCT cmj.chat_id) as chats_with_unread"
            ),
            chatId: chatId,
            sinceApple: sinceApple,
            chats: Self.shownChats(includeFiltered)
        ).build()

        let rows: [(Int, Int)] = try database.query(sql, params: params) { row in
            (Int(row.int(0)), Int(row.int(1)))
        }
        return rows.first ?? (0, 0)
    }

    private func getFilteredHiddenCount(
        chatId: Int64?,
        sinceApple: Int64?
    ) throws -> Int {
        let (sql, params) = Self.unread(
            QueryBuilder().select("COUNT(DISTINCT cmj.chat_id)"),
            chatId: chatId,
            sinceApple: sinceApple,
            chats: SQLFragments.hiddenChat()
        ).build()
        let rows: [Int] = try database.query(sql, params: params) { row in
            Int(row.int(0))
        }
        return rows.first ?? 0
    }

}

// MARK: - Helper Types

private struct SummaryRow {
    let chatId: Int64
    let chatDisplayName: String?
    let unreadCount: Int
    let oldestUnreadDate: Int64?
    let newestUnreadDate: Int64?
}

