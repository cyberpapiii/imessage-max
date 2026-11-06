import Foundation

extension SearchTool {
    /// The chats a search reads, and how its rows relate to them.
    enum Chats {
        /// One row per message, under the chat `scope` lists it in.
        case listed(ChatScope)
        /// One row per hidden chat a message is in, only `inChat` when set:
        /// the filtered_hidden candidates.
        case hiddenMembership(inChat: Int64?)
    }

    static func applySearchFilters(
        to builder: QueryBuilder,
        query: String?,
        fromPerson: SenderFilter?,
        chats: Chats,
        isGroup: Bool?,
        has: String?,
        since: String?,
        before: String?,
        cursor: TimelineCursor?,
        sort: SearchSort,
        unanswered: Bool,
        terms: [String],
        matchAll: Bool,
        fuzzy: Bool
    ) {
        switch chats {
        case .listed(let scope):
            scope.read(builder)
            builder
                .leftJoin(MessageRecord.senderJoin)
                .where(SQLFragments.notReaction())
        case .hiddenMembership(let inChat):
            // CROSS JOIN pins SQLite's loop order: visit the chats the
            // predicate selects, then only their messages by rowid.
            builder
                .from("""
                    chat c
                    CROSS JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
                    CROSS JOIN message m ON m.ROWID = cmj.message_id
                    """)
                .leftJoin(MessageRecord.senderJoin)
                .where(SQLFragments.notReaction())
                .where(SQLFragments.hiddenChat())
            if let inChat {
                builder.where("c.ROWID = ?", inChat)
            }
        }

        if let query, !query.isEmpty {
            // At most 8 terms reach SQL. Under match_all any 8 still only
            // narrow (the Swift word filter checks every term), but an
            // any-word query OR'ing its first 8 would drop rows matching only
            // a later word, so a longer any-word query skips the prefilter.
            let prefilterCap = 8
            if fuzzy || terms.isEmpty || (!matchAll && terms.count > prefilterCap) {
                builder.where("(m.text IS NOT NULL OR m.attributedBody IS NOT NULL)")
            } else {
                // Each term's textMayContain, joined as match_all asks, so
                // attributedBody-only rows without the words never fill the
                // fetch window.
                let matches = terms.prefix(prefilterCap).map { SQLFragments.textMayContain($0) }
                let joiner = matchAll ? " AND " : " OR "
                builder.where(
                    "(\(matches.map(\.sql).joined(separator: joiner)))",
                    params: matches.flatMap(\.bindings)
                )
            }
        }

        if let sinceStr = since, let sinceTs = AppleTime.parse(sinceStr) {
            builder.where("m.date >= ?", sinceTs)
        }

        if let beforeStr = before, let beforeTs = AppleTime.parse(beforeStr) {
            builder.where("m.date <= ?", beforeTs)
        }

        if let cursor {
            let after = cursor.predicate(descending: sort == .recentFirst)
            builder.where(after.sql, params: after.params)
        }

        if let sender = unanswered ? .me : fromPerson {
            builder.where(sender)
        }

        if let isGroup {
            builder.where(isGroup ? SQLFragments.isGroup() : SQLFragments.isDirect())
        }

        if let has = SQLFragments.has(has) {
            builder.where(has)
        }
    }

    static func buildQuery(
        query: String?,
        fromPerson: SenderFilter?,
        inChat: Int64?,
        isGroup: Bool?,
        has: String?,
        since: String?,
        before: String?,
        cursor: TimelineCursor?,
        limit: Int,
        sort: SearchSort,
        unanswered: Bool,
        terms: [String] = [],
        matchAll: Bool = false,
        fuzzy: Bool = false,
        includeFiltered: Bool = false,
        schema: SchemaCapabilities = .assumed
    ) -> (String, [Any]) {
        let builder = QueryBuilder()
            .selectMessages(schema, MessageInChat.chatColumns)
        applySearchFilters(
            to: builder,
            query: query,
            fromPerson: fromPerson,
            chats: .listed(ChatScope(named: inChat, includeFiltered: includeFiltered)),
            isGroup: isGroup,
            has: has,
            since: since,
            before: before,
            cursor: cursor,
            sort: sort,
            unanswered: unanswered,
            terms: terms,
            matchAll: matchAll,
            fuzzy: fuzzy
        )
        builder.leftJoin(MessageRecord.otherHandleJoin)

        if sort == .oldestFirst {
            builder.orderBy("m.date ASC", "m.ROWID ASC")
        } else {
            builder.orderBy("m.date DESC", "m.ROWID DESC")
        }

        builder.limit(limit)

        return builder.build()
    }

