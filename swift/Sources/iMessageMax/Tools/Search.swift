// Sources/iMessageMax/Tools/Search.swift
import Foundation
import MCP

/// Sort order for search results
enum SearchSort: String {
    case recentFirst = "recent_first"
    case oldestFirst = "oldest_first"
}

/// Response format for search results
enum SearchFormat: String {
    case flat = "flat"
    case groupedByChat = "grouped_by_chat"
}

/// Individual search result
struct SearchResult: Codable {
    let id: String
    let ts: String?
    let ago: String?
    let from: String
    let text: String?
    let chat: String
    let chatName: String?
    var contextBefore: [SearchContextMessage]?
    var contextAfter: [SearchContextMessage]?

    enum CodingKeys: String, CodingKey {
        case id, ts, ago, from, text, chat
        case chatName = "chat_name"
        case contextBefore = "context_before"
        case contextAfter = "context_after"
    }
}

/// Context message for search results
struct SearchContextMessage: Codable {
    let id: String
    let ts: String?
    let from: String
    let text: String?
}

/// Grouped chat for grouped search response
struct SearchGroupedChat: Codable {
    let id: String
    let name: String?
    let matchCount: Int
    let firstMatch: String?
    let lastMatch: String?
    let sampleMessages: [SearchSampleMessage]

    enum CodingKeys: String, CodingKey {
        case id, name
        case matchCount = "match_count"
        case firstMatch = "first_match"
        case lastMatch = "last_match"
        case sampleMessages = "sample_messages"
    }
}

/// Sample message in grouped response
struct SearchSampleMessage: Codable {
    let id: String
    let text: String?
    let from: String
    let ts: String?
}

/// Person info for search results
struct SearchPersonInfo: Codable {
    let name: String
    let handle: String?
    let isMe: Bool?

    enum CodingKeys: String, CodingKey {
        case name, handle
        case isMe = "is_me"
    }
}

/// Flat search response
struct SearchFlatResponse: Codable {
    let results: [SearchResult]
    let people: [String: SearchPersonInfo]
    let total: Int
    let more: Bool
    let cursor: String?
}

/// Grouped search response
struct SearchGroupedResponse: Codable {
    let chats: [SearchGroupedChat]
    let people: [String: SearchPersonInfo]
    let total: Int
    let chatCount: Int
    let query: String?
    let more: Bool
    let cursor: String?

    enum CodingKeys: String, CodingKey {
        case chats, people, total, query, more, cursor
        case chatCount = "chat_count"
    }
}

/// Error response for search
struct SearchError: Error, Codable {
    let error: String
    let message: String
}

/// Implementation of the search tool
enum SearchTool {
    // Default unanswered window in hours
    static let defaultUnansweredHours = 24

    // MARK: - Tool Registration

