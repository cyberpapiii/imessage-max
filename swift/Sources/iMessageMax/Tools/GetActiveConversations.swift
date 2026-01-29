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
    let people: PeopleMap?

    enum CodingKeys: String, CodingKey {
        case conversations
        case total
        case windowHours = "window_hours"
        case more
        case cursor
        case people
    }
}

/// A conversation with bidirectional activity
struct ActiveConversation: Codable {
    let id: String
    let name: String
    let participants: [ParticipantRef]
    let activity: ConversationActivity
    let awaitingReply: Bool
    let group: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case participants
        case activity
        case awaitingReply = "awaiting_reply"
        case group
    }
}

/// Compact participant reference for responses
struct ParticipantRef: Codable {
    let name: String
    let handle: String
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
                    "description": "Time window to consider (default 24, max 168 = 1 week)",
                ]),
                "min_exchanges": .object([
                    "type": "integer",
                    "description": "Minimum back-and-forth exchanges to qualify (default 2)",
                ]),
                "is_group": .object([
                    "type": "boolean",
                    "description": "True for groups only, False for DMs only",
                ]),
                "limit": .object([
                    "type": "integer",
                    "description": "Max results (default 10, max 50)",
                ]),
            ]),
            "additionalProperties": false,
        ])

        server.registerTool(
            name: "get_active_conversations",
            description: "Find conversations with recent bidirectional activity. Returns chats where both parties have exchanged messages within the time window.",
            inputSchema: inputSchema,
            annotations: Tool.Annotations(
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

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let json = try encoder.encode(result)
                return [.text(String(data: json, encoding: .utf8) ?? "{}")]
            } catch {
                let errorResponse = ActiveConversationsError(
                    error: "execution_error",
                    message: error.localizedDescription
                )
                let encoder = JSONEncoder()
                let json = try encoder.encode(errorResponse)
                return [.text(String(data: json, encoding: .utf8) ?? "{}")]
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
        var peopleMap: PeopleMap = [:]

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

            var participantRefs: [ParticipantRef] = []
            for p in participantRows {
                let displayName = p.name ?? PhoneUtils.formatDisplay(p.handle)
                participantRefs.append(ParticipantRef(name: displayName, handle: p.handle))

                // Add to people map
                let key = "p\(peopleMap.count)"
                peopleMap[key] = p
            }

            // Generate display name if not set
            let chatDisplayName = row.displayName ?? generateDisplayName(from: participantRows)
            let isGroupChat = row.participantCount > 1

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

            let conversation = ActiveConversation(
                id: "chat\(row.chatId)",
                name: chatDisplayName,
                participants: participantRefs,
                activity: activity,
                awaitingReply: awaitingReply,
                group: isGroupChat ? true : nil
            )

            conversations.append(conversation)
        }

        return ActiveConversationsResult(
            conversations: conversations,
            total: conversations.count,
            windowHours: clampedHours,
            more: conversations.count >= clampedLimit,
            cursor: nil,
            people: peopleMap.isEmpty ? nil : peopleMap
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

    private static func generateDisplayName(from participants: [Participant]) -> String {
        let names = participants.map { p in
            p.name ?? PhoneUtils.formatDisplay(p.handle)
        }

        switch names.count {
        case 0:
            return "Unknown"
        case 1...4:
            return names.joined(separator: ", ")
        default:
            let first3 = names.prefix(3).joined(separator: ", ")
            let remaining = names.count - 3
            return "\(first3) and \(remaining) others"
        }
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
