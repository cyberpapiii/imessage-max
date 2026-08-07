// Sources/iMessageMax/Tools/FindChat.swift
import Foundation
import MCP

/// Find chats by participants, name, or recent content.
enum FindChatTool {
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
                "description": "Text that appears in recent messages for a targeted chat lookup",
            ]),
            "is_group": .object([
                "type": "boolean",
                "description": "Filter to group chats only (true) or DMs only (false)",
            ]),
            "limit": .object([
                "type": "integer",
                "description": "Maximum results to return (default 5)",
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
        let limit: Int

        init(from arguments: [String: Value]?) {
            self.participants = arguments?["participants"]?.arrayValue?.compactMap { $0.stringValue }
            self.name = arguments?["name"]?.stringValue
            self.containsRecent = arguments?["contains_recent"]?.stringValue
            self.isGroup = arguments?["is_group"]?.boolValue
            self.limit = arguments?["limit"]?.intValue ?? 5
        }
    }

    // MARK: - Response Types

    struct ChatResult: Codable {
        let id: String
        let name: String
        let group: Bool?
        let participantCount: Int
        let participantsPreview: [String]
        let lastMessage: LastMessageSummary?
        let participants: [ChatParticipant]
        let match: MatchInfo
        let identity: ChatIdentity

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case group
            case participantCount = "participant_count"
            case participantsPreview = "participants_preview"
            case lastMessage = "last_message"
            case participants
            case match
            case identity
        }
    }

    struct Response: Codable {
        let chats: [ChatResult]
        let more: Bool
    }

    struct ErrorResponse: Codable {
        let error: String
        let message: String
    }

    // MARK: - Tool Registration

    static func register(on server: Server, database: Database, resolver: ContactResolver) {
        server.registerTool(
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
            let error = ErrorResponse(
                error: "validation_error",
                message: "At least one of participants, name, or contains_recent required"
            )
            throw ToolError(content: [.plainText(try FormatUtils.encodeJSON(error))])
        }

        // Initialize contacts if available
        try? await resolver.initialize()

        do {
            var results: [ChatResult] = []

            if let participants = params.participants, !participants.isEmpty {
                let handleGroups = await buildHandleGroups(participants: participants, resolver: resolver)
                if !handleGroups.isEmpty {
                    let chats = try findChatsByHandleGroups(
                        database: database,
                        handleGroups: handleGroups,
                        isGroup: params.isGroup,
                        limit: params.limit
                    )
                    for chat in chats {
                        results.append(try await buildChatResult(
                            database: database,
                            chat: chat,
                            resolver: resolver,
                            matchType: "participants"
                        ))
                    }
                }
            }

            if let name = params.name, results.isEmpty {
                let chats = try findChatsByName(
                    database: database,
                    name: name,
                    limit: params.limit,
                    isGroup: params.isGroup
                )
                for chat in chats {
                    results.append(try await buildChatResult(
                        database: database,
                        chat: chat,
                        resolver: resolver,
                        matchType: "name"
                    ))
                }
            }

            if let containsRecent = params.containsRecent, results.isEmpty {
                let chats = try findChatsByContent(
                    database: database,
                    content: containsRecent,
                    limit: params.limit,
                    isGroup: params.isGroup
                )
                for chat in chats {
                    results.append(try await buildChatResult(
                        database: database,
                        chat: chat,
                        resolver: resolver,
                        matchType: "content"
                    ))
                }
            }

            var seen = Set<String>()
            var uniqueResults: [ChatResult] = []
            for result in results {
                if !seen.contains(result.id) {
                    seen.insert(result.id)
                    uniqueResults.append(result)
                    if uniqueResults.count >= params.limit {
                        break
                    }
                }
            }

            // No cursor on find_chat; never advertise more pages.
            let response = Response(
                chats: uniqueResults,
                more: false
            )

            return [.plainText(try FormatUtils.encodeJSON(response))]

        } catch let dbError as DatabaseError {
            let error: ErrorResponse
            switch dbError {
            case .notFound:
                error = ErrorResponse(error: "database_not_found", message: ClientErrorMessages.databaseNotFound)
            case .permissionDenied:
                error = ErrorResponse(error: "permission_denied", message: ClientErrorMessages.permissionDenied)
            case .queryFailed(let msg):
                error = ErrorResponse(error: "query_failed", message: msg)
            case .invalidData(let msg):
                error = ErrorResponse(error: "invalid_data", message: msg)
            }
            throw ToolError(content: [.plainText(try FormatUtils.encodeJSON(error))])
        } catch {
            let errorResp = ErrorResponse(error: "internal_error", message: ClientErrorMessages.sanitized(error))
            throw ToolError(content: [.plainText(try FormatUtils.encodeJSON(errorResp))])
        }
    }

    // MARK: - Private Helpers


    private static func buildHandleGroups(
        participants: [String],
        resolver: ContactResolver
    ) async -> [[String]] {
        var handleGroups: [[String]] = []

        for participant in participants {
            var groupHandles: [String] = []

            if participant.hasPrefix("+") {
                groupHandles.append(participant)
            } else {
                if let normalized = PhoneUtils.normalizeToE164(participant) {
                    groupHandles.append(normalized)
                }

                let matches = await resolver.searchByName(participant)
                for (handle, _) in matches {
                    if !groupHandles.contains(handle) {
                        groupHandles.append(handle)
                    }
                }
            }

            if !groupHandles.isEmpty {
                handleGroups.append(groupHandles)
            }
        }

        return handleGroups
    }

    /// SQL fragment filtering chats by handle count before LIMIT (groups > 1, DMs <= 1).
    private static func groupFilterSQL(isGroup: Bool?) -> String {
        guard let isGroup else { return "" }
        if isGroup {
            return " AND (SELECT COUNT(*) FROM chat_handle_join chj_g WHERE chj_g.chat_id = c.ROWID) > 1"
        }
        return " AND (SELECT COUNT(*) FROM chat_handle_join chj_g WHERE chj_g.chat_id = c.ROWID) <= 1"
    }

    private static func findChatsByHandleGroups(
        database: Database,
        handleGroups: [[String]],
        isGroup: Bool?,
        limit: Int
    ) throws -> [ChatRow] {
        guard !handleGroups.isEmpty else { return [] }

        // Flatten all handles for initial query
        let allHandles = handleGroups.flatMap { $0 }
        let placeholders = allHandles.map { _ in "?" }.joined(separator: ", ")
        let groupSQL = groupFilterSQL(isGroup: isGroup)

        // Get candidate chats
        let sql = """
            SELECT DISTINCT c.ROWID as id, c.guid, c.display_name
            FROM chat c
            JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
            JOIN handle h ON chj.handle_id = h.ROWID
            WHERE h.id IN (\(placeholders))
            \(groupSQL)
            """

        let candidates = try database.query(sql, params: allHandles) { row in
            ChatRow(
                id: row.int(0),
                guid: row.string(1),
                displayName: row.string(2)
            )
        }

        let sorted: [ChatRow]
        // For single group, filter to those with matching handles
        if handleGroups.count == 1 {
            sorted = try enrichAndSortChats(database: database, chats: candidates, targetCount: 2)
        } else {
            // For multiple groups, filter to chats that have at least one handle from each group
            var matchingChats: [ChatRow] = []

            for chat in candidates {
                let chatHandles = try getChatHandles(database: database, chatId: chat.id)

                var hasAllGroups = true
                for group in handleGroups {
                    if !group.contains(where: { chatHandles.contains($0) }) {
                        hasAllGroups = false
                        break
                    }
                }

                if hasAllGroups {
                    matchingChats.append(chat)
                }
            }

            let targetCount = handleGroups.count + 1  // participants + me
            sorted = try enrichAndSortChats(database: database, chats: matchingChats, targetCount: targetCount)
        }

        return Array(sorted.prefix(limit))
    }

    private static func getChatHandles(database: Database, chatId: Int64) throws -> Set<String> {
        let sql = """
            SELECT h.id
            FROM chat_handle_join chj
            JOIN handle h ON chj.handle_id = h.ROWID
            WHERE chj.chat_id = ?
            """

        let handles = try database.query(sql, params: [chatId]) { row in
            row.string(0) ?? ""
        }

        return Set(handles.filter { !$0.isEmpty })
    }

    private static func enrichAndSortChats(
        database: Database,
        chats: [ChatRow],
        targetCount: Int
    ) throws -> [ChatRow] {
        var enriched: [(chat: ChatRow, participantCount: Int, lastMessageDate: Int64)] = []

        for chat in chats {
            // Get participant count
            let countSql = "SELECT COUNT(*) as cnt FROM chat_handle_join WHERE chat_id = ?"
            let counts = try database.query(countSql, params: [chat.id]) { row in
                Int(row.int(0)) + 1  // +1 for "me"
            }
            let participantCount = counts.first ?? 1

            // Get last message date
            let dateSql = """
                SELECT MAX(m.date) as last_date
                FROM message m
                JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
                WHERE cmj.chat_id = ?
                """
            let dates = try database.query(dateSql, params: [chat.id]) { row in
                row.optionalInt(0) ?? 0
            }
            let lastDate = dates.first ?? 0

            enriched.append((chat, participantCount, lastDate))
        }

        // Sort: exact participant match first, then by recency
        enriched.sort { a, b in
            let aExact = a.participantCount == targetCount ? 0 : 1
            let bExact = b.participantCount == targetCount ? 0 : 1
            if aExact != bExact {
                return aExact < bExact
            }
            return a.lastMessageDate > b.lastMessageDate
        }

        return enriched.map { $0.chat }
    }

    private static func findChatsByName(
        database: Database,
        name: String,
        limit: Int,
        isGroup: Bool?
    ) throws -> [ChatRow] {
        let escaped = QueryBuilder.escapeLike(name)
        let groupSQL = groupFilterSQL(isGroup: isGroup)
        let sql = """
            SELECT c.ROWID as id, c.guid, c.display_name
            FROM chat c
            WHERE c.display_name LIKE ? ESCAPE '\\'
            \(groupSQL)
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

    private static func findChatsByContent(
        database: Database,
        content: String,
        limit: Int,
        isGroup: Bool?
    ) throws -> [ChatRow] {
        let escaped = QueryBuilder.escapeLike(content)
        let groupSQL = groupFilterSQL(isGroup: isGroup)
        // Over-fetch: attributedBody matches are confirmed in Swift after typedstream extract.
        let fetchLimit = min(max(limit * 10, 50), 200)
        let sql = """
            SELECT c.ROWID as id, c.guid, c.display_name, m.text, m.attributedBody
            FROM chat c
            JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
            JOIN message m ON cmj.message_id = m.ROWID
            WHERE m.associated_message_type = 0
              AND (
                m.text LIKE ? ESCAPE '\\'
                OR m.attributedBody IS NOT NULL
              )
              \(groupSQL)
            ORDER BY m.date DESC
            LIMIT ?
            """

        let rows = try database.query(sql, params: ["%\(escaped)%", fetchLimit]) { row in
            (
                id: row.int(0),
                guid: row.string(1),
                displayName: row.string(2),
                text: row.string(3),
                attributedBody: row.blob(4)
            )
        }

        let needle = content.lowercased()
        var seen = Set<Int64>()
        var chats: [ChatRow] = []
        for row in rows {
            let extracted = MessageTextExtractor.extract(text: row.text, attributedBody: row.attributedBody)
            guard let extracted, extracted.lowercased().contains(needle) else { continue }
            if seen.insert(row.id).inserted {
                chats.append(ChatRow(id: row.id, guid: row.guid, displayName: row.displayName))
                if chats.count >= limit { break }
            }
        }
        return chats
    }

    private static func buildChatResult(
        database: Database,
        chat: ChatRow,
        resolver: ContactResolver,
        matchType: String
    ) async throws -> ChatResult {
        // Get participants
        let participantSql = """
            SELECT h.id, h.service
            FROM chat_handle_join chj
            JOIN handle h ON chj.handle_id = h.ROWID
            WHERE chj.chat_id = ?
            ORDER BY h.id ASC
            """

        let participantRows = try database.query(participantSql, params: [chat.id]) { row in
            (handle: row.string(0) ?? "", service: row.string(1))
        }

        var participants: [ChatParticipant] = []
        var identityParticipants: [ChatIdentity.Participant] = []
        for p in participantRows {
            let resolvedName = await resolver.resolve(p.handle)
            let identityParticipant = ChatIdentity.makeParticipant(
                handle: p.handle,
                contactName: resolvedName
            )
            participants.append(ChatParticipant(name: identityParticipant.displayName, handle: p.handle))
            identityParticipants.append(identityParticipant)
        }

        let isGroup = participants.count > 1

        let identity = ChatIdentity(
            mcpId: "chat\(chat.id)",
            guid: chat.guid,
            explicitName: chat.displayName,
            participants: identityParticipants
        )

        // Get last message
        let lastMsgSql = """
            SELECT m.ROWID, m.text, m.attributedBody, m.date, m.is_from_me, h.id as sender_handle
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE cmj.chat_id = ?
            AND m.associated_message_type = 0
            ORDER BY m.date DESC
            LIMIT 1
            """

        let lastMsgRows = try database.query(lastMsgSql, params: [chat.id]) { row in
            (
                messageId: row.int(0),
                text: row.string(1),
                attributedBody: row.blob(2),
                date: row.optionalInt(3),
                isFromMe: row.int(4) == 1,
                senderHandle: row.string(5)
            )
        }

        var lastMessage: LastMessageSummary? = nil
        if let lastMsg = lastMsgRows.first {
            let sender: String
            if lastMsg.isFromMe {
                sender = "Me"
            } else if let handle = lastMsg.senderHandle {
                sender = await IdentityDisplayFormatter.displayName(handle: handle, resolver: resolver)
            } else {
                sender = "unknown"
            }

            let date = AppleTime.toDate(lastMsg.date)

            lastMessage = LastMessageSummary(
                from: sender,
                text: try MessagePreviewResolver.messageSummary(
                    db: database,
                    messageId: lastMsg.messageId,
                    text: lastMsg.text,
                    attributedBody: lastMsg.attributedBody,
                    maxLength: 50
                ),
                ago: TimeUtils.formatCompactRelative(date),
                ts: TimeUtils.formatISO(date)
            )
        }

        return ChatResult(
            id: identity.mcpId,
            name: identity.displayName,
            group: isGroup ? true : nil,
            participantCount: identity.participantCount,
            participantsPreview: try ChatSummaryBuilder.participantsPreview(
                db: database,
                chatId: chat.id,
                identity: identity
            ),
            lastMessage: lastMessage,
            participants: participants,
            match: MatchInfo(type: matchType),
            identity: identity
        )
    }


}

// MARK: - Supporting Types

private struct ChatRow {
    let id: Int64
    let guid: String?
    let displayName: String?
}
