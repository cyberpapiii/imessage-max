import Foundation
import MCP

/// Find chats by participants, name, or recent content.
enum FindChatTool {
    static let limit = IntArgument(name: "limit", defaultValue: 5, range: 1...50)

    static let name = "find_chat"
    static let description = "Find a specific chat by participants, name, or recent content when you already have a targeted conversation in mind. Use returned chat ids for follow-up tool calls; when explaining results to the user, refer to chats by name, not by id."

    // MARK: - Input Schema

    static let inputSchema: Value = .object([
        "type": "object",
        "properties": .object([
            "participants": .object([
                "type": "array",
                "items": .object(["type": "string"]),
                "description": "List of participant names or phone numbers to match for a targeted chat lookup",
            ]),
            "name": .object([
                "type": "string",
                "description": "Chat display name to search for when looking for a specific conversation (fuzzy match)",
            ]),
            "contains_recent": .object([
                "type": "string",
                "description": "Text that appears in recent messages for a targeted chat lookup. Scans the most recent 200 rows.",
            ]),
            "is_group": .object([
                "type": "boolean",
                "description": "Filter to group chats only (true) or DMs only (false)",
            ]),
            "include_filtered": .object([
                "type": "boolean",
                "description": "Include chats Messages.app has filtered as junk or unknown senders (default false)",
            ]),
            "limit": .object([
                "type": "integer",
                "description": "Maximum results to return (default \(limit.defaultValue))",
                "default": .int(5),
            ]),
        ]),
        "additionalProperties": false,
    ])

    // MARK: - Parameters

    struct Parameters {
        let participants: [String]?
        let name: String?
        let containsRecent: String?
        let isGroup: Bool?
        let includeFiltered: Bool
        let limit: Int

        init(from arguments: [String: Value]?) {
            self.participants = arguments?["participants"]?.arrayValue?.compactMap { $0.stringValue }
            self.name = arguments?["name"]?.stringValue
            self.containsRecent = arguments?["contains_recent"]?.stringValue
            self.isGroup = arguments?["is_group"]?.boolValue
            self.includeFiltered = arguments?["include_filtered"]?.boolValue ?? false
            self.limit = FindChatTool.limit.read(arguments)
        }
    }

    // MARK: - Response Types

    typealias ChatResult = ChatListing<ChatResultDetails>

    struct ChatResultDetails: Encodable {
        let lastMessage: LastMessageSummary?
        let participants: [ChatParticipant]
        let match: MatchInfo
        let identity: ChatIdentity

        enum CodingKeys: String, CodingKey {
            case lastMessage = "last_message"
            case participants, match, identity
        }
    }

    struct Response: Encodable {
        let chats: [ChatResult]
        let more: Bool
        let filteredHidden: Int?

        enum CodingKeys: String, CodingKey {
            case chats, more
            case filteredHidden = "filtered_hidden"
        }
    }

    // MARK: - Tool Registration

