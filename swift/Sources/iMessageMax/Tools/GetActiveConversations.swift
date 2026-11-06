import Foundation
import MCP

struct ActiveConversationsResult: Encodable {
    let conversations: [ActiveConversation]
    let total: Int
    let windowHours: Int
    let more: Bool
    let cursor: String?

    enum CodingKeys: String, CodingKey {
        case conversations
        case total
        case windowHours = "window_hours"
        case more
        case cursor
    }
}

typealias ActiveConversation = ChatListing<ActiveConversationDetails>

struct ActiveConversationDetails: Encodable {
    let lastMessage: LastMessageSummary?
    let awaitingReply: Bool
    let activity: ConversationActivity

    enum CodingKeys: String, CodingKey {
        case lastMessage = "last_message"
        case awaitingReply = "awaiting_reply"
        case activity
    }
}

struct ConversationActivity: Encodable {
    let exchanges: Int
    let myMsgs: Int
    let theirMsgs: Int
    let lastFromMe: String?
    let lastFromThem: String?
    let started: String?

    enum CodingKeys: String, CodingKey {
        case exchanges
        case myMsgs = "my_msgs"
        case theirMsgs = "their_msgs"
        case lastFromMe = "last_from_me"
        case lastFromThem = "last_from_them"
        case started
    }
}

enum GetActiveConversations {
    static let hours = IntArgument(name: "hours", defaultValue: 24, range: 1...168)
    static let minExchanges = IntArgument(name: "min_exchanges", defaultValue: 2, range: 1...100)
    static let limit = IntArgument(name: "limit", defaultValue: 10, range: 1...50)

    // MARK: - Tool Registration

