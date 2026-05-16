// Sources/iMessageMax/Tools/ListChats.swift
import Foundation
import MCP

/// Sort order for list_chats
enum ListChatsSort: String {
    case recent = "recent"
    case alphabetical = "alphabetical"
    case mostActive = "most_active"
}

/// Response structure for list_chats tool
struct ListChatsResponse: Codable {
    let chats: [ChatInfo]
    let totalChats: Int
    let totalGroups: Int
    let totalDms: Int
    let more: Bool
    let cursor: String?

    enum CodingKeys: String, CodingKey {
        case chats
        case totalChats = "total_chats"
        case totalGroups = "total_groups"
        case totalDms = "total_dms"
        case more
        case cursor
    }
}

/// Individual chat info in response
struct ChatInfo: Codable {
    let id: String
    let name: String
    let group: Bool?
    let participantCount: Int
    let participantsPreview: [String]
    let lastMessage: LastMessageSummary?
    let awaitingReply: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case group
        case participantCount = "participant_count"
        case participantsPreview = "participants_preview"
        case lastMessage = "last_message"
        case awaitingReply = "awaiting_reply"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(lastMessage, forKey: .lastMessage)
        try container.encodeIfPresent(awaitingReply, forKey: .awaitingReply)
        try container.encodeIfPresent(group, forKey: .group)
        try container.encode(participantCount, forKey: .participantCount)
        try container.encode(participantsPreview, forKey: .participantsPreview)
    }
}

/// Error response
struct ListChatsError: Error, Codable {
    let error: String
    let message: String
}

/// Implementation of the list_chats tool
enum ListChatsTool {
    // MARK: - Tool Registration