    /// `columns` of hidden chats' rows that pass the SQL prefilter. Starts
    /// from the few filtered chats rather than scanning every message a
    /// second time.
    static func filteredHiddenQuery(
        query: String?,
        fromPerson: SenderFilter?,
        inChat: Int64?,
        isGroup: Bool?,
        has: String?,
        since: String?,
        before: String?,
        unanswered: Bool,
        terms: [String],
        matchAll: Bool,
        fuzzy: Bool,
        columns: String = "DISTINCT c.ROWID"
    ) -> (String, [Any]) {
        let builder = QueryBuilder()
            .select(columns)
        applySearchFilters(
            to: builder,
            query: query,
            fromPerson: fromPerson,
            chats: .hiddenMembership(inChat: inChat),
            isGroup: isGroup,
            has: has,
            since: since,
            before: before,
            cursor: nil,
            sort: .recentFirst,
            unanswered: unanswered,
            terms: terms,
            matchAll: matchAll,
            fuzzy: fuzzy
        )
        return builder.build()
    }

    static func buildFlatResponse(
        db: Database,
        rows: [MessageInChat],
        query: String?,
        nextCursor: String?,
        includeContext: Bool,
        resolver: ContactResolver,
        filteredHidden: Int?
    ) async throws -> String {
        var results: [SearchResult] = []
        let chatByID = try await ChatReferences(rows.chats, db: db, resolver: resolver)
        var windows: [MessageWindow.Anchor: MessageWindow.Context] = [:]
        if includeContext {
            let anchors = rows.map { MessageWindow.Anchor(chatId: $0.chatId, message: $0.message) }
            windows = try MessageWindow.around(anchors, before: 2, after: 2, db: db)
        }

        let records = rows.map(\.message) + windows.values.flatMap { $0.before + $0.after }
        let annotations = try MessageAnnotations.load(for: records, include: [.reactions, .replies], db: db)
        let renderer = MessageRenderer(
            annotations: annotations,
            labels: await SenderLabels.displayNames(
                me: "Me", unknown: "Unknown", for: records, annotations: annotations, resolver: resolver
            )
        )
        func contextMessages(_ records: [MessageRecord]) -> [ContextMessage]? {
            records.isEmpty ? nil : records.map { ContextMessage(renderer.render($0), showAgo: false) }
        }

        for searchRow in rows {
            let message = renderer.render(searchRow.message)

            var result = SearchResult(
                id: message.id,
                chat: chatByID[searchRow.chatId],
                from: message.from,
                excerpt: makeExcerpt(text: message.text, query: query),
                ago: message.ago,
                ts: message.ts,
                contextBefore: nil,
                contextAfter: nil,
                reactions: message.reactions,
                replyTo: message.replyTo,
                replyCount: message.replyCount,
                edited: message.edited
            )

            if let window = windows[MessageWindow.Anchor(chatId: searchRow.chatId, message: searchRow.message)] {
                result.contextBefore = contextMessages(window.before)
                result.contextAfter = contextMessages(window.after)
            }

            results.append(result)
        }

        let response = SearchFlatResponse(
            results: results,
            total: results.count,
            more: nextCursor != nil,
            cursor: nextCursor,
            filteredHidden: filteredHidden
        )
        return try FormatUtils.encodeJSON(response)
    }