    static func definition(db: Database, resolver: ContactResolver) -> ToolDefinition {
        let inputSchema: Value = .object([
            "type": "object",
            "properties": .object([
                "hours": .object([
                    "type": "integer",
                    "description": "Time window to consider for recent activity (\(hours.defaultAndMax) = 1 week)",
                ]),
                "min_exchanges": .object([
                    "type": "integer",
                    "description": "Minimum back-and-forth exchanges to qualify as active (default \(minExchanges.defaultValue))",
                ]),
                "is_group": .object([
                    "type": "boolean",
                    "description": "True for groups only, False for DMs only",
                ]),
                "limit": .object([
                    "type": "integer",
                    "description": "Max recent active conversations to return (\(limit.defaultAndMax))",
                ]),
            ]),
            "additionalProperties": false,
        ])

        return ToolDefinition(
            name: "get_active_conversations",
            description: "Find conversations with recent bidirectional activity. Returns chat ids for follow-up tool calls and chat names for user-facing summaries. When explaining results to the user, refer to chats by name, not by id. Use it to find threads that deserve attention first. It is not a complete recent overview across all chats; use list_chats for that.",
            inputSchema: inputSchema,
            outputSchema: OutputSchema.object,
            annotations: Tool.Annotations(
                title: "Get Active Conversations",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let hours = Self.hours.read(arguments)
            let minExchanges = Self.minExchanges.read(arguments)
            let isGroup = arguments?["is_group"]?.boolValue
            let limit = Self.limit.read(arguments)

            let result = try await execute(
                hours: hours,
                minExchanges: minExchanges,
                isGroup: isGroup,
                limit: limit,
                database: db,
                resolver: resolver
            )
            return [.plainText(try FormatUtils.encodeJSON(result))]
        }
    }

    static func execute(
        hours: Int = GetActiveConversations.hours.defaultValue,
        minExchanges: Int = GetActiveConversations.minExchanges.defaultValue,
        isGroup: Bool? = nil,
        limit: Int = GetActiveConversations.limit.defaultValue,
        database: Database,
        resolver: ContactResolver
    ) async throws -> ActiveConversationsResult {
        let clampedHours = Self.hours.clamp(hours)
        let clampedMinExchanges = Self.minExchanges.clamp(minExchanges)
        let clampedLimit = Self.limit.clamp(limit)

        let now = Date()
        let windowStart = now.addingTimeInterval(-Double(clampedHours) * Seconds.hour)
        let windowStartApple = AppleTime.fromDate(windowStart)

        let conversational = SQLFragments.conversational()
        // No include_filtered: hidden chats are always left out.
        let scope = ChatScope(named: nil, includeFiltered: false)
        let query = QueryBuilder()
            .select(
                "c.ROWID as chat_id",
                "c.display_name",
                "\(SQLFragments.participantCount()) as participant_count",
                // Group events (renames, joins, leaves) are no one's turn.
                "SUM(CASE WHEN m.is_from_me = 1 AND \(conversational) THEN 1 ELSE 0 END) as my_count",
                "SUM(CASE WHEN m.is_from_me = 0 AND \(conversational) THEN 1 ELSE 0 END) as their_count",
                "MAX(CASE WHEN m.is_from_me = 1 AND \(conversational) THEN m.date ELSE NULL END) as last_from_me",
                "MAX(CASE WHEN m.is_from_me = 0 AND \(conversational) THEN m.date ELSE NULL END) as last_from_them",
                "MIN(m.date) as first_in_window",
                "MAX(m.date) as last_in_window"
            )
            // CROSS JOIN pins SQLite's loop order to the window's messages by
            // date. With the hidden-chat predicate on c, the planner otherwise
            // walks every chat's whole history to satisfy GROUP BY c.ROWID.
            .from("""
                message m
                CROSS JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                CROSS JOIN chat c ON c.ROWID = cmj.chat_id
                """)
            .where("m.date >= ?", windowStartApple)
            .where(SQLFragments.notReaction())
            .where(scope.shownPredicate() ?? "1")
            .groupBy("c.ROWID")
            // An exchange needs a message each way, so the qualifying count
            // is the smaller side; minExchanges is at least 1.
            .having("my_count >= ? AND their_count >= ?", clampedMinExchanges, clampedMinExchanges)
        if let filterGroup = isGroup {
            query.having(filterGroup
                ? SQLFragments.isGroup(count: "participant_count")
                : SQLFragments.isDirect(count: "participant_count"))
        }
        // One row past the page says whether more chats qualify.
        query.orderBy("last_in_window DESC", "c.ROWID DESC").limit(clampedLimit + 1)
        let (sql, params) = query.build()

        let chatRows = try database.query(sql, params: params) { row -> ChatActivityRow in
            ChatActivityRow(
                chatId: row.int(0),
                displayName: row.string(1),
                myCount: Int(row.int(3)),
                theirCount: Int(row.int(4)),
                lastFromMe: row.optionalInt(5),
                lastFromThem: row.optionalInt(6),
                firstInWindow: row.optionalInt(7),
                lastInWindow: row.optionalInt(8)
            )
        }

        let includedRows = Array(chatRows.prefix(clampedLimit))

        // last_in_window is the newest qualifying date the activity query
        // already computed, which is exactly the message the preview wants.
        let page = try await ChatPage.build(
            includedRows.map { ChatPage.Chat(id: $0.chatId, explicitName: $0.displayName, newestDate: $0.lastInWindow) },
            lastMessages: ChatPage.LastMessageOptions(
                sinceApple: windowStartApple,
                previewMaxLength: 80,
                unknownSenderLabel: "Unknown",
                agoFallback: nil
            ),
            db: database,
            resolver: resolver
        )

        let conversations = includedRows.compactMap { row -> ActiveConversation? in
            guard let entry = page[row.chatId] else { return nil }
            let iso = { (date: Int64?) in date.flatMap(AppleTime.toDate).flatMap(TimeUtils.formatISO) }
            return ActiveConversation(
                chat: entry.summary,
                details: ActiveConversationDetails(
                    lastMessage: entry.lastMessage?.info,
                    awaitingReply: entry.lastMessage?.awaitingReply ?? false,
                    activity: ConversationActivity(
                        exchanges: min(row.myCount, row.theirCount),
                        myMsgs: row.myCount,
                        theirMsgs: row.theirCount,
                        lastFromMe: iso(row.lastFromMe),
                        lastFromThem: iso(row.lastFromThem),
                        started: iso(row.firstInWindow)
                    )
                )
            )
        }

        return ActiveConversationsResult(
            conversations: conversations,
            total: conversations.count,
            windowHours: clampedHours,
            // No cursor: more says raising limit would show more chats.
            more: chatRows.count > clampedLimit,
            cursor: nil
        )
    }

    // MARK: - Private Helpers

    private struct ChatActivityRow {
        let chatId: Int64
        let displayName: String?
        let myCount: Int
        let theirCount: Int
        let lastFromMe: Int64?
        let lastFromThem: Int64?
        let firstInWindow: Int64?
        let lastInWindow: Int64?
    }

}