    static func register(on server: Server, db: Database, resolver: ContactResolver) {
        let inputSchema: Value = .object([
            "type": "object",
            "properties": .object([
                "limit": .object([
                    "type": "integer",
                    "description": "Max chats to return (default 20, max 100)",
                ]),
                "since": .object([
                    "type": "string",
                    "description": "Only chats with activity since this time (ISO, relative, or natural). Good for broad recent catch-up windows like \"2d\" or \"yesterday\".",
                ]),
                "is_group": .object([
                    "type": "boolean",
                    "description": "True for groups only, False for DMs only",
                ]),
                "min_participants": .object([
                    "type": "integer",
                    "description": "Filter to chats with at least N participants",
                ]),
                "max_participants": .object([
                    "type": "integer",
                    "description": "Filter to chats with at most N participants",
                ]),
                "sort": .object([
                    "type": "string",
                    "description": "Sort order. Use \"recent\" for a broad recent-overview across conversations.",
                    "enum": ["recent", "alphabetical", "most_active"],
                ]),
            ]),
            "additionalProperties": false,
        ])

        server.registerTool(
            name: "list_chats",
            description: "List recent chats with previews. Returns chat ids for follow-up tool calls and chat names for user-facing summaries. When explaining results to the user, refer to chats by name, not by id. Good starting point for broad catch-ups and discovery before drilling deeper.",
            inputSchema: inputSchema,
            annotations: Tool.Annotations(
                title: "List Chats",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let limit = arguments?["limit"]?.intValue ?? 20
            let since = arguments?["since"]?.stringValue
            let isGroup = arguments?["is_group"]?.boolValue
            let minParticipants = arguments?["min_participants"]?.intValue
            let maxParticipants = arguments?["max_participants"]?.intValue
            let sort = arguments?["sort"]?.stringValue ?? "recent"

            let result = await execute(
                limit: limit,
                since: since,
                isGroup: isGroup,
                minParticipants: minParticipants,
                maxParticipants: maxParticipants,
                sort: sort,
                cursor: nil,
                db: db,
                resolver: resolver
            )

            switch result {
            case .success(let response):
                return [.plainText(try FormatUtils.encodeJSON(response))]
            case .failure(let error):
                throw ToolError(content: [.plainText(try FormatUtils.encodeJSON(error))])
            }
        }
    }

    /// List recent chats with previews
    /// - Parameters:
    ///   - limit: Max chats to return (default 20, clamped to 1-100)
    ///   - since: Only chats with activity since this time
    ///   - isGroup: True for groups only, False for DMs only
    ///   - minParticipants: Filter to chats with at least N participants
    ///   - maxParticipants: Filter to chats with at most N participants
    ///   - sort: "recent" (default), "alphabetical", or "most_active"
    ///   - cursor: Pagination cursor (unused, for future use)
    ///   - db: Database instance
    ///   - resolver: ContactResolver for name lookups
    static func execute(
        limit: Int = 20,
        since: String? = nil,
        isGroup: Bool? = nil,
        minParticipants: Int? = nil,
        maxParticipants: Int? = nil,
        sort: String = "recent",
        cursor: String? = nil,
        db: Database = Database(),
        resolver: ContactResolver
    ) async -> Result<ListChatsResponse, ListChatsError> {
        // Clamp limit to 1-100
        let clampedLimit = max(1, min(limit, 100))

        // Validate sort
        let sortOrder = ListChatsSort(rawValue: sort) ?? .recent

        // Initialize resolver
        do {
            try await resolver.initialize()
        } catch {
            // Continue without contacts - not a fatal error
        }

        do {
            // Build base query
            let qb = QueryBuilder()
            qb.select(
                "c.ROWID as id",
                "c.guid",
                "c.display_name",
                "c.service_name",
                "COUNT(DISTINCT chj.handle_id) as participant_count",
                "MAX(m.date) as last_message_date"
            )
            .from("chat c")
            .leftJoin("chat_handle_join chj ON c.ROWID = chj.chat_id")
            .leftJoin("chat_message_join cmj ON c.ROWID = cmj.chat_id")
            .leftJoin("message m ON cmj.message_id = m.ROWID AND m.associated_message_type = 0")

            // Time filter
            if let since = since, let sinceApple = AppleTime.parse(since) {
                qb.where("m.date >= ?", sinceApple)
            }

            qb.groupBy("c.ROWID")

            // Participant count filters (HAVING clause)
            if let minP = minParticipants {
                qb.having("participant_count >= ?", minP)
            }
            if let maxP = maxParticipants {
                qb.having("participant_count <= ?", maxP)
            }
            if let isGroup = isGroup {
                if isGroup {
                    qb.having("participant_count > 1")
                } else {
                    qb.having("participant_count <= 1")
                }
            }

            // Sort
            switch sortOrder {
            case .recent, .mostActive:
                qb.orderBy("last_message_date DESC NULLS LAST")
            case .alphabetical:
                qb.orderBy("COALESCE(c.display_name, '') ASC")
            }

            qb.limit(clampedLimit)

            let (sql, params) = qb.build()
            let chatRows = try db.query(sql, params: params) { row in
                ChatRow(
                    id: row.int(0),
                    guid: row.string(1),
                    displayName: row.string(2),
                    serviceName: row.string(3),
                    participantCount: Int(row.int(4)),
                    lastMessageDate: row.optionalInt(5)
                )
            }

            // Build results
            var chats: [ChatInfo] = []

            for chatRow in chatRows {
                // Get participants
                let participantRows = try await getParticipants(
                    db: db,
                    chatId: chatRow.id,
                    resolver: resolver
                )

                var identityParticipants: [ChatIdentity.Participant] = []
                for p in participantRows {
                    let identityParticipant = ChatIdentity.makeParticipant(
                        handle: p.handle,
                        contactName: p.name
                    )
                    identityParticipants.append(identityParticipant)
                }

                let identity = ChatIdentity(
                    mcpId: "chat\(chatRow.id)",
                    guid: chatRow.guid,
                    explicitName: chatRow.displayName,
                    participants: identityParticipants
                )
                let isGroupChat = identity.participantCount > 1

                // Get last message
                let lastMsg = try await getLastMessage(
                    db: db,
                    chatId: chatRow.id,
                    resolver: resolver
                )

                let chatInfo = ChatInfo(
                    id: identity.mcpId,
                    name: identity.displayName,
                    group: isGroupChat ? true : nil,
                    participantCount: identity.participantCount,
                    participantsPreview: try ChatSummaryBuilder.participantsPreview(
                        db: db,
                        chatId: chatRow.id,
                        identity: identity
                    ),
                    lastMessage: lastMsg?.info,
                    awaitingReply: lastMsg?.awaitingReply
                )

                chats.append(chatInfo)
            }

            // Get totals
            let totals = try getTotals(db: db)

            return .success(ListChatsResponse(
                chats: chats,
                totalChats: totals.total,
                totalGroups: totals.groups,
                totalDms: totals.dms,
                more: chats.count == clampedLimit,
                cursor: nil
            ))

        } catch let error as DatabaseError {
            switch error {
            case .notFound(let path):
                return .failure(ListChatsError(
                    error: "database_not_found",
                    message: "Database not found at \(path)"
                ))
            case .permissionDenied(let path):
                return .failure(ListChatsError(
                    error: "permission_denied",
                    message: "Permission denied accessing \(path)"
                ))
            case .queryFailed(let msg):
                return .failure(ListChatsError(
                    error: "query_failed",
                    message: msg
                ))
            case .invalidData(let msg):
                return .failure(ListChatsError(
                    error: "invalid_data",
                    message: msg
                ))
            }
        } catch {
            return .failure(ListChatsError(
                error: "internal_error",
                message: error.localizedDescription
            ))
        }
    }

    // MARK: - Private Helpers

    private struct ChatRow {
        let id: Int64
        let guid: String?
        let displayName: String?
        let serviceName: String?
        let participantCount: Int
        let lastMessageDate: Int64?
    }

    private struct ParticipantRow {
        let handle: String
        let name: String?
        let service: String?
    }

    private struct LastMessageResult {
        let info: LastMessageSummary
        let awaitingReply: Bool
    }

    /// Get participants for a chat
    private static func getParticipants(
        db: Database,
        chatId: Int64,
        resolver: ContactResolver
    ) async throws -> [ParticipantRow] {
        let sql = """
            SELECT h.id as handle, h.service
            FROM chat_handle_join chj
            JOIN handle h ON chj.handle_id = h.ROWID
            WHERE chj.chat_id = ?
            """

        let rows = try db.query(sql, params: [chatId]) { row in
            (handle: row.string(0) ?? "", service: row.string(1))
        }

        var participants: [ParticipantRow] = []
        for row in rows {
            let name = await resolver.resolve(row.handle)
            participants.append(ParticipantRow(
                handle: row.handle,
                name: name,
                service: row.service
            ))
        }

        return participants
    }

    /// Get last message for a chat
    private static func getLastMessage(
        db: Database,
        chatId: Int64,
        resolver: ContactResolver
    ) async throws -> LastMessageResult? {
        let sql = """
            SELECT m.text, m.attributedBody, m.is_from_me, h.id as sender_handle, m.date
            , m.ROWID
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE cmj.chat_id = ?
            AND m.associated_message_type = 0
            ORDER BY m.date DESC
            LIMIT 1
            """

        let rows = try db.query(sql, params: [chatId]) { row in
            (
                text: row.string(0),
                attributedBody: row.blob(1),
                isFromMe: row.int(2) == 1,
                senderHandle: row.string(3),
                date: row.optionalInt(4),
                messageId: row.int(5)
            )
        }

        guard let last = rows.first else { return nil }

        // Determine sender
        let sender: String
        if last.isFromMe {
            sender = "Me"
        } else if let handle = last.senderHandle {
            sender = await IdentityDisplayFormatter.displayName(handle: handle, resolver: resolver)
        } else {
            sender = "unknown"
        }

        // Format time
        let date = AppleTime.toDate(last.date)
        let ago = TimeUtils.formatCompactRelative(date) ?? "unknown"

        return LastMessageResult(
            info: LastMessageSummary(
                from: sender,
                text: try MessagePreviewResolver.messageSummary(
                    db: db,
                    messageId: last.messageId,
                    text: last.text,
                    attributedBody: last.attributedBody,
                    maxLength: 50
                ),
                ago: ago,
                ts: TimeUtils.formatISO(date)
            ),
            awaitingReply: !last.isFromMe
        )
    }

    /// Get total counts
    private static func getTotals(db: Database) throws -> (total: Int, groups: Int, dms: Int) {
        let sql = """
            SELECT
                COUNT(*) as total,
                SUM(CASE WHEN cnt > 1 THEN 1 ELSE 0 END) as groups,
                SUM(CASE WHEN cnt <= 1 THEN 1 ELSE 0 END) as dms
            FROM (
                SELECT c.ROWID, COUNT(chj.handle_id) as cnt
                FROM chat c
                LEFT JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
                GROUP BY c.ROWID
            )
            """

        let rows = try db.query(sql, params: []) { row in
            (
                total: Int(row.int(0)),
                groups: Int(row.int(1)),
                dms: Int(row.int(2))
            )
        }

        return rows.first ?? (0, 0, 0)
    }
}
