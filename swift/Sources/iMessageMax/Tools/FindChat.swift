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
                "default": .int(limit.defaultValue),
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

        // filtered_hidden counts the distinct hidden chats that any path
        // tried would have matched, not capped by limit: a path that finds
        // only hidden chats hands over to the next without losing its count.
        // contains_recent reads only the newest candidate rows (its shown
        // results do too), so its hidden count covers the same window over
        // hidden chats.
        var results: [ChatResult] = []
        var hiddenMatches: Set<Int64> = []
        let scope = ChatScope(named: nil, includeFiltered: params.includeFiltered)
        let shown = scope.shownPredicate() ?? "1"

        if let participants = params.participants, !participants.isEmpty {
            // A participant who resolves to nobody matches no chat.
            let match = await ParticipantChats.resolve(participants, resolver: resolver)
            let chats = try match.chats(
                db: database,
                chatPredicate: scope.shownPredicate(),
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
            if scope.hidesChats {
                hiddenMatches.formUnion(try match.chats(
                    db: database,
                    chatPredicate: SQLFragments.hiddenChat(),
                    isGroup: params.isGroup,
                    order: .recent,
                    limit: -1  // SQLite reads a negative LIMIT as no limit.
                ).map(\.id))
            }
        }

        if let name = params.name, results.isEmpty {
            let chats = try await findChatsByName(
                database: database,
                name: name,
                limit: params.limit,
                isGroup: params.isGroup,
                chatPredicate: shown,
                resolver: resolver
            )
            results.append(contentsOf: try await buildChatResults(
                database: database,
                chats: chats,
                resolver: resolver,
                matchType: "name"
            ))
            if scope.hidesChats {
                hiddenMatches.formUnion(try await findChatsByName(
                    database: database,
                    name: name,
                    limit: nil,
                    isGroup: params.isGroup,
                    chatPredicate: SQLFragments.hiddenChat(),
                    resolver: resolver
                ).map(\.id))
            }
        }

        if let containsRecent = params.containsRecent, results.isEmpty {
            let chats = try findChatsByContent(
                database: database,
                content: containsRecent,
                limit: params.limit,
                isGroup: params.isGroup,
                chatPredicate: shown
            )
            results.append(contentsOf: try await buildChatResults(
                database: database,
                chats: chats,
                resolver: resolver,
                matchType: "content"
            ))
            if scope.hidesChats {
                hiddenMatches.formUnion(try findChatsByContent(
                    database: database,
                    content: containsRecent,
                    limit: params.limit,
                    isGroup: params.isGroup,
                    chatPredicate: SQLFragments.hiddenChat(),
                    capsChats: false
                ).map(\.id))
            }
        }

        // No cursor on find_chat; never advertise more pages.
        let response = Response(
            chats: results,
            more: false,
            filteredHidden: scope.filteredHidden { hiddenMatches.count }
        )

        return [.plainText(try FormatUtils.encodeJSON(response))]
    }

    // MARK: - Private Helpers

    private static func groupFilterSQL(isGroup: Bool?) -> String {
        guard let isGroup else { return "" }
        return " AND " + (isGroup ? SQLFragments.isGroup() : SQLFragments.isDirect())
    }

    /// Chats over `chatPredicate` named `name`, newest first; nil `limit`
    /// returns every match.
    private static func findChatsByName(
        database: Database,
        name: String,
        limit: Int?,
        isGroup: Bool?,
        chatPredicate: String,
        resolver: ContactResolver
    ) async throws -> [ChatRow] {
        var chats = try findChatsByDisplayName(
            database: database,
            name: name,
            limit: limit,
            isGroup: isGroup,
            chatPredicate: chatPredicate
        )
        // Unnamed DMs have no display_name. Match the resolved participant
        // contact with the same word-prefix rule searchByName uses.
        if chats.count < limit ?? .max, isGroup != true {
            let unnamed = try await findUnnamedDMsByParticipantName(
                database: database,
                name: name,
                limit: limit.map { $0 - chats.count },
                chatPredicate: chatPredicate,
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
        limit: Int?,
        isGroup: Bool?,
        chatPredicate: String
    ) throws -> [ChatRow] {
        let escaped = QueryBuilder.escapeLike(name)
        let groupSQL = groupFilterSQL(isGroup: isGroup)
        let sql = """
            SELECT c.ROWID as id, c.guid, c.display_name
            FROM chat c
            WHERE c.display_name LIKE ? ESCAPE '\\'
            \(groupSQL)
            AND \(chatPredicate)
            ORDER BY \(SQLFragments.newestChatFirst())
            LIMIT ?
            """

        // SQLite reads a negative LIMIT as no limit.
        return try database.query(sql, params: ["%\(escaped)%", limit ?? -1]) { row in
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
        limit: Int?,
        chatPredicate: String,
        resolver: ContactResolver
    ) async throws -> [ChatRow] {
        let matches = await resolver.searchByName(name)
        guard !matches.isEmpty, limit ?? 1 > 0 else { return [] }

        let handles = Array(Set(matches.map(\.handle)))
        let placeholders = SQLFragments.placeholders(handles.count)
        let sql = """
            SELECT c.ROWID as id, c.guid, c.display_name
            FROM chat c
            JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
            JOIN handle h ON h.ROWID = chj.handle_id
            WHERE (c.display_name IS NULL OR TRIM(c.display_name) = '')
              AND h.id IN (\(placeholders))
              AND \(SQLFragments.isDirect())
              AND \(chatPredicate)
            GROUP BY c.ROWID
            ORDER BY \(SQLFragments.newestChatFirst())
            LIMIT ?
            """
        var params: [Any] = handles.map { $0 as Any }
        params.append(limit ?? -1)

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
    /// the decoded text decides. `limit` sizes the scan and, when
    /// `capsChats`, caps the chats returned.
    private static func findChatsByContent(
        database: Database,
        content: String,
        limit: Int,
        isGroup: Bool?,
        chatPredicate: String,
        capsChats: Bool = true
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
                if capsChats && chats.count >= limit { break }
            }
        }
        return chats
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
