// Sources/iMessageMax/Tools/GetActiveConversations.swift
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
    // MARK: - Tool Registration

    static func definition(db: Database, resolver: ContactResolver) -> ToolDefinition {
        let inputSchema: Value = .object([
            "type": "object",
            "properties": .object([
                "hours": .object([
                    "type": "integer",
                    "description": "Time window to consider for recent activity (default 24, max 168 = 1 week)",
                ]),
                "min_exchanges": .object([
                    "type": "integer",
                    "description": "Minimum back-and-forth exchanges to qualify as active (default 2)",
                ]),
                "is_group": .object([
                    "type": "boolean",
                    "description": "True for groups only, False for DMs only",
                ]),
                "limit": .object([
                    "type": "integer",
                    "description": "Max recent active conversations to return (default 10, max 50)",
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
            let hours = arguments?["hours"]?.intValue ?? 24
            let minExchanges = arguments?["min_exchanges"]?.intValue ?? 2
            let isGroup = arguments?["is_group"]?.boolValue
            let limit = arguments?["limit"]?.intValue ?? 10

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
        hours: Int = 24,
        minExchanges: Int = 2,
        isGroup: Bool? = nil,
        limit: Int = 10,
        database: Database,
        resolver: ContactResolver
    ) async throws -> ActiveConversationsResult {
        let clampedHours = max(1, min(hours, 168))  // 1 hour to 1 week
        let clampedMinExchanges = max(1, min(minExchanges, 100))
        let clampedLimit = max(1, min(limit, 50))

        let now = Date()
        let windowStart = now.addingTimeInterval(-Double(clampedHours) * Seconds.hour)
        let windowStartApple = AppleTime.fromDate(windowStart)

        let query = QueryBuilder()
            .select(
                "c.ROWID as chat_id",
                "c.display_name",
                "\(SQLFragments.participantCount()) as participant_count",
                "SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) as my_count",
                "SUM(CASE WHEN m.is_from_me = 0 THEN 1 ELSE 0 END) as their_count",
                "MAX(CASE WHEN m.is_from_me = 1 THEN m.date ELSE NULL END) as last_from_me",
                "MAX(CASE WHEN m.is_from_me = 0 THEN m.date ELSE NULL END) as last_from_them",
                "MIN(m.date) as first_in_window",
                "MAX(m.date) as last_in_window"
            )
            .from("chat c")
            .join("chat_message_join cmj ON c.ROWID = cmj.chat_id")
            .join("message m ON cmj.message_id = m.ROWID")
            .where("m.date >= ?", windowStartApple)
            .where(SQLFragments.notReaction())
            .groupBy("c.ROWID")
            .having("my_count >= 1 AND their_count >= 1")
        if let filterGroup = isGroup {
            query.having(filterGroup ? "participant_count > 1" : "participant_count <= 1")
        }
        // Fetch more than limit to account for filtering
        let fetchLimit = clampedLimit * 3
        query.orderBy("last_in_window DESC").limit(fetchLimit)
        let (sql, params) = query.build()

        let chatRows = try database.query(sql, params: params) { row -> ChatActivityRow in
            ChatActivityRow(
                chatId: row.int(0),
                displayName: row.string(1),
                participantCount: Int(row.int(2)),
                myCount: Int(row.int(3)),
                theirCount: Int(row.int(4)),
                lastFromMe: row.optionalInt(5),
                lastFromThem: row.optionalInt(6),
                firstInWindow: row.optionalInt(7),
                lastInWindow: row.optionalInt(8)
            )
        }

        // Apply min_exchanges and the limit first so the batched lookups
        // cover exactly the chats returned.
        var includedRows: [ChatActivityRow] = []
        for row in chatRows {
            guard includedRows.count < clampedLimit else { break }
            guard min(row.myCount, row.theirCount) >= clampedMinExchanges else { continue }
            includedRows.append(row)
        }

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
                    awaitingReply: row.lastFromThem.map { $0 > (row.lastFromMe ?? .min) } ?? false,
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
            // Cursor pagination not implemented; never advertise more pages.
            more: false,
            cursor: nil
        )
    }

    // MARK: - Private Helpers

    private struct ChatActivityRow {
        let chatId: Int64
        let displayName: String?
        let participantCount: Int
        let myCount: Int
        let theirCount: Int
        let lastFromMe: Int64?
        let lastFromThem: Int64?
        let firstInWindow: Int64?
        let lastInWindow: Int64?
    }

}
