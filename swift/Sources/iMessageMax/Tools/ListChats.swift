import Foundation
import MCP

enum ListChatsSort: String {
    case recent = "recent"
    case alphabetical = "alphabetical"
    case mostActive = "most_active"
}

struct ListChatsResponse: Encodable {
    let chats: [ChatInfo]
    let totalChats: Int?
    let totalGroups: Int?
    let totalDms: Int?
    let more: Bool
    let cursor: String?
    var filteredHidden: Int? = nil

    enum CodingKeys: String, CodingKey {
        case chats
        case totalChats = "total_chats"
        case totalGroups = "total_groups"
        case totalDms = "total_dms"
        case more
        case cursor
        case filteredHidden = "filtered_hidden"
    }
}

typealias ChatInfo = ChatListing<ChatInfoDetails>

struct ChatInfoDetails: Encodable {
    let lastMessage: LastMessageSummary?
    let awaitingReply: Bool?

    enum CodingKeys: String, CodingKey {
        case lastMessage = "last_message"
        case awaitingReply = "awaiting_reply"
    }
}

enum ListChatsTool {
    static let limit = IntArgument(name: "limit", defaultValue: 20, range: 1...100)

    static func definition(db: Database, resolver: ContactResolver) -> ToolDefinition {
        let inputSchema: Value = .object([
            "type": "object",
            "properties": .object([
                "limit": .object([
                    "type": "integer",
                    "description": "Maximum chats to return (\(limit.defaultAndMax))",
                ]),
                "since": .object([
                    "type": "string",
                    "description": "Only chats with activity since this time (ISO, relative, or natural). Use it for broad catch-up windows such as \"2d\" or \"yesterday\".",
                ]),
                "is_group": .object([
                    "type": "boolean",
                    "description": "true for groups only, false for DMs only",
                ]),
                "include_filtered": .object([
                    "type": "boolean",
                    "description": "Include chats Messages.app has filtered as junk or unknown senders (default false)",
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
                    "description": "Sort order. \"recent\" sorts by last message, \"most_active\" by message count in the selected window, and \"alphabetical\" by display name.",
                    "enum": ["recent", "alphabetical", "most_active"],
                ]),
                "cursor": .object([
                    "type": "string",
                    "description": "Pagination cursor from a previous list_chats response",
                ]),
            ]),
            "additionalProperties": false,
        ])

        return ToolDefinition(
            name: "list_chats",
            description: "List recent chats with previews. Returns chat ids for follow-up tool calls and chat names for user-facing summaries. When you explain results to the user, refer to chats by name, not by id. Start here for broad catch-ups and to find chats before you read one in detail. Totals (total_chats, total_groups, total_dms) appear on the first page only.",
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
            let limit = Self.limit.read(arguments)
            let since = arguments?["since"]?.stringValue
            let isGroup = arguments?["is_group"]?.boolValue
            let includeFiltered = arguments?["include_filtered"]?.boolValue ?? false
            let minParticipants = arguments?["min_participants"]?.intValue
            let maxParticipants = arguments?["max_participants"]?.intValue
            let sort = arguments?["sort"]?.stringValue ?? "recent"
            let cursor = arguments?["cursor"]?.stringValue

            let result = try await execute(
                limit: limit,
                since: since,
                isGroup: isGroup,
                minParticipants: minParticipants,
                maxParticipants: maxParticipants,
                sort: sort,
                cursor: cursor,
                includeFiltered: includeFiltered,
                db: db,
                resolver: resolver
            )

            return [.plainText(try FormatUtils.encodeJSON(result))]
        }
    }