    static func definition(db database: Database, resolver: ContactResolver) -> ToolDefinition {
        return ToolDefinition(
            name: name,
            description: description,
            inputSchema: inputSchema,
            outputSchema: OutputSchema.object,
            annotations: Tool.Annotations(
                title: "Find Chat",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await execute(arguments: arguments, database: database, resolver: resolver)
        }
    }

    // MARK: - Execution

    static func execute(
        arguments: [String: Value]?,
        database: Database,
        resolver: ContactResolver
    ) async throws -> [Tool.Content] {
        let params = Parameters(from: arguments)

        guard params.participants != nil || params.name != nil || params.containsRecent != nil else {
            throw ToolFailure("validation_error", "At least one of participants, name, or contains_recent required")
        }

        var results: [ChatResult] = []
        var filteredHidden: Int? = params.includeFiltered ? nil : 0

        if let participants = params.participants, !participants.isEmpty {
            // A participant who resolves to nobody matches no chat.
            let match = await ParticipantChats.resolve(participants, resolver: resolver)
            let chats = try match.chats(
                db: database,
                chatPredicate: params.includeFiltered ? nil : SQLFragments.shownChat(),
                isGroup: params.isGroup,
                order: .exactSizeFirst,
                limit: params.limit
            )
            results.append(contentsOf: try await buildChatResults(
                database: database,
                chats: chats.map { ChatRow(id: $0.id, guid: $0.guid, displayName: $0.displayName) },
                resolver: resolver,
                matchType: "participants"
            ))
            if !params.includeFiltered {
                filteredHidden = try match.count(db: database, chatPredicate: SQLFragments.hiddenChat(), isGroup: params.isGroup)
            }
        }

        if let name = params.name, results.isEmpty {
            let chats = try await findChatsByName(
                database: database,
                name: name,
                limit: params.limit,
                isGroup: params.isGroup,
                includeFiltered: params.includeFiltered,
                resolver: resolver
            )
            results.append(contentsOf: try await buildChatResults(
                database: database,
                chats: chats,
                resolver: resolver,
                matchType: "name"
            ))
            if !params.includeFiltered {
                filteredHidden = try countFilteredHiddenByName(
                    database: database,
                    name: name,
                    limit: params.limit,
                    isGroup: params.isGroup
                )
            }
        }

        if let containsRecent = params.containsRecent, results.isEmpty {
            let chats = try findChatsByContent(
                database: database,
                content: containsRecent,
                limit: params.limit,
                isGroup: params.isGroup,
                chatPredicate: params.includeFiltered ? "1" : SQLFragments.shownChat()
            )
            results.append(contentsOf: try await buildChatResults(
                database: database,
                chats: chats,
                resolver: resolver,
                matchType: "content"
            ))
            if !params.includeFiltered {
                filteredHidden = try findChatsByContent(
                    database: database,
                    content: containsRecent,
                    limit: params.limit,
                    isGroup: params.isGroup,
                    chatPredicate: SQLFragments.hiddenChat()
                ).count
            }
        }

        var seen = Set<String>()
        var uniqueResults: [ChatResult] = []
        for result in results {
            if !seen.contains(result.chat.id) {
                seen.insert(result.chat.id)
                uniqueResults.append(result)
                if uniqueResults.count >= params.limit {
                    break
                }
            }
        }

        // No cursor on find_chat; never advertise more pages.
        let response = Response(
            chats: uniqueResults,
            more: false,
            filteredHidden: filteredHidden
        )

        return [.plainText(try FormatUtils.encodeJSON(response))]
    }

    // MARK: - Private Helpers

    /// SQL fragment filtering chats by handle count before LIMIT (groups > 1, DMs <= 1).
    private static func groupFilterSQL(isGroup: Bool?) -> String {
        guard let isGroup else { return "" }
        return " AND " + (isGroup ? SQLFragments.isGroup() : SQLFragments.isDirect())
    }

    private static func filteredSQL(includeFiltered: Bool) -> String {
        includeFiltered ? "" : " AND \(SQLFragments.shownChat())"
    }

    private static func filteredHiddenSQL() -> String {
        " AND \(SQLFragments.hiddenChat())"
    }

    private static func findChatsByName(
        database: Database,
        name: String,
        limit: Int,
        isGroup: Bool?,
        includeFiltered: Bool,
        resolver: ContactResolver
    ) async throws -> [ChatRow] {
        var chats = try findChatsByDisplayName(
            database: database,
            name: name,
            limit: limit,
            isGroup: isGroup,
            includeFiltered: includeFiltered
        )
        // Unnamed DMs have no display_name. Match the resolved participant
        // contact with the same word-prefix rule searchByName uses.
        if chats.count < limit, isGroup != true {
            let unnamed = try await findUnnamedDMsByParticipantName(
                database: database,
                name: name,
                limit: limit - chats.count,
                includeFiltered: includeFiltered,
                resolver: resolver
            )
            var seen = Set(chats.map(\.id))
            for chat in unnamed where seen.insert(chat.id).inserted {
                chats.append(chat)
            }
        }
        return chats
    }

    private static func findChatsByDisplayName(
        database: Database,
        name: String,
        limit: Int,
        isGroup: Bool?,
        includeFiltered: Bool
    ) throws -> [ChatRow] {
        let escaped = QueryBuilder.escapeLike(name)
        let groupSQL = groupFilterSQL(isGroup: isGroup)
        let filterSQL = filteredSQL(includeFiltered: includeFiltered)
        let sql = """
            SELECT c.ROWID as id, c.guid, c.display_name
            FROM chat c
            WHERE c.display_name LIKE ? ESCAPE '\\'
            \(groupSQL)
            \(filterSQL)
            ORDER BY \(SQLFragments.newestChatFirst())
            LIMIT ?
            """

        return try database.query(sql, params: ["%\(escaped)%", limit]) { row in
            ChatRow(
                id: row.int(0),
                guid: row.string(1),
                displayName: row.string(2)
            )
        }
    }

    private static func findUnnamedDMsByParticipantName(
        database: Database,
        name: String,
        limit: Int,
        includeFiltered: Bool,
        resolver: ContactResolver
    ) async throws -> [ChatRow] {
        let matches = await resolver.searchByName(name)
        guard !matches.isEmpty, limit > 0 else { return [] }

        let handles = Array(Set(matches.map(\.handle)))
        let placeholders = SQLFragments.placeholders(handles.count)
        let filterSQL = filteredSQL(includeFiltered: includeFiltered)
        let sql = """
            SELECT c.ROWID as id, c.guid, c.display_name
            FROM chat c
            JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
            JOIN handle h ON h.ROWID = chj.handle_id
            WHERE (c.display_name IS NULL OR TRIM(c.display_name) = '')
              AND h.id IN (\(placeholders))
              AND \(SQLFragments.isDirect())
              \(filterSQL)
            GROUP BY c.ROWID
            ORDER BY \(SQLFragments.newestChatFirst())
            LIMIT ?
            """
        var params: [Any] = handles.map { $0 as Any }
        params.append(limit)

        return try database.query(sql, params: params) { row in
            ChatRow(
                id: row.int(0),
                guid: row.string(1),
                displayName: row.string(2)
            )
        }
    }

    /// Chats whose newest candidate rows contain `content`, newest first.
    /// The scan covers the most recent rows that may contain the text, and
    /// the decoded text decides.
    private static func findChatsByContent(
        database: Database,
        content: String,
        limit: Int,
        isGroup: Bool?,
        chatPredicate: String
    ) throws -> [ChatRow] {
        let match = SQLFragments.textMayContain(content)
        let fetchLimit = min(max(limit * 10, 50), 200)
        let sql = """
            SELECT c.ROWID as id, c.guid, c.display_name, m.text, m.attributedBody
            FROM chat c
            JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
            JOIN message m ON cmj.message_id = m.ROWID
            WHERE \(SQLFragments.notReaction())
              AND \(match.sql)
              \(groupFilterSQL(isGroup: isGroup))
              AND \(chatPredicate)
            ORDER BY m.date DESC, m.ROWID DESC
            LIMIT ?
            """

        let rows = try database.query(sql, params: match.bindings + [fetchLimit]) { row in
            (
                chat: ChatRow(id: row.int(0), guid: row.string(1), displayName: row.string(2)),
                text: MessageTextExtractor.extract(text: row.string(3), attributedBody: row.blob(4))
            )
        }

        let needle = content.lowercased()
        var seen = Set<Int64>()
        var chats: [ChatRow] = []
        for row in rows where row.text?.lowercased().contains(needle) == true {
            if seen.insert(row.chat.id).inserted {
                chats.append(row.chat)
                if chats.count >= limit { break }
            }
        }
        return chats
    }

    private static func countFilteredHiddenByName(
        database: Database,
        name: String,
        limit: Int,
        isGroup: Bool?
    ) throws -> Int {
        let escaped = QueryBuilder.escapeLike(name)
        let groupSQL = groupFilterSQL(isGroup: isGroup)
        let sql = """
            SELECT COUNT(*) FROM (
                SELECT c.ROWID
                FROM chat c
                WHERE c.display_name LIKE ? ESCAPE '\\'
                \(groupSQL)
                \(filteredHiddenSQL())
                LIMIT ?
            )
            """
        let rows: [Int] = try database.query(sql, params: ["%\(escaped)%", limit]) { row in
            Int(row.int(0))
        }
        return rows.first ?? 0
    }

    private static func buildChatResults(
        database: Database,
        chats: [ChatRow],
        resolver: ContactResolver,
        matchType: String
    ) async throws -> [ChatResult] {
        let page = try await ChatPage.build(
            chats.map { ChatPage.Chat(id: $0.id, guid: $0.guid, explicitName: $0.displayName) },
            lastMessages: ChatPage.LastMessageOptions(agoFallback: nil),
            db: database,
            resolver: resolver
        )
        let results = chats.compactMap { chat in
            page[chat.id].map { entry in
                ChatResult(
                    chat: entry.summary,
                    details: ChatResultDetails(
                        lastMessage: entry.lastMessage?.info,
                        participants: IdentityDisplayFormatter.participants(entry.identity.participants),
                        match: MatchInfo(type: matchType),
                        identity: entry.identity
                    )
                )
            }
        }
        return results
    }


}

// MARK: - Supporting Types

private struct ChatRow {
    let id: Int64
    let guid: String?
    let displayName: String?
}