    static func register(on server: Server, db: Database, resolver: ContactResolver) {
        let inputSchema: Value = .object([
            "type": "object",
            "properties": .object([
                "query": .object([
                    "type": "string",
                    "description": "Text to search for (optional if filters provided)"
                ]),
                "from_person": .object([
                    "type": "string",
                    "description": "Filter to messages from this person (or \"me\")"
                ]),
                "in_chat": .object([
                    "type": "string",
                    "description": "Chat ID to search within (e.g., \"chat123\")"
                ]),
                "is_group": .object([
                    "type": "boolean",
                    "description": "True for groups only, False for DMs only"
                ]),
                "has": .object([
                    "type": "string",
                    "description": "Content type filter",
                    "enum": ["link", "image", "video", "attachment"]
                ]),
                "since": .object([
                    "type": "string",
                    "description": "Time bound (ISO, relative like \"24h\"/\"7d\", or natural like \"yesterday\"/\"last tuesday\"/\"2 weeks ago\")"
                ]),
                "match_all": .object([
                    "type": "boolean",
                    "description": "If true, require ALL words to match. If false (default), match ANY word.",
                    "default": .bool(false)
                ]),
                "fuzzy": .object([
                    "type": "boolean",
                    "description": "Enable typo-tolerant matching (allows 1-2 character differences). Useful for finding messages with typos.",
                    "default": .bool(false)
                ]),
                "before": .object([
                    "type": "string",
                    "description": "Upper time bound"
                ]),
                "limit": .object([
                    "type": "integer",
                    "description": "Max results (default 20, max 100)",
                    "default": .int(20)
                ]),
                "sort": .object([
                    "type": "string",
                    "description": "Sort order",
                    "enum": ["recent_first", "oldest_first"],
                    "default": "recent_first"
                ]),
                "format": .object([
                    "type": "string",
                    "description": "Response format",
                    "enum": ["flat", "grouped_by_chat"],
                    "default": "flat"
                ]),
                "include_context": .object([
                    "type": "boolean",
                    "description": "Include messages before/after each result",
                    "default": false
                ]),
                "unanswered": .object([
                    "type": "boolean",
                    "description": "Only return messages from me that didn't receive a reply",
                    "default": false
                ]),
                "unanswered_hours": .object([
                    "type": "integer",
                    "description": "Window in hours to check for replies (default 24)",
                    "default": .int(24)
                ])
            ]),
            "additionalProperties": false
        ])

        server.registerTool(
            name: "search",
            description: """
                Full-text search across messages with advanced filtering.

                Search features:
                - Multi-word: "costa rica trip" matches ANY word by default
                - match_all: true requires ALL words to be present
                - fuzzy: true handles typos (costarcia → costa rica)

                Time filters (since/before):
                - Relative: "24h", "7d", "2w", "3m"
                - Natural: "yesterday", "last tuesday", "2 weeks ago", "this month"
                - ISO: "2024-01-15T10:30:00Z"

                Examples:
                - search(query: "costa rica trip") - find any of these words
                - search(query: "costa rica", match_all: true) - must have both words
                - search(query: "volcno", fuzzy: true) - finds "volcano" despite typo
                - search(from_person: "me", since: "last monday") - my messages since Monday
                - search(has: "link", in_chat: "chat123") - links in a specific chat
                - search(unanswered: true) - questions I sent without replies
                """,
            inputSchema: inputSchema,
            annotations: Tool.Annotations(
                title: "Search Messages",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            // Extract parameters
            let query = arguments?["query"]?.stringValue
            let fromPerson = arguments?["from_person"]?.stringValue
            let inChat = arguments?["in_chat"]?.stringValue
            let isGroup = arguments?["is_group"]?.boolValue
            let has = arguments?["has"]?.stringValue
            let since = arguments?["since"]?.stringValue
            let before = arguments?["before"]?.stringValue
            let limit = arguments?["limit"]?.intValue ?? 20
            let sort = arguments?["sort"]?.stringValue ?? "recent_first"
            let format = arguments?["format"]?.stringValue ?? "flat"
            let includeContext = arguments?["include_context"]?.boolValue ?? false
            let unanswered = arguments?["unanswered"]?.boolValue ?? false
            let unansweredHours = arguments?["unanswered_hours"]?.intValue ?? 24
            let matchAll = arguments?["match_all"]?.boolValue ?? false
            let fuzzy = arguments?["fuzzy"]?.boolValue ?? false

            let result = await execute(
                query: query,
                fromPerson: fromPerson,
                inChat: inChat,
                isGroup: isGroup,
                has: has,
                since: since,
                before: before,
                limit: limit,
                sort: sort,
                format: format,
                includeContext: includeContext,
                unanswered: unanswered,
                unansweredHours: unansweredHours,
                matchAll: matchAll,
                fuzzy: fuzzy,
                db: db,
                resolver: resolver
            )

            switch result {
            case .success(let json):
                return [.text(json)]
            case .failure(let error):
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let errorJson = try encoder.encode(error)
                return [.text(String(data: errorJson, encoding: .utf8) ?? "{}")]
            }
        }
    }

    /// Full-text search across messages with advanced filtering
    static func execute(
        query: String? = nil,
        fromPerson: String? = nil,
        inChat: String? = nil,
        isGroup: Bool? = nil,
        has: String? = nil,
        since: String? = nil,
        before: String? = nil,
        limit: Int = 20,
        sort: String = "recent_first",
        format: String = "flat",
        includeContext: Bool = false,
        unanswered: Bool = false,
        unansweredHours: Int = 24,
        matchAll: Bool = false,
        fuzzy: Bool = false,
        db: Database = Database(),
        resolver: ContactResolver
    ) async -> Result<String, SearchError> {
        // Validate inputs
        let hasFilter = fromPerson != nil || inChat != nil || isGroup != nil ||
                        has != nil || since != nil || before != nil || unanswered
        let hasQuery = query != nil &&
                       !(query?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)

        if !hasQuery && !hasFilter {
            return .failure(SearchError(
                error: "invalid_query",
                message: "Query or at least one filter required"
            ))
        }

        // Clamp limit
        let clampedLimit = max(1, min(limit, 100))
        let sortOrder = SearchSort(rawValue: sort) ?? .recentFirst
        let responseFormat = SearchFormat(rawValue: format) ?? .flat

        // Initialize contacts
        try? await resolver.initialize()

        do {
            // Build and execute query
            // Fetch more rows if we need to filter by text in Swift
            // (since attributedBody can't be searched in SQL)
            // Use a higher multiplier to improve search coverage without time filters
            let fetchLimit = (hasQuery || unanswered) ? max(500, clampedLimit * 10) : clampedLimit

            let (sql, params) = buildQuery(
                query: query,
                fromPerson: fromPerson,
                inChat: inChat,
                isGroup: isGroup,
                has: has,
                since: since,
                before: before,
                limit: fetchLimit,
                sort: sortOrder,
                unanswered: unanswered
            )

            var rows = try db.query(sql, params: params) { row in
                SearchRow(
                    msgId: row.int(0),
                    msgGuid: row.string(1) ?? "",
                    text: row.string(2),
                    attributedBody: row.blob(3),
                    date: row.optionalInt(4),
                    isFromMe: row.int(5) != 0,
                    senderHandle: row.string(6),
                    chatId: row.int(7),
                    chatGuid: row.string(8) ?? "",
                    chatDisplayName: row.string(9)
                )
            }

            // Filter by search query in Swift (since we can't search attributedBody in SQL)
            // Supports multi-word search: OR (any word) by default, AND (all words) with matchAll=true
            // With fuzzy=true, also matches words within 1-2 edits (handles typos)
            if hasQuery, let searchQuery = query?.trimmingCharacters(in: .whitespaces).lowercased(), !searchQuery.isEmpty {
                // Split query into words (minimum 2 chars each to avoid noise)
                let searchWords = searchQuery.split(separator: " ")
                    .map { String($0).lowercased() }
                    .filter { $0.count >= 2 }

                if !searchWords.isEmpty {
                    rows = rows.filter { row in
                        let extractedText = MessageTextExtractor.extract(text: row.text, attributedBody: row.attributedBody)
                        guard let text = extractedText?.lowercased() else { return false }

                        // Split message text into words for fuzzy matching
                        let textWords = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                            .map { String($0).lowercased() }

                        if matchAll {
                            // AND logic: all search words must be present
                            return searchWords.allSatisfy { searchWord in
                                wordMatches(searchWord: searchWord, in: text, textWords: textWords, fuzzy: fuzzy)
                            }
                        } else {
                            // OR logic: any word matches
                            return searchWords.contains { searchWord in
                                wordMatches(searchWord: searchWord, in: text, textWords: textWords, fuzzy: fuzzy)
                            }
                        }
                    }
                }
            }

            // Filter for unanswered if requested
            if unanswered {
                rows = try filterUnanswered(
                    db: db,
                    rows: rows,
                    limit: clampedLimit,
                    hours: unansweredHours
                )
            }

            // Trim to requested limit after filtering
            if rows.count > clampedLimit {
                rows = Array(rows.prefix(clampedLimit))
            }

            // Build response
            let jsonString: String
            if responseFormat == .groupedByChat {
                jsonString = try await buildGroupedResponse(
                    db: db,
                    rows: rows,
                    query: query,
                    resolver: resolver
                )
            } else {
                jsonString = try await buildFlatResponse(
                    db: db,
                    rows: rows,
                    limit: clampedLimit,
                    includeContext: includeContext,
                    resolver: resolver
                )
            }

            return .success(jsonString)

        } catch let dbError as DatabaseError {
            switch dbError {
            case .notFound(let path):
                return .failure(SearchError(error: "database_not_found", message: "Database not found at \(path)"))
            case .permissionDenied(let path):
                return .failure(SearchError(error: "permission_denied", message: "Permission denied for \(path)"))
            case .queryFailed(let msg):
                return .failure(SearchError(error: "query_failed", message: msg))
            case .invalidData(let msg):
                return .failure(SearchError(error: "invalid_data", message: msg))
            }
        } catch {
            return .failure(SearchError(error: "internal_error", message: error.localizedDescription))
        }
    }

    // MARK: - Query Building

    private static func buildQuery(
        query: String?,
        fromPerson: String?,
        inChat: String?,
        isGroup: Bool?,
        has: String?,
        since: String?,
        before: String?,
        limit: Int,
        sort: SearchSort,
        unanswered: Bool
    ) -> (String, [Any]) {
        let builder = QueryBuilder()
            .select(
                "m.ROWID as msg_id",
                "m.guid as msg_guid",
                "m.text",
                "m.attributedBody",
                "m.date",
                "m.is_from_me",
                "h.id as sender_handle",
                "c.ROWID as chat_id",
                "c.guid as chat_guid",
                "c.display_name as chat_display_name"
            )
            .from("message m")
            .join("chat_message_join cmj ON m.ROWID = cmj.message_id")
            .join("chat c ON cmj.chat_id = c.ROWID")
            .leftJoin("handle h ON m.handle_id = h.ROWID")
            .where("m.associated_message_type = ?", 0)

        // NOTE: Text search is done in Swift after fetching, not in SQL
        // This is because many messages have text in attributedBody (binary blob)
        // instead of the text column, and SQLite can't search binary blobs effectively.
        // We fetch more rows and filter in Swift after extracting text from both columns.

        // Ensure we have text content (either in text or attributedBody)
        if query != nil && !query!.isEmpty {
            builder.where("(m.text IS NOT NULL OR m.attributedBody IS NOT NULL)")
        }

        // Time filters
        if let sinceStr = since, let sinceTs = AppleTime.parse(sinceStr) {
            builder.where("m.date >= ?", sinceTs)
        }

        if let beforeStr = before, let beforeTs = AppleTime.parse(beforeStr) {
            builder.where("m.date <= ?", beforeTs)
        }

        // Chat filter
        if let chatStr = inChat {
            let chatIdStr = chatStr.hasPrefix("chat") ? String(chatStr.dropFirst(4)) : chatStr
            if let chatId = Int64(chatIdStr) {
                builder.where("c.ROWID = ?", chatId)
            } else {
                builder.where("c.guid LIKE ? ESCAPE '\\'", "%\(QueryBuilder.escapeLike(chatStr))%")
            }
        }

        // From filter (unanswered implies from_me)
        if unanswered {
            builder.where("m.is_from_me = ?", 1)
        } else if let person = fromPerson {
            if person.lowercased() == "me" {
                builder.where("m.is_from_me = ?", 1)
            } else {
                builder.where("h.id LIKE ? ESCAPE '\\'", "%\(QueryBuilder.escapeLike(person))%")
            }
        }

        // Group filter
        if let isGroupChat = isGroup {
            if isGroupChat {
                builder.where(
                    "(SELECT COUNT(*) FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID) > ?",
                    1)
            } else {
                builder.where(
                    "(SELECT COUNT(*) FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID) = ?",
                    1)
            }
        }

        // Has filter (content type)
        if let hasType = has {
            switch hasType {
            case "link":
                builder.where("m.text LIKE ?", "%http%")
            case "image", "video", "attachment":
                builder.where("""
                    EXISTS (
                        SELECT 1 FROM attachment a
                        JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
                        WHERE maj.message_id = m.ROWID
                    )
                    """)
            default:
                break
            }
        }

        // Sort
        if sort == .oldestFirst {
            builder.orderBy("m.date ASC")
        } else {
            builder.orderBy("m.date DESC")
        }

        builder.limit(limit)

        return builder.build()
    }

    // MARK: - Unanswered Filtering

    private static func looksLikeQuestion(_ text: String?) -> Bool {
        guard let text = text, !text.isEmpty else { return false }

        let textLower = text.lowercased().trimmingCharacters(in: .whitespaces)

        // Contains question mark
        if text.contains("?") { return true }

        // Ends with common question/request patterns
        let questionEndings = [
            "what do you think",
            "let me know",
            "thoughts",
            "can you",
            "could you",
            "would you",
            "will you",
            "please",
            "lmk"
        ]

        for ending in questionEndings {
            if textLower.hasSuffix(ending) { return true }
        }

        return false
    }

    private static func hasReplyWithinWindow(
        db: Database,
        chatId: Int64,
        messageDate: Int64,
        hours: Int
    ) throws -> Bool {
        let windowNs = Int64(hours) * 60 * 60 * 1_000_000_000

        let rows = try db.query("""
            SELECT 1 FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            WHERE cmj.chat_id = ?
            AND m.date > ?
            AND m.date <= ?
            AND m.is_from_me = 0
            AND m.associated_message_type = 0
            LIMIT 1
            """,
            params: [chatId, messageDate, messageDate + windowNs]
        ) { _ in true }

        return !rows.isEmpty
    }

    private static func filterUnanswered(
        db: Database,
        rows: [SearchRow],
        limit: Int,
        hours: Int
    ) throws -> [SearchRow] {
        var filtered: [SearchRow] = []

        for row in rows {
            let text = MessageTextExtractor.extract(text: row.text, attributedBody: row.attributedBody)
            guard let date = row.date else { continue }

            let isQuestion = looksLikeQuestion(text)
            let hasReply = try hasReplyWithinWindow(
                db: db,
                chatId: row.chatId,
                messageDate: date,
                hours: hours
            )

            if isQuestion && !hasReply {
                filtered.append(row)
                if filtered.count >= limit { break }
            }
        }

        return filtered
    }

    // MARK: - Response Building

    private static func buildFlatResponse(
        db: Database,
        rows: [SearchRow],
        limit: Int,
        includeContext: Bool,
        resolver: ContactResolver
    ) async throws -> String {
        var results: [SearchResult] = []
        var people: [String: SearchPersonInfo] = [:]
        var handleToKey: [String: String] = [:]
        var personCounter = 1
        var chatNamesCache: [Int64: String] = [:]

        for row in rows {
            // Get or create person reference
            let senderKey: String
            if row.isFromMe {
                senderKey = "me"
                if people["me"] == nil {
                    people["me"] = SearchPersonInfo(name: "Me", handle: nil, isMe: true)
                }
            } else {
                let handle = row.senderHandle ?? "unknown"
                if let existingKey = handleToKey[handle] {
                    senderKey = existingKey
                } else {
                    let name = await resolver.resolve(handle)
                    let key: String
                    if let resolvedName = name {
                        let firstName = resolvedName.split(separator: " ").first.map(String.init)
                                        ?? resolvedName
                        key = generateUniqueKey(baseName: firstName.lowercased(), existing: people)
                    } else {
                        key = "p\(personCounter)"
                        personCounter += 1
                    }
                    handleToKey[handle] = key
                    people[key] = SearchPersonInfo(name: name ?? handle, handle: handle, isMe: nil)
                    senderKey = key
                }
            }

            let text = MessageTextExtractor.extract(text: row.text, attributedBody: row.attributedBody)
            let msgDate = AppleTime.toDate(row.date)

            // Get chat name with fallback
            var chatName = row.chatDisplayName
            if chatName == nil || chatName?.isEmpty == true {
                if let cached = chatNamesCache[row.chatId] {
                    chatName = cached
                } else {
                    let generatedName = try await generateChatDisplayName(
                        db: db, chatId: row.chatId, resolver: resolver
                    )
                    chatNamesCache[row.chatId] = generatedName
                    chatName = generatedName
                }
            }

            var result = SearchResult(
                id: "msg_\(row.msgId)",
                ts: TimeUtils.formatISO(msgDate),
                ago: TimeUtils.formatCompactRelative(msgDate),
                from: senderKey,
                text: text,
                chat: "chat\(row.chatId)",
                chatName: chatName,
                contextBefore: nil,
                contextAfter: nil
            )

            // Add context if requested
            if includeContext, let msgDate = row.date {
                let (before, after) = try await getContext(
                    db: db,
                    chatId: row.chatId,
                    msgDate: msgDate,
                    people: &people,
                    handleToKey: &handleToKey,
                    personCounter: &personCounter,
                    resolver: resolver
                )
                result.contextBefore = before.isEmpty ? nil : before
                result.contextAfter = after.isEmpty ? nil : after
            }

            results.append(result)
        }

        let response = SearchFlatResponse(
            results: results,
            people: people,
            total: results.count,
            more: results.count >= limit,
            cursor: nil
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(response)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func buildGroupedResponse(
        db: Database,
        rows: [SearchRow],
        query: String?,
        resolver: ContactResolver
    ) async throws -> String {
        var chatsData: [Int64: GroupedChatData] = [:]
        var people: [String: SearchPersonInfo] = [:]
        var handleToKey: [String: String] = [:]
        var personCounter = 1
        var chatNamesCache: [Int64: String] = [:]

        for row in rows {
            let chatId = row.chatId

            // Get or create person reference
            let senderKey: String
            if row.isFromMe {
                senderKey = "me"
                if people["me"] == nil {
                    people["me"] = SearchPersonInfo(name: "Me", handle: nil, isMe: true)
                }
            } else {
                let handle = row.senderHandle ?? "unknown"
                if let existingKey = handleToKey[handle] {
                    senderKey = existingKey
                } else {
                    let name = await resolver.resolve(handle)
                    let key: String
                    if let resolvedName = name {
                        let firstName = resolvedName.split(separator: " ").first.map(String.init)
                                        ?? resolvedName
                        key = generateUniqueKey(baseName: firstName.lowercased(), existing: people)
                    } else {
                        key = "p\(personCounter)"
                        personCounter += 1
                    }
                    handleToKey[handle] = key
                    people[key] = SearchPersonInfo(name: name ?? handle, handle: handle, isMe: nil)
                    senderKey = key
                }
            }

            let text = MessageTextExtractor.extract(text: row.text, attributedBody: row.attributedBody)
            let msgDate = AppleTime.toDate(row.date)

            // Get chat name with fallback
            var chatName = row.chatDisplayName
            if chatName == nil || chatName?.isEmpty == true {
                if let cached = chatNamesCache[chatId] {
                    chatName = cached
                } else {
                    let generatedName = try await generateChatDisplayName(
                        db: db, chatId: chatId, resolver: resolver
                    )
                    chatNamesCache[chatId] = generatedName
                    chatName = generatedName
                }
            }

            if chatsData[chatId] == nil {
                chatsData[chatId] = GroupedChatData(
                    id: "chat\(chatId)",
                    name: chatName,
                    matchCount: 0,
                    firstMatchDate: msgDate,
                    lastMatchDate: msgDate,
                    sampleMessages: []
                )
            }

            var chat = chatsData[chatId]!
            chat.matchCount += 1

            if let date = msgDate {
                if chat.firstMatchDate == nil || date < chat.firstMatchDate! {
                    chat.firstMatchDate = date
                }
                if chat.lastMatchDate == nil || date > chat.lastMatchDate! {
                    chat.lastMatchDate = date
                }
            }

            // Add sample messages (up to 3)
            if chat.sampleMessages.count < 3 {
                chat.sampleMessages.append(SearchSampleMessage(
                    id: "msg_\(row.msgId)",
                    text: text,
                    from: senderKey,
                    ts: TimeUtils.formatISO(msgDate)
                ))
            }

            chatsData[chatId] = chat
        }

        // Convert to response format and sort by match count
        var chats = chatsData.values.map { data in
            SearchGroupedChat(
                id: data.id,
                name: data.name,
                matchCount: data.matchCount,
                firstMatch: TimeUtils.formatISO(data.firstMatchDate),
                lastMatch: TimeUtils.formatISO(data.lastMatchDate),
                sampleMessages: data.sampleMessages
            )
        }
        chats.sort { $0.matchCount > $1.matchCount }

        let response = SearchGroupedResponse(
            chats: chats,
            people: people,
            total: chats.reduce(0) { $0 + $1.matchCount },
            chatCount: chats.count,
            query: query,
            more: false,
            cursor: nil
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(response)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Context Messages

    private static func getContext(
        db: Database,
        chatId: Int64,
        msgDate: Int64,
        people: inout [String: SearchPersonInfo],
        handleToKey: inout [String: String],
        personCounter: inout Int,
        resolver: ContactResolver
    ) async throws -> ([SearchContextMessage], [SearchContextMessage]) {
        // Get 2 messages before
        let beforeRows = try db.query("""
            SELECT m.ROWID as msg_id, m.text, m.attributedBody, m.date, m.is_from_me, h.id as sender_handle
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE cmj.chat_id = ? AND m.date < ? AND m.associated_message_type = 0
            ORDER BY m.date DESC LIMIT 2
            """,
            params: [chatId, msgDate]
        ) { row in
            ContextRow(
                msgId: row.int(0),
                text: row.string(1),
                attributedBody: row.blob(2),
                date: row.optionalInt(3),
                isFromMe: row.int(4) != 0,
                senderHandle: row.string(5)
            )
        }

        // Get 2 messages after
        let afterRows = try db.query("""
            SELECT m.ROWID as msg_id, m.text, m.attributedBody, m.date, m.is_from_me, h.id as sender_handle
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE cmj.chat_id = ? AND m.date > ? AND m.associated_message_type = 0
            ORDER BY m.date ASC LIMIT 2
            """,
            params: [chatId, msgDate]
        ) { row in
            ContextRow(
                msgId: row.int(0),
                text: row.string(1),
                attributedBody: row.blob(2),
                date: row.optionalInt(3),
                isFromMe: row.int(4) != 0,
                senderHandle: row.string(5)
            )
        }

        var contextBefore: [SearchContextMessage] = []
        var contextAfter: [SearchContextMessage] = []

        // Format before messages (reverse for chronological order)
        for row in beforeRows.reversed() {
            let msg = await formatContextMessage(
                row: row,
                people: &people,
                handleToKey: &handleToKey,
                personCounter: &personCounter,
                resolver: resolver
            )
            contextBefore.append(msg)
        }

        // Format after messages
        for row in afterRows {
            let msg = await formatContextMessage(
                row: row,
                people: &people,
                handleToKey: &handleToKey,
                personCounter: &personCounter,
                resolver: resolver
            )
            contextAfter.append(msg)
        }

        return (contextBefore, contextAfter)
    }

    private static func formatContextMessage(
        row: ContextRow,
        people: inout [String: SearchPersonInfo],
        handleToKey: inout [String: String],
        personCounter: inout Int,
        resolver: ContactResolver
    ) async -> SearchContextMessage {
        let senderKey: String
        if row.isFromMe {
            senderKey = "me"
            if people["me"] == nil {
                people["me"] = SearchPersonInfo(name: "Me", handle: nil, isMe: true)
            }
        } else {
            let handle = row.senderHandle ?? "unknown"
            if let existingKey = handleToKey[handle] {
                senderKey = existingKey
            } else {
                let name = await resolver.resolve(handle)
                let key: String
                if let resolvedName = name {
                    let firstName = resolvedName.split(separator: " ").first.map(String.init)
                                    ?? resolvedName
                    key = generateUniqueKey(baseName: firstName.lowercased(), existing: people)
                } else {
                    key = "p\(personCounter)"
                    personCounter += 1
                }
                handleToKey[handle] = key
                people[key] = SearchPersonInfo(name: name ?? handle, handle: handle, isMe: nil)
                senderKey = key
            }
        }

        let text = MessageTextExtractor.extract(text: row.text, attributedBody: row.attributedBody)
        let msgDate = AppleTime.toDate(row.date)

        return SearchContextMessage(
            id: "msg_\(row.msgId)",
            ts: TimeUtils.formatISO(msgDate),
            from: senderKey,
            text: text
        )
    }

    // MARK: - Helpers

    private static func generateUniqueKey(
        baseName: String,
        existing: [String: SearchPersonInfo]
    ) -> String {
        if existing[baseName] == nil { return baseName }

        var suffix = 2
        while existing["\(baseName)\(suffix)"] != nil {
            suffix += 1
        }
        return "\(baseName)\(suffix)"
    }

    /// Check if a search word matches anywhere in the text
    /// - Parameters:
    ///   - searchWord: The word to search for
    ///   - text: The full message text (for exact contains match)
    ///   - textWords: Individual words from the message (for fuzzy matching)
    ///   - fuzzy: Whether to use fuzzy/typo-tolerant matching
    /// - Returns: True if the word matches
    private static func wordMatches(searchWord: String, in text: String, textWords: [String], fuzzy: Bool) -> Bool {
        // Always try exact substring match first (fast)
        if text.contains(searchWord) {
            return true
        }

        // If fuzzy matching enabled, check for close matches
        if fuzzy {
            // Calculate max allowed distance based on word length
            // Short words (3-4 chars): 1 edit, longer words: 2 edits
            let maxDistance = searchWord.count <= 4 ? 1 : 2

            for textWord in textWords {
                // Skip words that are way too different in length
                if abs(textWord.count - searchWord.count) > maxDistance {
                    continue
                }
                // Check Levenshtein distance
                if levenshteinDistance(searchWord, textWord) <= maxDistance {
                    return true
                }
            }
        }

        return false
    }

    /// Calculate Levenshtein edit distance between two strings
    /// Returns the minimum number of single-character edits (insertions, deletions, substitutions)
    /// needed to transform one string into another
    private static func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let m = s1.count
        let n = s2.count

        // Quick checks for empty strings
        if m == 0 { return n }
        if n == 0 { return m }

        // Convert to arrays for indexing
        let chars1 = Array(s1)
        let chars2 = Array(s2)

        // Use two rows instead of full matrix for memory efficiency
        var prevRow = Array(0...n)
        var currRow = Array(repeating: 0, count: n + 1)

        for i in 1...m {
            currRow[0] = i
            for j in 1...n {
                let cost = chars1[i - 1] == chars2[j - 1] ? 0 : 1
                currRow[j] = min(
                    prevRow[j] + 1,      // deletion
                    currRow[j - 1] + 1,  // insertion
                    prevRow[j - 1] + cost // substitution
                )
            }
            swap(&prevRow, &currRow)
        }

        return prevRow[n]
    }

    private static func generateChatDisplayName(
        db: Database,
        chatId: Int64,
        resolver: ContactResolver
    ) async throws -> String {
        // Get participants for this chat
        let participants = try db.query("""
            SELECT h.id as handle
            FROM handle h
            JOIN chat_handle_join chj ON h.ROWID = chj.handle_id
            WHERE chj.chat_id = ?
            """,
            params: [chatId]
        ) { row in
            row.string(0) ?? "unknown"
        }

        if participants.isEmpty {
            return "Unknown Chat"
        }

        var names: [String] = []
        for handle in participants {
            if let name = await resolver.resolve(handle) {
                names.append(name.split(separator: " ").first.map(String.init) ?? name)
            } else {
                names.append(PhoneUtils.formatDisplay(handle))
            }
        }

        return DisplayNameGenerator.fromNames(names)
    }
}

// MARK: - Internal Types

private struct SearchRow {
    let msgId: Int64
    let msgGuid: String
    let text: String?
    let attributedBody: Data?
    let date: Int64?
    let isFromMe: Bool
    let senderHandle: String?
    let chatId: Int64
    let chatGuid: String
    let chatDisplayName: String?
}

private struct ContextRow {
    let msgId: Int64
    let text: String?
    let attributedBody: Data?
    let date: Int64?
    let isFromMe: Bool
    let senderHandle: String?
}

private struct GroupedChatData {
    let id: String
    var name: String?
    var matchCount: Int
    var firstMatchDate: Date?
    var lastMatchDate: Date?
    var sampleMessages: [SearchSampleMessage]
}
