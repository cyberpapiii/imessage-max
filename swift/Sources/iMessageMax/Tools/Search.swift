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
                "cursor": .object([
                    "type": "string",
                    "description": "Pagination cursor from a previous search response"
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
            let cursor = arguments?["cursor"]?.stringValue
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
                cursor: cursor,
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
                return [.plainText(json)]
            case .failure(let error):
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let errorJson = try encoder.encode(error)
                throw ToolError(content: [.plainText(String(data: errorJson, encoding: .utf8) ?? "{}")])
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
        cursor: String? = nil,
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

            let senderFilter = await resolveFromPersonFilter(fromPerson, resolver: resolver)

            let (sql, params) = buildQuery(
                query: query,
                fromPerson: senderFilter,
                inChat: inChat,
                isGroup: isGroup,
                has: has,
                since: since,
                before: before,
                cursor: cursor.flatMap(decodeCursor),
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
                    limit: clampedLimit,
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

}