    static func execute(
        limit: Int = ListChatsTool.limit.defaultValue,
        since: String? = nil,
        isGroup: Bool? = nil,
        minParticipants: Int? = nil,
        maxParticipants: Int? = nil,
        sort: String = "recent",
        cursor: String? = nil,
        includeFiltered: Bool = false,
        db: Database,
        resolver: ContactResolver
    ) async throws -> ListChatsResponse {
        let clampedLimit = Self.limit.clamp(limit)

        let sortOrder = ListChatsSort(rawValue: sort) ?? .recent

        let sinceApple = since.flatMap(AppleTime.parse)
        let scope = ChatScope(named: nil, includeFiltered: includeFiltered)

        let needsMessageAggregate = sinceApple != nil || sortOrder != .alphabetical

        let recentCursorDate: Int64? = sortOrder == .recent
            ? cursor.flatMap(ChatListCursor.decode)?.primary
            : nil

        func buildPageQuery(candidateWidth: Int?) -> (String, [Any]) {
            var innerFilter = SQLFragments.notReaction()
            var innerParams: [Any] = []
            if let sinceApple {
                innerFilter += "\n                       AND m.date >= ?"
                innerParams.append(sinceApple)
            }

            let messageAggregate: String
            if let candidateWidth {
                messageAggregate = """
                    (SELECT chat_id, 0 AS n, MAX(dt) AS last_date
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
                            COUNT(*) AS n,
                            MAX(m.date) AS last_date
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
                "\(SQLFragments.participantCount()) as participant_count",
                needsMessageAggregate ? "COALESCE(msg.n, 0) as message_count" : "0 as message_count",
                // msg's columns have names distinct from these aliases, because
                // HAVING would otherwise bind the uncoalesced column.
                needsMessageAggregate ? "COALESCE(msg.last_date, 0) as last_message_date" : "NULL as last_message_date"
            )
            .from("chat c")

            if let shown = scope.shownPredicate() {
                qb.where(shown)
            }

            if sinceApple != nil || candidateWidth != nil {
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
                qb.having(isGroup
                    ? SQLFragments.isGroup(count: "participant_count")
                    : SQLFragments.isDirect(count: "participant_count"))
            }

            if let cursor {
                switch sortOrder {
                case .recent:
                    if let decoded = ChatListCursor.decode(cursor) {
                        qb.having(
                            "(last_message_date < ? OR (last_message_date = ? AND c.ROWID < ?))",
                            decoded.primary, decoded.primary, decoded.chatId
                        )
                    }
                case .mostActive:
                    if let decoded = ChatListCursor.decode(cursor) {
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
                    }
                case .alphabetical:
                    if let nameCursor = ChatListCursor.decodeName(cursor) {
                        qb.having(
                            """
                            (COALESCE(c.display_name, '') > ?
                             OR (COALESCE(c.display_name, '') = ? AND c.ROWID > ?))
                            """,
                            nameCursor.name, nameCursor.name, nameCursor.chatId
                        )
                    }
                }
            }

            switch sortOrder {
            case .recent:
                qb.orderBy("last_message_date DESC", "c.ROWID DESC")
            case .mostActive:
                qb.orderBy("message_count DESC", "last_message_date DESC", "c.ROWID DESC")
            case .alphabetical:
                qb.orderBy("COALESCE(c.display_name, '') ASC", "c.ROWID ASC")
            }

            qb.limit(clampedLimit + 1)

            return qb.build()
        }

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

        let page = try await ChatPage.build(
            chatRows.map { ChatPage.Chat(id: $0.id, guid: $0.guid, explicitName: $0.displayName, newestDate: $0.lastMessageDate) },
            lastMessages: ChatPage.LastMessageOptions(),
            db: db,
            resolver: resolver
        )
        let chats = chatRows.compactMap { row in
            page[row.id].map { entry in
                ChatInfo(
                    chat: entry.summary,
                    details: ChatInfoDetails(
                        lastMessage: entry.lastMessage?.info,
                        awaitingReply: entry.lastMessage?.awaitingReply
                    )
                )
            }
        }

        let totals = cursor == nil ? try getTotals(db: db, scope: scope) : nil
        let filteredHidden = try scope.filteredHidden(firstPage: cursor == nil) {
            try getFilteredHidden(db: db, sinceApple: sinceApple)
        }

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

        return ListChatsResponse(
            chats: chats,
            totalChats: totals?.total,
            totalGroups: totals?.groups,
            totalDms: totals?.dms,
            more: nextCursor != nil,
            cursor: nextCursor,
            filteredHidden: filteredHidden
        )
    }

    private struct ChatRow {
        let id: Int64
        let guid: String?
        let displayName: String?
        let messageCount: Int64
        let lastMessageDate: Int64?
    }

    private static func getTotals(db: Database, scope: ChatScope) throws -> (total: Int, groups: Int, dms: Int) {
        let filter = scope.shownPredicate().map { "WHERE \($0)" } ?? ""
        let sql = """
            SELECT
                COUNT(*) as total,
                SUM(CASE WHEN \(SQLFragments.isGroup(count: "cnt")) THEN 1 ELSE 0 END) as groups,
                SUM(CASE WHEN \(SQLFragments.isDirect(count: "cnt")) THEN 1 ELSE 0 END) as dms
            FROM (
                SELECT \(SQLFragments.participantCount()) as cnt
                FROM chat c
                \(filter)
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

    private static func getFilteredHidden(db: Database, sinceApple: Int64?) throws -> Int {
        if let sinceApple {
            let sql = """
                SELECT COUNT(*)
                FROM chat c
                WHERE \(SQLFragments.hiddenChat())
                  AND EXISTS (
                    SELECT 1
                    FROM chat_message_join cmj
                    JOIN message m ON m.ROWID = cmj.message_id
                    WHERE cmj.chat_id = c.ROWID
                      AND \(SQLFragments.notReaction())
                      AND m.date >= ?
                  )
                """
            let rows: [Int] = try db.query(sql, params: [sinceApple]) { row in
                Int(row.int(0))
            }
            return rows.first ?? 0
        }

        let rows: [Int] = try db.query(
            "SELECT COUNT(*) FROM chat c WHERE \(SQLFragments.hiddenChat())",
            params: []
        ) { row in
            Int(row.int(0))
        }
        return rows.first ?? 0
    }
}
