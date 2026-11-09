import Foundation
import MCP

enum SearchSort: String {
    case recentFirst = "recent_first"
    case oldestFirst = "oldest_first"
}

enum SearchFormat: String {
    case flat = "flat"
    case groupedByChat = "grouped_by_chat"
}

struct SearchResult: Codable {
    let id: String
    let chat: ChatReference
    let from: String
    let excerpt: String
    let ago: String?
    let ts: String?
    var contextBefore: [ContextMessage]?
    var contextAfter: [ContextMessage]?
    let reactions: [String]?
    let replyTo: String?
    let replyCount: Int?
    let edited: Bool?

    enum CodingKeys: String, CodingKey {
        case id, chat, from, excerpt, ago, ts
        case contextBefore = "context_before"
        case contextAfter = "context_after"
        case reactions
        case replyTo = "reply_to"
        case replyCount = "reply_count"
        case edited
    }
}

struct SearchGroupedChat: Codable {
    let id: String
    let name: String
    let group: Bool?
    let participantCount: Int
    let participantsPreview: [String]
    let matchCount: Int
    let firstMatch: String?
    let lastMatch: String?
    let results: [SearchSampleMessage]

    enum CodingKeys: String, CodingKey {
        case id, name, group
        case participantCount = "participant_count"
        case participantsPreview = "participants_preview"
        case matchCount = "match_count"
        case firstMatch = "first_match"
        case lastMatch = "last_match"
        case results
    }
}

struct SearchSampleMessage: Codable {
    let id: String
    let from: String
    let excerpt: String
    let ts: String?
}

/// Where a search stopped when its time budget ran out before it filled
/// the page. `searchedTo` is the timestamp of the last message it checked;
/// the cursor goes on from there.
struct SearchScanStop: Equatable {
    let searchedTo: String?
}

struct SearchFlatResponse: Codable {
    let results: [SearchResult]
    let total: Int
    let more: Bool
    let cursor: String?
    let filteredHidden: Int?
    var partial: Bool? = nil
    var searchedTo: String? = nil

    enum CodingKeys: String, CodingKey {
        case results, total, more, cursor, partial
        case filteredHidden = "filtered_hidden"
        case searchedTo = "searched_to"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(results, forKey: .results)
        try container.encode(total, forKey: .total)
        try container.encode(more, forKey: .more)
        try container.encodeIfPresent(cursor, forKey: .cursor)
        try container.encodeIfPresent(partial, forKey: .partial)
        try container.encodeIfPresent(searchedTo, forKey: .searchedTo)
        try container.encodeIfPresent(filteredHidden, forKey: .filteredHidden)
    }
}

struct SearchGroupedResponse: Codable {
    let chats: [SearchGroupedChat]
    let total: Int
    let chatCount: Int
    let query: String?
    let more: Bool
    let cursor: String?
    let filteredHidden: Int?
    var partial: Bool? = nil
    var searchedTo: String? = nil

    enum CodingKeys: String, CodingKey {
        case chats, total, query, more, cursor, partial
        case chatCount = "chat_count"
        case filteredHidden = "filtered_hidden"
        case searchedTo = "searched_to"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(chats, forKey: .chats)
        try container.encode(total, forKey: .total)
        try container.encode(chatCount, forKey: .chatCount)
        try container.encodeIfPresent(query, forKey: .query)
        try container.encode(more, forKey: .more)
        try container.encodeIfPresent(cursor, forKey: .cursor)
        try container.encodeIfPresent(partial, forKey: .partial)
        try container.encodeIfPresent(searchedTo, forKey: .searchedTo)
        try container.encodeIfPresent(filteredHidden, forKey: .filteredHidden)
    }
}

enum SearchTool {
    static let limit = IntArgument(name: "limit", defaultValue: 20, range: 1...100)
    /// How long one call may keep paging through rows that fail the Swift
    /// check before it answers with what it has and a cursor.
    static let scanBudget: Duration = .seconds(3)

