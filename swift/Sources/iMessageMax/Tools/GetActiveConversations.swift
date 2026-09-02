// Sources/iMessageMax/Tools/GetActiveConversations.swift
import Foundation
import MCP

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
            } catch let error as DatabaseError {
                let mapped = ToolErrorMapping.map(error, context: "get_active_conversations")
                let payload = ActiveConversationsError(error: mapped.code, message: mapped.message)
                throw ToolError(content: [.plainText(try FormatUtils.encodeJSON(payload))])
            } catch {
                let payload = ActiveConversationsError(
                    error: "internal_error",
                    message: ClientErrorMessages.sanitized(error)
                )
                throw ToolError(content: [.plainText(try FormatUtils.encodeJSON(payload))])
            }
        }
    }

    static func execute(
        hours: Int = 24,
        minExchanges: Int = 2,
        isGroup: Bool? = nil,
        limit: Int = 10,
        database: Database = Database(),
        resolver: ContactResolver
    ) async throws -> ActiveConversationsResult {
        let clampedHours = max(1, min(hours, 168))  // 1 hour to 1 week
        let clampedMinExchanges = max(1, min(minExchanges, 100))
        let clampedLimit = max(1, min(limit, 50))

        let now = Date()
        let windowStart = now.addingTimeInterval(-Double(clampedHours) * 3600)
        let windowStartApple = AppleTime.fromDate(windowStart)

        try await resolver.initialize()

        let query = QueryBuilder()
            .select(
                "c.ROWID as chat_id",
                "c.display_name",
                """
                (SELECT COUNT(DISTINCT chj.handle_id) FROM chat_handle_join chj
                 WHERE chj.chat_id = c.ROWID) as participant_count
                """,
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
            .where("m.associated_message_type = 0")
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
        // last_in_window is the newest qualifying date the activity query
        // already computed for each chat, which is exactly the message this
        // preview is looking for.
        var newestInWindow: [Int64: Int64] = [:]
        for row in includedRows {
            if let last = row.lastInWindow {
                newestInWindow[row.chatId] = last
            }
        }
        let lastMessagesByChat = try await ChatSummaryQueries.lastMessagesByChat(
            db: database,
            chatIds: chatIds,
            resolver: resolver,
            sinceApple: windowStartApple,
            previewMaxLength: 80,
            unknownSenderLabel: "Unknown",
            agoFallback: nil,
            newestDates: newestInWindow
        )
        let recentSenderChatIds = includedRows.compactMap { row -> Int64? in
            let trimmed = row.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isNamed = trimmed?.isEmpty == false
            let count = (participantsByChat[row.chatId] ?? []).count
            return (isNamed && count > 4) ? row.chatId : nil
        }
        let recentSendersByChat = try ChatSummaryQueries.recentSendersByChat(
            db: database,
            chatIds: recentSenderChatIds
        )

        var conversations: [ActiveConversation] = []

        for row in includedRows {
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
                lastFromMe: row.lastFromMe.flatMap(AppleTime.toDate).flatMap(TimeUtils.formatISO),
                lastFromThem: row.lastFromThem.flatMap(AppleTime.toDate).flatMap(TimeUtils.formatISO),
                started: row.firstInWindow.flatMap(AppleTime.toDate).flatMap(TimeUtils.formatISO)
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
                    identity: identity,
                    recentSenders: recentSendersByChat[row.chatId]
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
