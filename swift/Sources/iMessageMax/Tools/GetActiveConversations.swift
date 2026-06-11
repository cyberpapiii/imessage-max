// Sources/iMessageMax/Tools/GetActiveConversations.swift
import Foundation
import MCP

/// Result type for get_active_conversations tool
struct ActiveConversationsResult: Codable {
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

/// A conversation with bidirectional activity
struct ActiveConversation: Codable {
    let id: String
    let name: String
    let group: Bool?
    let participantCount: Int
    let participantsPreview: [String]
    let lastMessage: LastMessageSummary?
    let awaitingReply: Bool
    let activity: ConversationActivity

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case group
        case participantCount = "participant_count"
        case participantsPreview = "participants_preview"
        case lastMessage = "last_message"
        case awaitingReply = "awaiting_reply"
        case activity
    }
}

/// Activity metrics within the time window
struct ConversationActivity: Codable {
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

/// Error result for get_active_conversations
struct ActiveConversationsError: Codable {
    let error: String
    let message: String
}

enum GetActiveConversations {
    // MARK: - Tool Registration

    static func register(on server: Server, db: Database, resolver: ContactResolver) {
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

        server.registerTool(
            name: "get_active_conversations",
            description: "Find conversations with recent bidirectional activity. Returns chat ids for follow-up tool calls and chat names for user-facing summaries. When explaining results to the user, refer to chats by name, not by id. Helpful for surfacing threads that may deserve attention first, but not a complete recent overview across all chats.",
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

            do {
                let result = try await execute(
                    hours: hours,
                    minExchanges: minExchanges,
                    isGroup: isGroup,
                    limit: limit,
                    database: db,
                    resolver: resolver
                )

                return [.plainText(try FormatUtils.encodeJSON(result))]
            } catch {
                let errorResponse = ActiveConversationsError(
                    error: "execution_error",
                    message: error.localizedDescription
                )
                throw ToolError(content: [.plainText(try FormatUtils.encodeJSON(errorResponse))])
            }
        }
    }

