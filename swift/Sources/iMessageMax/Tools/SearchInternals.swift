import Foundation

struct SearchSenderFilter {
    let value: String
    let exact: Bool
}

struct SearchRow {
    let message: MessageRecord
    let chatId: Int64
    let chatDisplayName: String?
}

struct GroupedChatData {
    let id: String
    var name: String
    var group: Bool?
    var participantCount: Int
    var participantsPreview: [String]
    var matchCount: Int
    var firstMatchDate: Date?
    var lastMatchDate: Date?
    var results: [SearchSampleMessage]
}

extension SearchTool {
    static func applySearchFilters(
        to builder: QueryBuilder,
        query: String?,
        fromPerson: SearchSenderFilter?,
        inChat: String?,
        isGroup: Bool?,
        has: String?,
        since: String?,
        before: String?,
        cursor: TimelineCursor?,
        sort: SearchSort,
        unanswered: Bool,
        terms: [String],
        matchAll: Bool,
        fuzzy: Bool,
        chatFilterPredicate: String?,
        drivenFromChats: Bool = false
    ) {
        if drivenFromChats {
            // CROSS JOIN pins SQLite's loop order: visit the chats the
            // predicate selects, then only their messages by rowid.
            builder
                .from("""
                    chat c
                    CROSS JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
                    CROSS JOIN message m ON m.ROWID = cmj.message_id
                    """)
        } else {
            builder
                .from("message m")
                .join("chat_message_join cmj ON m.ROWID = cmj.message_id")
                .join("chat c ON cmj.chat_id = c.ROWID")
        }
        builder
            .leftJoin(MessageRecord.senderJoin)
            .where("m.associated_message_type = ?", 0)

        if let chatFilterPredicate {
            builder.where(chatFilterPredicate)
        }

        if let query, !query.isEmpty {
            if fuzzy || terms.isEmpty {
                builder.where("(m.text IS NOT NULL OR m.attributedBody IS NOT NULL)")
            } else {
                // LIKE on text (ASCII case-insensitive) plus instr on the
                // typedstream blob so attributedBody-only rows do not all
                // pass and steal the fetchLimit window. instr is
                // case-sensitive; bind lower / titled / upper UTF-8.
                // Cap at 8; leftover terms stay in the Swift word filter.
                let capped = Array(terms.prefix(8))
                let likeClauses = capped.map { _ in "m.text LIKE ? ESCAPE '\\'" }
                let blobClauses = capped.map { _ in
                    "(instr(m.attributedBody, ?) > 0 OR instr(m.attributedBody, ?) > 0 OR instr(m.attributedBody, ?) > 0)"
                }
                let joiner = matchAll ? " AND " : " OR "
                let condition = "((\(likeClauses.joined(separator: joiner))) OR (\(blobClauses.joined(separator: joiner))))"
                var bindings: [Any] = capped.map { "%\(QueryBuilder.escapeLike($0))%" }
                for term in capped {
                    let titled = term.prefix(1).uppercased() + term.dropFirst()
                    bindings.append(Data(term.utf8))
                    bindings.append(Data(titled.utf8))
                    bindings.append(Data(term.uppercased().utf8))
                }
                builder.where(condition, params: bindings)
            }
        }

        if let sinceStr = since, let sinceTs = AppleTime.parse(sinceStr) {
            builder.where("m.date >= ?", sinceTs)
        }

        if let beforeStr = before, let beforeTs = AppleTime.parse(beforeStr) {
            builder.where("m.date <= ?", beforeTs)
        }

        if let cursor {
            switch sort {
            case .recentFirst:
                builder.where(cursor.olderThanSQL, cursor.date, cursor.date, cursor.messageId)
            case .oldestFirst:
                builder.where(cursor.newerThanSQL, cursor.date, cursor.date, cursor.messageId)
            }
        }

        if let chatStr = inChat {
            if let chatId = ChatIdentifier.parseRowId(chatStr) {
                builder.where("c.ROWID = ?", chatId)
            } else {
                builder.where("c.guid LIKE ? ESCAPE '\\'", "%\(QueryBuilder.escapeLike(chatStr))%")
            }
        }

        if unanswered {
            builder.where("m.is_from_me = ?", 1)
        } else if let person = fromPerson {
            if person.value.lowercased() == "me" {
                builder.where("m.is_from_me = ?", 1)
            } else if person.exact {
                builder.where("h.id = ?", person.value)
            } else {
                builder.where("h.id LIKE ? ESCAPE '\\'", "%\(QueryBuilder.escapeLike(person.value))%")
            }
        }

        if let isGroupChat = isGroup {
            if isGroupChat {
                builder.where(
                    "\(SQLFragments.participantCount()) > ?",
                    1)
            } else {
                builder.where(
                    "\(SQLFragments.participantCount()) = ?",
                    1)
            }
        }

        if let hasType = has {
            switch hasType {
            case "link":
                builder.where("(m.text LIKE ? ESCAPE '\\' OR m.balloon_bundle_id = '\(BalloonBundle.urlPreview)')", "%http%")
            case "attachment":
                builder.where("""
                    EXISTS (
                        SELECT 1 FROM attachment a
                        JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
                        WHERE maj.message_id = m.ROWID
                          AND COALESCE(a.hide_attachment, 0) = 0
                    )
                    """)
            case "image", "video":
                if let typePredicate = AttachmentType.sqlPredicate(for: hasType, alias: "a") {
                    builder.where("""
                        EXISTS (
                            SELECT 1 FROM attachment a
                            JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
                            WHERE maj.message_id = m.ROWID
                              AND (\(typePredicate))
                              AND COALESCE(a.hide_attachment, 0) = 0
                        )
                        """)
                }
            default:
                break
            }
        }
    }

