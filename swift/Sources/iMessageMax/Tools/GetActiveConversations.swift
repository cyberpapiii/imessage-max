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

        var conversations: [ActiveConversation] = []

        for row in chatRows {
            guard conversations.count < clampedLimit else { break }

            // Calculate exchanges (min of my and their messages)
            let exchanges = min(row.myCount, row.theirCount)

            // Filter by minimum exchanges
            guard exchanges >= clampedMinExchanges else { continue }

            // Get participants for this chat
            let participantRows = try await getParticipants(
                chatId: row.chatId,
                database: database,
                resolver: resolver
            )

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

            let lastPreview = try await getLastPreview(
                chatId: row.chatId,
                windowStartApple: windowStartApple,
                database: database,
                resolver: resolver
            )

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

    private struct LastPreviewRow {
        let msgId: Int64
        let text: String?
        let attributedBody: Data?
        let date: Int64?
        let isFromMe: Bool
        let senderHandle: String?
    }

    private static func getParticipants(
        chatId: Int64,
        database: Database,
        resolver: ContactResolver
    ) async throws -> [Participant] {
        let sql = """
            SELECT h.id as handle, h.service
            FROM handle h
            JOIN chat_handle_join chj ON h.ROWID = chj.handle_id
            WHERE chj.chat_id = ?
            """

        let rows = try database.query(sql, params: [chatId]) { row in
            (handle: row.string(0) ?? "", service: row.string(1))
        }

        var participants: [Participant] = []
        for row in rows {
            let name = await resolver.resolve(row.handle)
            participants.append(Participant(
                handle: row.handle,
                name: name,
                service: row.service,
                inContacts: name != nil
            ))
        }

        return participants
    }

    private static func getLastPreview(
        chatId: Int64,
        windowStartApple: Int64,
        database: Database,
        resolver: ContactResolver
    ) async throws -> LastMessageSummary? {
        let sql = """
            SELECT m.ROWID, m.text, m.attributedBody, m.date, m.is_from_me, h.id as sender_handle
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE cmj.chat_id = ?
            AND m.date >= ?
            AND m.associated_message_type = 0
            ORDER BY m.date DESC
            LIMIT 1
            """

        let rows = try database.query(sql, params: [chatId, windowStartApple]) { row in
            LastPreviewRow(
                msgId: row.int(0),
                text: row.string(1),
                attributedBody: row.blob(2),
                date: row.optionalInt(3),
                isFromMe: row.int(4) == 1,
                senderHandle: row.string(5)
            )
        }

        guard let row = rows.first else { return nil }

        let from: String
        if row.isFromMe {
            from = "Me"
        } else if let handle = row.senderHandle {
            from = await IdentityDisplayFormatter.displayName(handle: handle, resolver: resolver)
        } else {
            from = "Unknown"
        }

        let previewText = try await formatPreviewText(
            messageId: row.msgId,
            text: row.text,
            attributedBody: row.attributedBody,
            database: database
        )

        let date = AppleTime.toDate(row.date)
        return LastMessageSummary(
            from: from,
            text: previewText,
            ago: TimeUtils.formatCompactRelative(date),
            ts: TimeUtils.formatISO(date)
        )
    }

    private static func formatPreviewText(
        messageId: Int64,
        text: String?,
        attributedBody: Data?,
        database: Database
    ) async throws -> String {
        try MessagePreviewResolver.messageSummary(
            db: database,
            messageId: messageId,
            text: text,
            attributedBody: attributedBody,
            maxLength: 80
        )
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
