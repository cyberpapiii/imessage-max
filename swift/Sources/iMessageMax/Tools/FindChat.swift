// Sources/iMessageMax/Tools/FindChat.swift
import Foundation
import MCP

/// Find chats by participants, name, or recent content.
enum FindChatTool {
    static let name = "find_chat"
    static let description = "Find chats by participants, name, or recent content"

    // MARK: - Input Schema

    static let inputSchema: Value = .object([
        "type": "object",
        "properties": .object([
            "participants": .object([
                "type": "array",
                "items": .object(["type": "string"]),
                "description": "List of participant names or phone numbers to match",
            ]),
            "name": .object([
                "type": "string",
                "description": "Chat display name to search for (fuzzy match)",
            ]),
            "contains_recent": .object([
                "type": "string",
                "description": "Text that appears in recent messages",
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
        let participants: [[String: String]]
        let group: Bool?
        let last: LastMessage?
        let match: String
    }

    struct LastMessage: Codable {
        let from: String
        let text: String
        let ago: String
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

        // Validate that at least one search parameter is provided
        guard params.participants != nil || params.name != nil || params.containsRecent != nil else {
            let error = ErrorResponse(
                error: "validation_error",
                message: "At least one of participants, name, or contains_recent required"
            )
            return [.text(try FormatUtils.encodeJSON(error))]
        }

        // Initialize contacts if available
        try? await resolver.initialize()

        do {
            var results: [ChatResult] = []

            // Strategy 1: Search by participant handles
            if let participants = params.participants, !participants.isEmpty {
                let handleGroups = await buildHandleGroups(participants: participants, resolver: resolver)
                if !handleGroups.isEmpty {
                    let chats = try findChatsByHandleGroups(database: database, handleGroups: handleGroups)
                    for chat in chats {
                        var chatResult = try await buildChatResult(database: database, chat: chat, resolver: resolver)
                        chatResult = ChatResult(
                            id: chatResult.id,
                            name: chatResult.name,
                            participants: chatResult.participants,
                            group: chatResult.group,
                            last: chatResult.last,
                            match: "participants"
                        )
                        results.append(chatResult)
                    }
                }
            }

            // Strategy 2: Search by display name (only if no participant results)
            if let name = params.name, results.isEmpty {
                let chats = try findChatsByName(database: database, name: name, limit: params.limit)
                for chat in chats {
                    var chatResult = try await buildChatResult(database: database, chat: chat, resolver: resolver)
                    chatResult = ChatResult(
                        id: chatResult.id,
                        name: chatResult.name,
                        participants: chatResult.participants,
                        group: chatResult.group,
                        last: chatResult.last,
                        match: "name"
                    )
                    results.append(chatResult)
                }
            }

            // Strategy 3: Search by recent content (only if no results yet)
            if let containsRecent = params.containsRecent, results.isEmpty {
                let chats = try findChatsByContent(database: database, content: containsRecent, limit: params.limit)
                for chat in chats {
                    var chatResult = try await buildChatResult(database: database, chat: chat, resolver: resolver)
                    chatResult = ChatResult(
                        id: chatResult.id,
                        name: chatResult.name,
                        participants: chatResult.participants,
                        group: chatResult.group,
                        last: chatResult.last,
                        match: "content"
                    )
                    results.append(chatResult)
                }
            }

            // Filter by is_group if specified
            if let isGroup = params.isGroup {
                results = results.filter { ($0.group ?? false) == isGroup }
            }

            // Deduplicate and limit
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

            let response = Response(
                chats: uniqueResults,
                more: results.count > params.limit
            )

            return [.text(try FormatUtils.encodeJSON(response))]

        } catch let dbError as DatabaseError {
            let error: ErrorResponse
            switch dbError {
            case .notFound(let path):
                error = ErrorResponse(error: "database_not_found", message: "Database not found at \(path)")
            case .permissionDenied(let path):
                error = ErrorResponse(error: "permission_denied", message: "Permission denied for \(path)")
            case .queryFailed(let msg):
                error = ErrorResponse(error: "query_failed", message: msg)
            case .invalidData(let msg):
                error = ErrorResponse(error: "invalid_data", message: msg)
            }
            return [.text(try FormatUtils.encodeJSON(error))]
        } catch {
            let errorResp = ErrorResponse(error: "internal_error", message: error.localizedDescription)
            return [.text(try FormatUtils.encodeJSON(errorResp))]
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

            // If it starts with +, it's already a phone number
            if participant.hasPrefix("+") {
                groupHandles.append(participant)
            } else {
                // Try to normalize as phone number
                if let normalized = PhoneUtils.normalizeToE164(participant) {
                    groupHandles.append(normalized)
                }

                // Also try name lookup via contacts
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

    private static func findChatsByHandleGroups(
        database: Database,
        handleGroups: [[String]]
    ) throws -> [ChatRow] {
        guard !handleGroups.isEmpty else { return [] }

        // Flatten all handles for initial query
        let allHandles = handleGroups.flatMap { $0 }
        let placeholders = allHandles.map { _ in "?" }.joined(separator: ", ")

        // Get candidate chats
        let sql = """
            SELECT DISTINCT c.ROWID as id, c.guid, c.display_name, c.service_name
            FROM chat c
            JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
            JOIN handle h ON chj.handle_id = h.ROWID
            WHERE h.id IN (\(placeholders))
            """

        let candidates = try database.query(sql, params: allHandles) { row in
            ChatRow(
                id: row.int(0),
                guid: row.string(1),
                displayName: row.string(2),
                serviceName: row.string(3)
            )
        }

        // For single group, filter to those with matching handles
        if handleGroups.count == 1 {
            return try enrichAndSortChats(database: database, chats: candidates, targetCount: 2)
        }

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
        return try enrichAndSortChats(database: database, chats: matchingChats, targetCount: targetCount)
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
        limit: Int
    ) throws -> [ChatRow] {
        let escaped = QueryBuilder.escapeLike(name)
        let sql = """
            SELECT c.ROWID as id, c.guid, c.display_name, c.service_name
            FROM chat c
            WHERE c.display_name LIKE ? ESCAPE '\\'
            LIMIT ?
            """

        return try database.query(sql, params: ["%\(escaped)%", limit]) { row in
            ChatRow(
                id: row.int(0),
                guid: row.string(1),
                displayName: row.string(2),
                serviceName: row.string(3)
            )
        }
    }

    private static func findChatsByContent(
        database: Database,
        content: String,
        limit: Int
    ) throws -> [ChatRow] {
        let escaped = QueryBuilder.escapeLike(content)
        let sql = """
            SELECT DISTINCT c.ROWID as id, c.guid, c.display_name, c.service_name
            FROM chat c
            JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
            JOIN message m ON cmj.message_id = m.ROWID
            WHERE m.text LIKE ? ESCAPE '\\'
            ORDER BY m.date DESC
            LIMIT ?
            """

        return try database.query(sql, params: ["%\(escaped)%", limit]) { row in
            ChatRow(
                id: row.int(0),
                guid: row.string(1),
                displayName: row.string(2),
                serviceName: row.string(3)
            )
        }
    }

    private static func buildChatResult(
        database: Database,
        chat: ChatRow,
        resolver: ContactResolver
    ) async throws -> ChatResult {
        // Get participants
        let participantSql = """
            SELECT h.id, h.service
            FROM chat_handle_join chj
            JOIN handle h ON chj.handle_id = h.ROWID
            WHERE chj.chat_id = ?
            """

        let participantRows = try database.query(participantSql, params: [chat.id]) { row in
            (handle: row.string(0) ?? "", service: row.string(1))
        }

        var participants: [[String: String]] = []
        for p in participantRows {
            var info: [String: String] = ["handle": p.handle]

            // Try to resolve name from contacts
            if let name = await resolver.resolve(p.handle) {
                info["name"] = name
            } else {
                // Format phone number for display
                info["name"] = PhoneUtils.formatDisplay(p.handle)
            }

            participants.append(info)
        }

        let isGroup = participants.count > 1

        // Generate display name if not set
        var displayName = chat.displayName ?? ""
        if displayName.isEmpty {
            displayName = DisplayNameGenerator.fromNames(participants.compactMap { $0["name"] })
        }

        // Get last message
        let lastMsgSql = """
            SELECT m.text, m.date, m.is_from_me, h.id as sender_handle
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
                text: row.string(0),
                date: row.optionalInt(1),
                isFromMe: row.int(2) == 1,
                senderHandle: row.string(3)
            )
        }

        var lastMessage: LastMessage? = nil
        if let lastMsg = lastMsgRows.first {
            let sender: String
            if lastMsg.isFromMe {
                sender = "me"
            } else if let handle = lastMsg.senderHandle,
                      let name = await resolver.resolve(handle) {
                sender = name
            } else if let handle = lastMsg.senderHandle {
                sender = PhoneUtils.formatDisplay(handle)
            } else {
                sender = "unknown"
            }

            let date = AppleTime.toDate(lastMsg.date)
            let ago = TimeUtils.formatCompactRelative(date) ?? ""
            let text = (lastMsg.text ?? "").prefix(50)

            lastMessage = LastMessage(
                from: sender,
                text: String(text),
                ago: ago
            )
        }

        return ChatResult(
            id: "chat\(chat.id)",
            name: displayName,
            participants: participants,
            group: isGroup ? true : nil,
            last: lastMessage,
            match: ""
        )
    }


}

// MARK: - Supporting Types

private struct ChatRow {
    let id: Int64
    let guid: String?
    let displayName: String?
    let serviceName: String?
}