    static func buildQuery(
        query: String?,
        fromPerson: SearchSenderFilter?,
        inChat: String?,
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
            .selectMessages(schema, "c.ROWID as chat_id", "c.display_name as chat_display_name")
        applySearchFilters(
            to: builder,
            query: query,
            fromPerson: fromPerson,
            inChat: inChat,
            isGroup: isGroup,
            has: has,
            since: since,
            before: before,
            cursor: cursor,
            sort: sort,
            unanswered: unanswered,
            terms: terms,
            matchAll: matchAll,
            fuzzy: fuzzy,
            chatFilterPredicate: includeFiltered ? nil : SQLFragments.shownChat()
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

    /// Counts filtered chats with a match. Runs on every search that hides
    /// them, so it starts from the few filtered chats rather than scanning
    /// every message a second time.
    static func countFilteredHidden(
        db: Database,
        query: String?,
        fromPerson: SearchSenderFilter?,
        inChat: String?,
        isGroup: Bool?,
        has: String?,
        since: String?,
        before: String?,
        unanswered: Bool,
        terms: [String],
        matchAll: Bool,
        fuzzy: Bool
    ) throws -> Int {
        let (sql, params) = filteredHiddenQuery(
            query: query,
            fromPerson: fromPerson,
            inChat: inChat,
            isGroup: isGroup,
            has: has,
            since: since,
            before: before,
            unanswered: unanswered,
            terms: terms,
            matchAll: matchAll,
            fuzzy: fuzzy
        )
        let rows: [Int] = try db.query(sql, params: params) { row in
            Int(row.int(0))
        }
        return rows.first ?? 0
    }

    static func filteredHiddenQuery(
        query: String?,
        fromPerson: SearchSenderFilter?,
        inChat: String?,
        isGroup: Bool?,
        has: String?,
        since: String?,
        before: String?,
        unanswered: Bool,
        terms: [String],
        matchAll: Bool,
        fuzzy: Bool
    ) -> (String, [Any]) {
        let builder = QueryBuilder()
            .select("COUNT(DISTINCT c.ROWID)")
        applySearchFilters(
            to: builder,
            query: query,
            fromPerson: fromPerson,
            inChat: inChat,
            isGroup: isGroup,
            has: has,
            since: since,
            before: before,
            cursor: nil,
            sort: .recentFirst,
            unanswered: unanswered,
            terms: terms,
            matchAll: matchAll,
            fuzzy: fuzzy,
            chatFilterPredicate: SQLFragments.hiddenChat(),
            drivenFromChats: true
        )
        return builder.build()
    }

    static func buildFlatResponse(
        db: Database,
        rows: [SearchRow],
        query: String?,
        limit: Int,
        includeContext: Bool,
        resolver: ContactResolver,
        filteredHidden: Int?
    ) async throws -> String {
        var results: [SearchResult] = []
        let identityByChat = try await ChatPage.identities(chatsInFirstAppearanceOrder(rows), db: db, resolver: resolver)
        var windows: [MessageWindow.Anchor: MessageWindow.Context] = [:]
        if includeContext {
            let anchors = rows.compactMap { row in
                row.message.date.map { MessageWindow.Anchor(chatId: row.chatId, date: $0) }
            }
            windows = try MessageWindow.around(anchors, before: 2, after: 2, db: db)
        }

        let contextRows = windows.values.flatMap { $0.before + $0.after }
        let annotations = try MessageAnnotations.load(
            for: rows.map(\.message) + contextRows,
            include: [.reactions, .replies],
            db: db
        )
        let records = rows.map(\.message) + contextRows
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
            let chatName = identityByChat[searchRow.chatId]?.displayName ?? DisplayNameGenerator.fromNames([])

            var result = SearchResult(
                id: message.id,
                chat: ChatReference(id: ChatIdentifier.format(searchRow.chatId), name: chatName),
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

            if let date = searchRow.message.date,
               let window = windows[MessageWindow.Anchor(chatId: searchRow.chatId, date: date)] {
                result.contextBefore = contextMessages(window.before)
                result.contextAfter = contextMessages(window.after)
            }

            results.append(result)
        }

        let nextCursor = Self.nextCursor(from: rows, limit: limit)
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
        rows: [SearchRow],
        query: String?,
        limit: Int,
        resolver: ContactResolver,
        filteredHidden: Int?
    ) async throws -> String {
        var chatsData: [Int64: GroupedChatData] = [:]
        let page = try await ChatPage.build(
            chatsInFirstAppearanceOrder(rows),
            lastMessages: nil,
            db: db,
            resolver: resolver
        )
        let summaryByChat = page.mapValues(\.summary)
        let renderer = MessageRenderer(
            annotations: .none,
            labels: await SenderLabels.displayNames(me: "Me", unknown: "Unknown", for: rows.map(\.message), resolver: resolver)
        )

        for searchRow in rows {
            let row = searchRow.message
            let message = renderer.render(row)
            let chatId = searchRow.chatId
            let msgDate = AppleTime.toDate(row.date)

            guard let chatSummary = summaryByChat[chatId] else { continue }

            if chatsData[chatId] == nil {
                chatsData[chatId] = GroupedChatData(
                    id: chatSummary.id,
                    name: chatSummary.name,
                    group: chatSummary.group,
                    participantCount: chatSummary.participantCount,
                    participantsPreview: chatSummary.participantsPreview,
                    matchCount: 0,
                    firstMatchDate: msgDate,
                    lastMatchDate: msgDate,
                    results: []
                )
            }

            guard var chat = chatsData[chatId] else { continue }
            chat.matchCount += 1

            if let date = msgDate {
                if let first = chat.firstMatchDate {
                    if date < first { chat.firstMatchDate = date }
                } else {
                    chat.firstMatchDate = date
                }
                if let last = chat.lastMatchDate {
                    if date > last { chat.lastMatchDate = date }
                } else {
                    chat.lastMatchDate = date
                }
            }

            if chat.results.count < 3 {
                chat.results.append(SearchSampleMessage(
                    id: message.id,
                    from: message.from,
                    excerpt: makeExcerpt(text: message.text, query: query),
                    ts: message.ts
                ))
            }

            chatsData[chatId] = chat
        }

        var chats = chatsData.values.map { data in
            SearchGroupedChat(
                id: data.id,
                name: data.name,
                group: data.group,
                participantCount: data.participantCount,
                participantsPreview: data.participantsPreview,
                matchCount: data.matchCount,
                firstMatch: TimeUtils.formatISO(data.firstMatchDate),
                lastMatch: TimeUtils.formatISO(data.lastMatchDate),
                results: data.results
            )
        }
        // Most matches first; ties go to the most recent match so the order is stable.
        chats.sort {
            ($0.matchCount, $0.lastMatch ?? "", $0.id) > ($1.matchCount, $1.lastMatch ?? "", $1.id)
        }

        let nextCursor = Self.nextCursor(from: rows, limit: limit)
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
        let source: String
        var rawStart = 0
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let r = text.lowercased().range(of: query.lowercased()) {
            let center = text.distance(from: text.startIndex, to: r.lowerBound)
            let start = max(0, center - rawWindow / 2)
            rawStart = start
            source = String(text.dropFirst(start).prefix(rawWindow))
        } else {
            source = String(text.prefix(rawWindow))
        }
        let normalized = SummaryPreviewFormatter.formattedTextPreview(
            text: source,
            attributedBody: nil,
            maxLength: Int.max
        ) ?? source

        func withWindowPrefix(_ excerpt: String) -> String {
            if rawStart > 0 && !excerpt.hasPrefix("...") {
                return "..." + excerpt
            }
            return excerpt
        }

        guard normalized.count > 160 else { return withWindowPrefix(normalized) }

        let nsText = normalized as NSString

        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lowerText = normalized.lowercased()
            let lowerQuery = query.lowercased()
            if let matchRange = lowerText.range(of: lowerQuery) {
                let matchLocation = lowerText.distance(from: lowerText.startIndex, to: matchRange.lowerBound)
                let halfWindow = excerptLength / 2
                let start = max(0, matchLocation - halfWindow)
                let length = min(excerptLength, nsText.length - start)
                let excerpt = nsText.substring(with: NSRange(location: start, length: length))
                let prefix = start > 0 ? "..." : ""
                let suffix = (start + length) < nsText.length ? "..." : ""
                return withWindowPrefix(prefix + excerpt + suffix)
            }
        }

        let excerpt = nsText.substring(to: min(excerptLength, nsText.length))
        let head = nsText.length > excerptLength ? excerpt + "..." : excerpt
        return withWindowPrefix(head)
    }

    /// Each distinct chat in `rows`, named as the first row for it names it.
    static func chatsInFirstAppearanceOrder(_ rows: [SearchRow]) -> [ChatPage.Chat] {
        var seen: Set<Int64> = []
        return rows.compactMap { row in
            seen.insert(row.chatId).inserted ? ChatPage.Chat(id: row.chatId, explicitName: row.chatDisplayName) : nil
        }
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

    static func resolveFromPersonFilter(
        _ fromPerson: String?,
        resolver: ContactResolver
    ) async -> SearchSenderFilter? {
        guard let fromPerson, !fromPerson.isEmpty else { return nil }
        if fromPerson.lowercased() == "me" {
            return SearchSenderFilter(value: "me", exact: true)
        }
        if let normalized = PhoneUtils.normalizeToE164(fromPerson) {
            return SearchSenderFilter(value: normalized, exact: true)
        }
        if PhoneUtils.isEmail(fromPerson) {
            return SearchSenderFilter(value: fromPerson.lowercased(), exact: true)
        }
        if let firstMatch = await resolver.searchByName(fromPerson).first {
            return SearchSenderFilter(value: firstMatch.handle, exact: true)
        }
        return SearchSenderFilter(value: fromPerson, exact: false)
    }

    static func nextCursor(from rows: [SearchRow], limit: Int) -> String? {
        guard rows.count >= limit, let last = rows.last else { return nil }
        return TimelineCursor.encode(date: last.message.date, messageId: last.message.id)
    }
}
