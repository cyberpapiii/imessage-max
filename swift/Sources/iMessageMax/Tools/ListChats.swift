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
                    "description": "Sort order. \"recent\" by last message; \"most_active\" by message count in the selected window; \"alphabetical\" by display name.",
                    "enum": ["recent", "alphabetical", "most_active"],
                ]),
                "cursor": .object([
                    "type": "string",
                    "description": "Pagination cursor from a previous list_chats response",
                ]),
            ]),
            "additionalProperties": false,
        ])

        server.registerTool(
            name: "list_chats",
            description: "List recent chats with previews. Returns chat ids for follow-up tool calls and chat names for user-facing summaries. When explaining results to the user, refer to chats by name, not by id. Good starting point for broad catch-ups and discovery before drilling deeper.",
            inputSchema: inputSchema,
            outputSchema: OutputSchema.object,
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
            let cursor = arguments?["cursor"]?.stringValue

            let result = await execute(
                limit: limit,
                since: since,
                isGroup: isGroup,
                minParticipants: minParticipants,
                maxParticipants: maxParticipants,
                sort: sort,
                cursor: cursor,
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
        let clampedLimit = max(1, min(limit, 100))

        let sortOrder = ListChatsSort(rawValue: sort) ?? .recent

        do {
            try await resolver.initialize()
        } catch {
            // Continue without contacts - not a fatal error
        }

        do {
            let sinceApple = since.flatMap(AppleTime.parse)

            // Message totals come from a per-chat aggregate subquery rather than
            // joining chat_handle_join and message in the same FROM. Joining both
            // multiplies each chat's rows by its participant count, which both
            // inflated message_count (and therefore the most_active sort) and
            // forced SQLite to aggregate participants x messages for every chat.
            //
            // The aggregate walks every non-reaction message in the database,
            // so it is only worth paying for when the answer depends on it.
            // Neither message_count nor last_message_date reaches the response:
            // the last-message preview comes from ChatSummaryQueries. They are
            // ordering and cursor keys, and the alphabetical sort orders and
            // pages by name, so it needs neither. `since` still does, because
            // it decides which chats appear at all.
            let needsMessageAggregate = sinceApple != nil || sortOrder != .alphabetical

            let recentCursorDate: Int64? = sortOrder == .recent
                ? cursor.flatMap(ChatListCursor.decode)?.primary
                : nil

            /// Builds the page query, optionally bounding the aggregate to the
            /// newest `candidateWidth` messages.
            func buildPageQuery(candidateWidth: Int?) -> (String, [Any]) {
                var innerFilter = "m.associated_message_type = 0"
                var innerParams: [Any] = []
                if let sinceApple {
                    innerFilter += "\n                       AND m.date >= ?"
                    innerParams.append(sinceApple)
                }

                let messageAggregate: String
                if let candidateWidth {
                    // The inner scan takes a date-ordered prefix, so every chat
                    // it surfaces has its own newest message inside that prefix
                    // and MAX(dt) is that chat's true last-message date. The
                    // recent cursor deliberately does NOT push down into the
                    // scan: narrowing it to messages at or before the cursor
                    // would truncate the maximum for any chat with messages on
                    // both sides of it, and that chat would then re-appear on a
                    // later page it had already been returned on.
                    messageAggregate = """
                        (SELECT chat_id, 0 AS message_count, MAX(dt) AS last_message_date
                         FROM (SELECT cmj.chat_id AS chat_id, m.date AS dt
                               FROM chat_message_join cmj
                               JOIN message m ON m.ROWID = cmj.message_id
                               WHERE \(innerFilter)
                               ORDER BY m.date DESC
                               LIMIT \(candidateWidth))
                         GROUP BY chat_id) msg ON msg.chat_id = c.ROWID
                        """
                } else {
                    messageAggregate = """
                        (SELECT cmj.chat_id AS chat_id,
                                COUNT(*) AS message_count,
                                MAX(m.date) AS last_message_date
                         FROM chat_message_join cmj
                         JOIN message m ON m.ROWID = cmj.message_id
                         WHERE \(innerFilter)
                         GROUP BY cmj.chat_id) msg ON msg.chat_id = c.ROWID
                        """
                }

                let qb = QueryBuilder()
                qb.select(
                    "c.ROWID as id",
                    "c.guid",
                    "c.display_name",
                    "(SELECT COUNT(DISTINCT chj.handle_id) FROM chat_handle_join chj"
                        + " WHERE chj.chat_id = c.ROWID) as participant_count",
                    needsMessageAggregate ? "COALESCE(msg.message_count, 0) as message_count" : "0 as message_count",
                    needsMessageAggregate ? "msg.last_message_date as last_message_date" : "NULL as last_message_date"
                )
                .from("chat c")

                if sinceApple != nil || candidateWidth != nil {
                    // `since` previously filtered the joined message rows in
                    // WHERE, which dropped chats with no activity in the window.
                    // An inner join keeps that behavior. A bounded scan also
                    // joins inward: a chat outside the candidate set has no
                    // claim on this page, and the escalation below is what
                    // brings it back when the page cannot be filled without it.
                    qb.join(messageAggregate, params: innerParams)
                } else if needsMessageAggregate {
                    qb.leftJoin(messageAggregate)
                }

                qb.groupBy("c.ROWID")

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

                if let cursor, let decoded = ChatListCursor.decode(cursor) {
                    switch sortOrder {
                    case .recent:
                        qb.having(
                            "(last_message_date < ? OR (last_message_date = ? AND c.ROWID < ?))",
                            decoded.primary, decoded.primary, decoded.chatId
                        )
                    case .mostActive:
                        // primary = message_count, secondary = last_message_date
                        let lastDate = decoded.secondary ?? 0
                        qb.having(
                            """
                            (message_count < ?
                             OR (message_count = ? AND last_message_date < ?)
                             OR (message_count = ? AND last_message_date = ? AND c.ROWID < ?))
                            """,
                            decoded.primary, decoded.primary, lastDate,
                            decoded.primary, lastDate, decoded.chatId
                        )
                    case .alphabetical:
                        // primary unused; secondary unused — lexicographic via chat id only is unsafe.
                        // Alphabetical cursor encodes name hash in primary as 0 and uses chatId with name HAVING.
                        break
                    }
                }

                // Alphabetical keyset: "name\\0chatId" stored as opaque string via ChatListCursor.name form.
                if sortOrder == .alphabetical, let cursor, let nameCursor = ChatListCursor.decodeName(cursor) {
                    qb.having(
                        """
                        (COALESCE(c.display_name, '') > ?
                         OR (COALESCE(c.display_name, '') = ? AND c.ROWID > ?))
                        """,
                        nameCursor.name, nameCursor.name, nameCursor.chatId
                    )
                }

                switch sortOrder {
                case .recent:
                    qb.orderBy("last_message_date DESC NULLS LAST", "c.ROWID DESC")
                case .mostActive:
                    qb.orderBy("message_count DESC", "last_message_date DESC NULLS LAST", "c.ROWID DESC")
                case .alphabetical:
                    qb.orderBy("COALESCE(c.display_name, '') ASC", "c.ROWID ASC")
                }

                qb.limit(clampedLimit + 1)

                return qb.build()
            }

            // The recent sort orders chats by their newest message, so the
            // newest K messages in the database name every chat that can lead
            // the list. Grouping them gives candidates whose last-message dates
            // are all at least as new as the K-th newest message, so any chat
            // left out is older than every candidate: a full page drawn from
            // them is exactly the page the unbounded aggregate would return.
            // A short page means the participant filters thinned the candidates
            // below a full page, and only then is a wider scan worth paying for.
            // Every other sort needs the true aggregate and takes the last,
            // unbounded entry directly.
            // Paging is excluded because the cursor cannot narrow the scan
            // (see buildPageQuery) while it does thin the page, so every deep
            // page would climb the whole ladder before landing on the same
            // unbounded query it starts from today.
            let candidateWidths: [Int?] = sortOrder == .recent && recentCursorDate == nil
                ? [2_000, 20_000, 200_000, nil]
                : [nil]

            var fetchedRows: [ChatRow] = []
            for candidateWidth in candidateWidths {
                let (sql, params) = buildPageQuery(candidateWidth: candidateWidth)
                fetchedRows = try db.query(sql, params: params) { row in
                    ChatRow(
                        id: row.int(0),
                        guid: row.string(1),
                        displayName: row.string(2),
                        participantCount: Int(row.int(3)),
                        messageCount: row.int(4),
                        lastMessageDate: row.optionalInt(5)
                    )
                }
                if candidateWidth == nil || fetchedRows.count > clampedLimit {
                    break
                }
            }

            let hasMore = fetchedRows.count > clampedLimit
            let chatRows = Array(fetchedRows.prefix(clampedLimit))

            // Batch-fetch participants and last messages for all chats at once.
            let chatIds = chatRows.map(\.id)
            let participantsByChat = try await ChatSummaryQueries.participantsByChat(
                db: db,
                chatIds: chatIds,
                resolver: resolver
            )
            let lastMessagesByChat = try await ChatSummaryQueries.lastMessagesByChat(
                db: db,
                chatIds: chatIds,
                resolver: resolver
            )

            var chats: [ChatInfo] = []

            for chatRow in chatRows {
                let participantRows = participantsByChat[chatRow.id] ?? []

                let identityParticipants = participantRows.map { p in
                    ChatIdentity.makeParticipant(handle: p.handle, contactName: p.name)
                }

                let identity = ChatIdentity(
                    mcpId: "chat\(chatRow.id)",
                    guid: chatRow.guid,
                    explicitName: chatRow.displayName,
                    participants: identityParticipants
                )
                let isGroupChat = identity.participantCount > 1

                let lastMsg = lastMessagesByChat[chatRow.id]

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

            let totals = try getTotals(db: db)

            let nextCursor: String?
            if hasMore, let last = chatRows.last {
                switch sortOrder {
                case .recent:
                    nextCursor = ChatListCursor.encode(
                        primary: last.lastMessageDate,
                        secondary: nil,
                        chatId: last.id
                    )
                case .mostActive:
                    nextCursor = ChatListCursor.encode(
                        primary: last.messageCount,
                        secondary: last.lastMessageDate,
                        chatId: last.id
                    )
                case .alphabetical:
                    nextCursor = ChatListCursor.encodeName(
                        name: last.displayName ?? "",
                        chatId: last.id
                    )
                }
            } else {
                nextCursor = nil
            }

            return .success(ListChatsResponse(
                chats: chats,
                totalChats: totals.total,
                totalGroups: totals.groups,
                totalDms: totals.dms,
                more: hasMore,
                cursor: nextCursor
            ))

        } catch let error as DatabaseError {
            switch error {
            case .notFound:
                return .failure(ListChatsError(
                    error: "database_not_found",
                    message: ClientErrorMessages.databaseNotFound
                ))
            case .permissionDenied:
                return .failure(ListChatsError(
                    error: "permission_denied",
                    message: ClientErrorMessages.permissionDenied
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
                message: ClientErrorMessages.sanitized(error)
            ))
        }
    }

    // MARK: - Private Helpers

    private struct ChatRow {
        let id: Int64
        let guid: String?
        let displayName: String?
        let participantCount: Int
        let messageCount: Int64
        let lastMessageDate: Int64?
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