    static func buildGroupedResponse(
        db: Database,
        rows: [MessageInChat],
        query: String?,
        nextCursor: String?,
        resolver: ContactResolver,
        filteredHidden: Int?
    ) async throws -> String {
        let page = try await ChatPage.build(
            rows.chats,
            lastMessages: nil,
            db: db,
            resolver: resolver
        )
        let renderer = MessageRenderer(
            annotations: .none,
            labels: await SenderLabels.displayNames(me: "Me", unknown: "Unknown", for: rows.map(\.message), resolver: resolver)
        )

        let rowsByChat = Dictionary(grouping: rows, by: \.chatId)
        var chats = rowsByChat.compactMap { chatId, matches -> SearchGroupedChat? in
            guard let summary = page[chatId]?.summary else { return nil }
            let dates = matches.compactMap { AppleTime.toDate($0.message.date) }
            return SearchGroupedChat(
                id: summary.id,
                name: summary.name,
                group: summary.group,
                participantCount: summary.participantCount,
                participantsPreview: summary.participantsPreview,
                matchCount: matches.count,
                firstMatch: TimeUtils.formatISO(dates.min()),
                lastMatch: TimeUtils.formatISO(dates.max()),
                results: matches.prefix(3).map { match in
                    let message = renderer.render(match.message)
                    return SearchSampleMessage(
                        id: message.id,
                        from: message.from,
                        excerpt: makeExcerpt(text: message.text, query: query),
                        ts: message.ts
                    )
                }
            )
        }
        // Most matches first; ties go to the most recent match so the order is stable.
        chats.sort {
            ($0.matchCount, $0.lastMatch ?? "", $0.id) > ($1.matchCount, $1.lastMatch ?? "", $1.id)
        }

        let response = SearchGroupedResponse(
            chats: chats,
            total: chats.reduce(0) { $0 + $1.matchCount },
            chatCount: chats.count,
            query: query,
            more: nextCursor != nil,
            cursor: nextCursor,
            filteredHidden: filteredHidden
        )
        return try FormatUtils.encodeJSON(response)
    }

    /// Excerpt is centred on the first query match. A URL that straddles the
    /// raw-window boundary is collapsed from its truncated form, so
    /// `[Link: host]` may become `[Link: link]` or the raw fragment may appear.
    /// The window is four times the excerpt, so this needs a URL longer than
    /// ~240 characters positioned exactly at the edge.
    static func makeExcerpt(text: String?, query: String?) -> String {
        guard let text else { return "" }
        let excerptLength = 160
        let rawWindow = 4 * excerptLength
        /// Characters before the first case-insensitive match of the query.
        func matchOffset(in string: String) -> Int? {
            guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let range = string.range(of: query, options: .caseInsensitive) else { return nil }
            return string.distance(from: string.startIndex, to: range.lowerBound)
        }
        let rawStart = matchOffset(in: text).map { max(0, $0 - rawWindow / 2) } ?? 0
        let source = String(text.dropFirst(rawStart).prefix(rawWindow))
        let normalized = SummaryPreviewFormatter.formattedTextPreview(
            text: source,
            maxLength: Int.max
        ) ?? source

        func withWindowPrefix(_ excerpt: String) -> String {
            if rawStart > 0 && !excerpt.hasPrefix("...") {
                return "..." + excerpt
            }
            return excerpt
        }

        guard normalized.count > excerptLength else { return withWindowPrefix(normalized) }

        let start = matchOffset(in: normalized).map { max(0, $0 - excerptLength / 2) } ?? 0
        let excerpt = normalized.dropFirst(start).prefix(excerptLength)
        let prefix = start > 0 ? "..." : ""
        let suffix = start + excerpt.count < normalized.count ? "..." : ""
        return withWindowPrefix(prefix + excerpt + suffix)
    }

    static func wordMatches(searchWord: String, in text: String, textWords: [String], fuzzy: Bool) -> Bool {
        if text.contains(searchWord) {
            return true
        }

        if fuzzy {
            let maxDistance = searchWord.count <= 4 ? 1 : 2

            for textWord in textWords {
                if abs(textWord.count - searchWord.count) > maxDistance {
                    continue
                }
                if levenshteinDistance(searchWord, textWord) <= maxDistance {
                    return true
                }
            }
        }

        return false
    }

    static func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let m = s1.count
        let n = s2.count

        if m == 0 { return n }
        if n == 0 { return m }

        let chars1 = Array(s1)
        let chars2 = Array(s2)

        var prevRow = Array(0...n)
        var currRow = Array(repeating: 0, count: n + 1)

        for i in 1...m {
            currRow[0] = i
            for j in 1...n {
                let cost = chars1[i - 1] == chars2[j - 1] ? 0 : 1
                currRow[j] = min(
                    prevRow[j] + 1,
                    currRow[j - 1] + 1,
                    prevRow[j - 1] + cost
                )
            }
            swap(&prevRow, &currRow)
        }

        return prevRow[n]
    }

}