    static func definition(db: Database, resolver: ContactResolver) -> ToolDefinition {
        let inputSchema: Value = .object([
            "type": "object",
            "properties": .object([
                "query": .object([
                    "type": "string",
                    "description": "Text to search for (optional if you provide filters)"
                ]),
                "from_person": .object([
                    "type": "string",
                    "description": "Only messages from this person (or \"me\")"
                ]),
                "in_chat": .object([
                    "type": "string",
                    "description": "Chat ID to search within (e.g., \"chat123\")"
                ]),
                "is_group": .object([
                    "type": "boolean",
                    "description": "true for groups only, false for DMs only"
                ]),
                "include_filtered": .object([
                    "type": "boolean",
                    "description": "Include chats Messages.app has filtered as junk or unknown senders (default false)",
                ]),
                "has": .object([
                    "type": "string",
                    "description": "Content type filter",
                    "enum": ["link", "image", "video", "attachment"]
                ]),
                "since": .object([
                    "type": "string",
                    "description": "Lower time bound: \(AppleTime.boundFormats)"
                ]),
                "match_all": .object([
                    "type": "boolean",
                    "description": "If true, require ALL words to match. If false (default), match ANY word.",
                    "default": .bool(false)
                ]),
                "fuzzy": .object([
                    "type": "boolean",
                    "description": "Match despite typos (allows 1-2 character differences). Use it to find messages that contain typos.",
                    "default": .bool(false)
                ]),
                "before": .object([
                    "type": "string",
                    "description": "Upper time bound, in the same forms as since"
                ]),
                "cursor": .object([
                    "type": "string",
                    "description": "Pagination cursor from a previous search response"
                ]),
                "limit": .object([
                    "type": "integer",
                    "description": "Maximum results to return (\(limit.defaultAndMax))",
                    "default": .int(limit.defaultValue)
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
                    "description": "Include the messages before and after each result",
                    "default": false
                ]),
                "unanswered": .object([
                    "type": "boolean",
                    "description": "Only return messages from me that didn't receive a reply",
                    "default": false
                ]),
                "unanswered_hours": .object([
                    "type": "integer",
                    "description": "Window in hours to check for replies (default \(IntArgument.unansweredHours.defaultValue))",
                    "default": .int(IntArgument.unansweredHours.defaultValue)
                ])
            ]),
            "additionalProperties": false
        ])

        return ToolDefinition(
            name: "search",
            description: """
                Full-text search across messages. Use it when you know the topic or phrase but not which conversation it appeared in.
                Results include chat ids for follow-up tool calls and chat names for user-facing summaries. When you explain results to the user, refer to chats by name, not by id.

                Search features:
                - Multi-word: "costa rica trip" matches ANY word by default
                - match_all: true requires ALL words to be present
                - fuzzy: true handles typos ("costarcia" finds "costa rica")
                - A search that runs out of time before it fills the page returns what it found with partial: true, searched_to (the oldest message time it reached, or the newest with oldest_first), more: true and a cursor. Call again with the cursor to search further back.

                Time filters (since/before):
                - Relative: "30min", "24h", "7d", "2w", "3mo" (a bare "m" is refused: write "min" or "mo")
                - Natural: "yesterday", "last tuesday", "2 weeks ago", "this month"
                - ISO: "2024-01-15T10:30:00Z"

                Examples:
                - search(query: "launch timeline"): matches any of these words
                - search(query: "launch timeline", match_all: true): must have both words
                - search(query: "volcno", fuzzy: true): finds "volcano" despite the typo
                - search(from_person: "me", since: "last monday"): my messages since Monday
                - search(has: "link", in_chat: "chat123"): links in one chat, after narrowing down
                - search(unanswered: true): questions I sent that got no reply
                """,
            inputSchema: inputSchema,
            outputSchema: OutputSchema.object,
            annotations: Tool.Annotations(
                title: "Search Messages",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let query = arguments?["query"]?.stringValue
            let fromPerson = arguments?["from_person"]?.stringValue
            let inChat = arguments?["in_chat"]?.stringValue
            let isGroup = arguments?["is_group"]?.boolValue
            let includeFiltered = arguments?["include_filtered"]?.boolValue ?? false
            let has = arguments?["has"]?.stringValue
            let since = try AppleTime.checkedBound(arguments?["since"]?.stringValue, name: "since")
            let before = try AppleTime.checkedBound(arguments?["before"]?.stringValue, name: "before")
            let cursor = arguments?["cursor"]?.stringValue
            let limit = Self.limit.read(arguments)
            let sort = arguments?["sort"]?.stringValue ?? "recent_first"
            let format = arguments?["format"]?.stringValue ?? "flat"
            let includeContext = arguments?["include_context"]?.boolValue ?? false
            let unanswered = arguments?["unanswered"]?.boolValue ?? false
            let unansweredHours = IntArgument.unansweredHours.read(arguments)
            let matchAll = arguments?["match_all"]?.boolValue ?? false
            let fuzzy = arguments?["fuzzy"]?.boolValue ?? false

            let result = try await execute(
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
                includeFiltered: includeFiltered,
                db: db,
                resolver: resolver
            )

            return [.plainText(result)]
        }
    }

    static func execute(
        query: String? = nil,
        fromPerson: String? = nil,
        inChat: String? = nil,
        isGroup: Bool? = nil,
        has: String? = nil,
        since: String? = nil,
        before: String? = nil,
        cursor: String? = nil,
        limit: Int = SearchTool.limit.defaultValue,
        sort: String = "recent_first",
        format: String = "flat",
        includeContext: Bool = false,
        unanswered: Bool = false,
        unansweredHours: Int = IntArgument.unansweredHours.defaultValue,
        matchAll: Bool = false,
        fuzzy: Bool = false,
        includeFiltered: Bool = false,
        scanBudget: Duration = SearchTool.scanBudget,
        db: Database,
        resolver: ContactResolver
    ) async throws -> String {
        let hasFilter = fromPerson != nil || inChat != nil || isGroup != nil ||
                        has != nil || since != nil || before != nil || unanswered
        let hasQuery = query != nil &&
                       !(query?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)

        if !hasQuery && !hasFilter {
            throw ToolFailure("invalid_query", "Provide a query or at least one filter")
        }

        let clampedLimit = Self.limit.clamp(limit)
        let clampedUnansweredHours = IntArgument.unansweredHours.clamp(unansweredHours)
        let sortOrder = SearchSort(rawValue: sort) ?? .recentFirst
        let responseFormat = SearchFormat(rawValue: format) ?? .flat

        let fetchLimit = (hasQuery || unanswered) ? max(500, clampedLimit * 10) : clampedLimit

        let senderFilter = await SenderFilter.resolve(fromPerson, resolver: resolver)
        let chatFilter = try inChat.map { try ChatIdentifier.resolve($0, db: db) }

        let searchWords: [String]
        if hasQuery, let searchQuery = query?.trimmingCharacters(in: .whitespaces).lowercased(), !searchQuery.isEmpty {
            let words = searchQuery.split(separator: " ")
                .map(String.init)
                .filter { $0.count >= 2 }
            searchWords = words.isEmpty ? [searchQuery] : words
        } else {
            searchWords = []
        }

        let schema = try db.schema()
        func fetch(inChat: Int64?, includeFiltered: Bool, cursor: TimelineCursor?) throws -> [MessageInChat] {
            let (sql, params) = buildQuery(
                query: query,
                fromPerson: senderFilter,
                inChat: inChat,
                isGroup: isGroup,
                has: has,
                since: since,
                before: before,
                cursor: cursor,
                limit: fetchLimit,
                sort: sortOrder,
                unanswered: unanswered,
                terms: searchWords,
                matchAll: matchAll,
                fuzzy: fuzzy,
                includeFiltered: includeFiltered,
                schema: schema
            )
            return try db.query(sql, params: params, map: MessageInChat.init)
        }

        let confirmsInSwift = (hasQuery && !searchWords.isEmpty) || unanswered
        func matchesWords(_ text: String?) -> Bool {
            guard let text = text?.lowercased() else { return false }

            let textWords = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)

            if matchAll {
                return searchWords.allSatisfy { searchWord in
                    wordMatches(searchWord: searchWord, in: text, textWords: textWords, fuzzy: fuzzy)
                }
            } else {
                return searchWords.contains { searchWord in
                    wordMatches(searchWord: searchWord, in: text, textWords: textWords, fuzzy: fuzzy)
                }
            }
        }

        func confirmed(_ candidates: [MessageInChat], limit: Int) throws -> [MessageInChat] {
            var rows = candidates
            if hasQuery, !searchWords.isEmpty {
                rows = rows.filter { matchesWords($0.message.text) }
            }

            if unanswered {
                rows = try UnansweredHeuristics.filterUnanswered(
                    db: db,
                    rows: rows,
                    hours: clampedUnansweredHours,
                    limit: limit,
                    text: \.message.text,
                    date: \.message.date,
                    chatId: \.chatId
                )
            }
            return Array(rows.prefix(limit))
        }

        func hiddenChatsWithMatch() throws -> Int {
            func hiddenQuery(columns: String = "DISTINCT c.ROWID") -> (String, [Any]) {
                filteredHiddenQuery(
                    query: query,
                    fromPerson: senderFilter,
                    inChat: chatFilter,
                    isGroup: isGroup,
                    has: has,
                    since: since,
                    before: before,
                    unanswered: unanswered,
                    terms: searchWords,
                    matchAll: matchAll,
                    fuzzy: fuzzy,
                    columns: columns
                )
            }
            if confirmsInSwift, !unanswered {
                let (sql, params) = hiddenQuery(columns: "c.ROWID, m.text, m.attributedBody")
                var matched = Set<Int64>()
                _ = try db.query(sql, params: params) { row in
                    let chatId = row.int(0)
                    guard !matched.contains(chatId) else { return }
                    let text = MessageTextExtractor.extract(text: row.string(1), attributedBody: row.blob(2))
                    if matchesWords(text) { matched.insert(chatId) }
                }
                return matched.count
            }
            let (sql, params) = hiddenQuery()
            let candidates = try db.query(sql, params: params) { $0.int(0) }
            guard confirmsInSwift else { return candidates.count }
            var count = 0
            for chatId in candidates {
                var resumeAfter: TimelineCursor?
                while true {
                    let page = try fetch(
                        inChat: chatId, includeFiltered: true, cursor: resumeAfter
                    )
                    if try !confirmed(page, limit: 1).isEmpty {
                        count += 1
                        break
                    }
                    guard page.count >= fetchLimit, let last = page.last?.message, let date = last.date else { break }
                    resumeAfter = TimelineCursor(date: date, messageId: last.id)
                }
            }
            return count
        }

        let filteredHidden = try ChatScope(named: chatFilter, includeFiltered: includeFiltered)
            .filteredHidden(firstPage: cursor == nil, count: hiddenChatsWithMatch)

        // Rows checked in Swift (a query, or unanswered) can fail the check a
        // page at a time, so keep paging until the page is full, the
        // messages run out, or the time budget is spent (088 #37: a fuzzy
        // or many-word search checked 500 rows and answered total 0).
        let deadline = ContinuousClock.now + scanBudget
        var resumeAt = cursor.flatMap(TimelineCursor.decode)
        var rows: [MessageInChat] = []
        var lastPage: [MessageInChat] = []
        while true {
            let page = try fetch(inChat: chatFilter, includeFiltered: includeFiltered, cursor: resumeAt)
            rows += try confirmed(page, limit: clampedLimit - rows.count)
            lastPage = page
            guard confirmsInSwift, rows.count < clampedLimit, page.count >= fetchLimit,
                  let last = page.last?.message, let date = last.date,
                  ContinuousClock.now < deadline else { break }
            resumeAt = TimelineCursor(date: date, messageId: last.id)
        }
        let nextCursor = TimelineCursor.next(
            kept: rows.map(\.message), limit: clampedLimit,
            fetched: lastPage.map(\.message), fetchLimit: fetchLimit
        )
        // A short page with a cursor means the budget ran out mid-scan.
        let stop = rows.count < clampedLimit && nextCursor != nil
            ? SearchScanStop(searchedTo: TimeUtils.formatISO(AppleTime.toDate(lastPage.last?.message.date)))
            : nil

        let jsonString: String
        if responseFormat == .groupedByChat {
            jsonString = try await buildGroupedResponse(
                db: db,
                rows: rows,
                query: query,
                nextCursor: nextCursor,
                resolver: resolver,
                filteredHidden: filteredHidden,
                stop: stop
            )
        } else {
            jsonString = try await buildFlatResponse(
                db: db,
                rows: rows,
                query: query,
                nextCursor: nextCursor,
                includeContext: includeContext,
                resolver: resolver,
                filteredHidden: filteredHidden,
                stop: stop
            )
        }

        return jsonString
    }

}
