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
            self.limit = max(1, min(arguments?["limit"]?.intValue ?? 5, 50))
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
                let chats = try await findChatsByHandleGroups(
                    database: database,
                    handleGroups: handleGroups,
                    isGroup: params.isGroup,
                    limit: params.limit,
                    resolver: resolver
                )
                results.append(contentsOf: try await buildChatResults(
                    database: database,
                    chats: chats,
                    resolver: resolver,
                    matchType: "participants"
                ))
                }
            }

            if let name = params.name, results.isEmpty {
                let chats = try findChatsByName(
                    database: database,
                    name: name,
                    limit: params.limit,
                    isGroup: params.isGroup
                )
                results.append(contentsOf: try await buildChatResults(
                    database: database,
                    chats: chats,
                    resolver: resolver,
                    matchType: "name"
                ))
            }

            if let containsRecent = params.containsRecent, results.isEmpty {
                let chats = try findChatsByContent(
                    database: database,
                    content: containsRecent,
                    limit: params.limit,
                    isGroup: params.isGroup
                )
                results.append(contentsOf: try await buildChatResults(
                    database: database,
                    chats: chats,
                    resolver: resolver,
                    matchType: "content"
                ))
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
        limit: Int,
        resolver: ContactResolver
    ) async throws -> [ChatRow] {
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
            ORDER BY c.ROWID DESC
            LIMIT 500
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
            let handlesByChat = try await ChatSummaryQueries.participantsByChat(
                db: database,
                chatIds: candidates.map(\.id),
                resolver: resolver
            )
            var matchingChats: [ChatRow] = []

            for chat in candidates {
                let chatHandles = Set((handlesByChat[chat.id] ?? []).map(\.handle))

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

    private static func enrichAndSortChats(
        database: Database,
        chats: [ChatRow],
        targetCount: Int
    ) throws -> [ChatRow] {
        let chatIds = chats.map(\.id)
        let countsByChat = try ChatSummaryQueries.participantCountsByChat(db: database, chatIds: chatIds)
        let datesByChat = try ChatSummaryQueries.lastMessageDatesByChat(db: database, chatIds: chatIds)

        var enriched: [(chat: ChatRow, participantCount: Int, lastMessageDate: Int64)] = []
        for chat in chats {
            let participantCount = (countsByChat[chat.id] ?? 0) + 1  // +1 for "me"
            let lastDate = datesByChat[chat.id] ?? 0
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
                OR (m.text IS NULL AND m.attributedBody IS NOT NULL)
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

    private static func buildChatResults(
        database: Database,
        chats: [ChatRow],
        resolver: ContactResolver,
        matchType: String
    ) async throws -> [ChatResult] {
        let chatIds = chats.map(\.id)
        let participantsByChat = try await ChatSummaryQueries.participantsByChat(
            db: database,
            chatIds: chatIds,
            resolver: resolver
        )
        let lastByChat = try await ChatSummaryQueries.lastMessagesByChat(
            db: database,
            chatIds: chatIds,
            resolver: resolver,
            agoFallback: nil
        )

        var results: [ChatResult] = []
        for chat in chats {
            let participantRows = (participantsByChat[chat.id] ?? []).sorted { $0.handle < $1.handle }

            var participants: [ChatParticipant] = []
            var identityParticipants: [ChatIdentity.Participant] = []
            for p in participantRows {
                let identityParticipant = ChatIdentity.makeParticipant(
                    handle: p.handle,
                    contactName: p.name
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

            results.append(
                ChatResult(
                    id: identity.mcpId,
                    name: identity.displayName,
                    group: isGroup ? true : nil,
                    participantCount: identity.participantCount,
                    participantsPreview: try ChatSummaryBuilder.participantsPreview(
                        db: database,
                        chatId: chat.id,
                        identity: identity
                    ),
                    lastMessage: lastByChat[chat.id]?.info,
                    participants: participants,
                    match: MatchInfo(type: matchType),
                    identity: identity
                )
            )
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