    /// Find conversations with recent bidirectional activity
    ///
    /// - Parameters:
    ///   - hours: Time window to consider (default 24, max 168 = 1 week)
    ///   - minExchanges: Minimum back-and-forth exchanges to qualify (default 2)
    ///   - isGroup: true for groups only, false for DMs only, nil for both
    ///   - limit: Max results (default 10, max 50)
    ///   - database: Database instance
    ///   - resolver: ContactResolver for name lookups
    /// - Returns: ActiveConversationsResult or throws an error
    static func execute(
        hours: Int = 24,
        minExchanges: Int = 2,
        isGroup: Bool? = nil,
        limit: Int = 10,
        database: Database = Database(),
        resolver: ContactResolver
    ) async throws -> ActiveConversationsResult {
        // Validate and clamp inputs
        let clampedHours = max(1, min(hours, 168))  // 1 hour to 1 week
        let clampedMinExchanges = max(1, min(minExchanges, 100))
        let clampedLimit = max(1, min(limit, 50))

        // Calculate window start timestamp
        let now = Date()
        let windowStart = now.addingTimeInterval(-Double(clampedHours) * 3600)
        let windowStartApple = AppleTime.fromDate(windowStart)

        // Initialize resolver
        try await resolver.initialize()

        // Build query for chats with bidirectional activity
        var sql = """
            SELECT
                c.ROWID as chat_id,
                c.display_name,
                COUNT(DISTINCT chj.handle_id) as participant_count,
                SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) as my_count,
                SUM(CASE WHEN m.is_from_me = 0 THEN 1 ELSE 0 END) as their_count,
                MAX(CASE WHEN m.is_from_me = 1 THEN m.date ELSE NULL END) as last_from_me,
                MAX(CASE WHEN m.is_from_me = 0 THEN m.date ELSE NULL END) as last_from_them,
                MIN(m.date) as first_in_window,
                MAX(m.date) as last_in_window
            FROM chat c
            LEFT JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
            JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
            JOIN message m ON cmj.message_id = m.ROWID
            WHERE m.date >= ?
            AND m.associated_message_type = 0
            GROUP BY c.ROWID
            HAVING my_count >= 1 AND their_count >= 1
            """

        var params: [Any] = [windowStartApple]

        // Apply group filter
        if let filterGroup = isGroup {
            if filterGroup {
                sql += " AND participant_count > 1"
            } else {
                sql += " AND participant_count <= 1"
            }
        }

        sql += " ORDER BY last_in_window DESC"

        // Fetch more than limit to account for filtering
        let fetchLimit = clampedLimit * 3
        sql += " LIMIT ?"
        params.append(fetchLimit)

        // Execute main query
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

        // Pre-filter: same inclusion logic as the original loop (min-exchanges
        // filter, then cap at clampedLimit) so the batched queries cover
        // exactly the chats that will appear in the response.
        var includedRows: [ChatActivityRow] = []
        for row in chatRows {
            guard includedRows.count < clampedLimit else { break }
            guard min(row.myCount, row.theirCount) >= clampedMinExchanges else { continue }
            includedRows.append(row)
        }

        // Batch-fetch participants and last previews for all included chats.
        let chatIds = includedRows.map(\.chatId)
        let participantsByChat = try await ChatSummaryQueries.participantsByChat(
            db: database,
            chatIds: chatIds,
            resolver: resolver
        )
        let lastMessagesByChat = try await ChatSummaryQueries.lastMessagesByChat(
            db: database,
            chatIds: chatIds,
            resolver: resolver,
            sinceApple: windowStartApple,
            previewMaxLength: 80,
            unknownSenderLabel: "Unknown",
            agoFallback: nil
        )

        var conversations: [ActiveConversation] = []

        for row in includedRows {
            // Calculate exchanges (min of my and their messages)
            let exchanges = min(row.myCount, row.theirCount)

            let participantRows = participantsByChat[row.chatId] ?? []

            let identity = ChatIdentity(
                mcpId: "chat\(row.chatId)",
                guid: nil,
                explicitName: row.displayName,
                participants: participantRows.map {
                    ChatIdentity.makeParticipant(handle: $0.handle, contactName: $0.name)
                }
            )

            // Determine awaiting reply
            let awaitingReply: Bool
            if let lastFromThem = row.lastFromThem, let lastFromMe = row.lastFromMe {
                awaitingReply = lastFromThem > lastFromMe
            } else if row.lastFromThem != nil && row.lastFromMe == nil {
                awaitingReply = true
            } else {
                awaitingReply = false
            }

            let activity = ConversationActivity(
                exchanges: exchanges,
                myMsgs: row.myCount,
                theirMsgs: row.theirCount,
                lastFromMe: formatTimestamp(row.lastFromMe),
                lastFromThem: formatTimestamp(row.lastFromThem),
                started: formatTimestamp(row.firstInWindow)
            )

            let lastPreview = lastMessagesByChat[row.chatId]?.info

            let conversation = ActiveConversation(
                id: identity.mcpId,
                name: identity.displayName,
                group: identity.participantCount > 1 ? true : nil,
                participantCount: identity.participantCount,
                participantsPreview: try ChatSummaryBuilder.participantsPreview(
                    db: database,
                    chatId: row.chatId,
                    identity: identity
                ),
                lastMessage: lastPreview,
                awaitingReply: awaitingReply,
                activity: activity
            )

            conversations.append(conversation)
        }

        return ActiveConversationsResult(
            conversations: conversations,
            total: conversations.count,
            windowHours: clampedHours,
            more: conversations.count >= clampedLimit,
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

    private static func formatTimestamp(_ appleTimestamp: Int64?) -> String? {
        guard let ts = appleTimestamp,
              let date = AppleTime.toDate(ts) else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
