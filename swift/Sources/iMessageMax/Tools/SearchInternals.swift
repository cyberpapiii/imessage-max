import Foundation

struct SearchSenderFilter {
    let value: String
    let exact: Bool
}

struct SearchRow {
    let msgId: Int64
    let text: String?
    let attributedBody: Data?
    let date: Int64?
    let isFromMe: Bool
    let senderHandle: String?
    let chatId: Int64
    let chatDisplayName: String?
    let guid: String
    let threadOriginatorGuid: String?
    let dateEdited: Int64
    let hasReactions: Bool
    let hasReplies: Bool
}

struct ContextRow {
    let msgId: Int64
    let text: String?
    let attributedBody: Data?
    let date: Int64?
    let isFromMe: Bool
    let senderHandle: String?
    let guid: String
    let threadOriginatorGuid: String?
    let dateEdited: Int64
    let hasReactions: Bool
    let hasReplies: Bool
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
        chatFilterPredicate: String?
    ) {
        builder
            .from("message m")
            .join("chat_message_join cmj ON m.ROWID = cmj.message_id")
            .join("chat c ON cmj.chat_id = c.ROWID")
            .leftJoin("handle h ON m.handle_id = h.ROWID")
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
                    "(SELECT COUNT(*) FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID) > ?",
                    1)
            } else {
                builder.where(
                    "(SELECT COUNT(*) FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID) = ?",
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
            .select(
                "m.ROWID as msg_id",
                "m.text",
                "m.attributedBody",
                "m.date",
                "m.is_from_me",
                "h.id as sender_handle",
                "c.ROWID as chat_id",
                "c.display_name as chat_display_name",
                "m.guid",
                schema.threadOriginatorGuidSQL,
                schema.dateEditedSQL,
                schema.hasRepliesSQL
            )
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
            chatFilterPredicate: includeFiltered ? nil : "c.is_filtered = 0"
        )

        if sort == .oldestFirst {
            builder.orderBy("m.date ASC", "m.ROWID ASC")
        } else {
            builder.orderBy("m.date DESC", "m.ROWID DESC")
        }

        builder.limit(limit)

        return builder.build()
    }

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
            chatFilterPredicate: "c.is_filtered != 0"
        )
        let (sql, params) = builder.build()
        let rows: [Int] = try db.query(sql, params: params) { row in
            Int(row.int(0))
        }
        return rows.first ?? 0
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
        let identityByChat = try await identitiesByChat(db: db, rows: rows, resolver: resolver)
        var contextRowsByAnchor: [String: (before: [ContextRow], after: [ContextRow])] = [:]
        if includeContext {
            let anchors = rows.compactMap { row -> (chatId: Int64, date: Int64)? in
                guard let date = row.date else { return nil }
                return (row.chatId, date)
            }
            contextRowsByAnchor = try getContextBatch(db: db, anchors: anchors)
        }

        let contextRows = contextRowsByAnchor.values.flatMap { $0.before + $0.after }
        var pageIdByGuid: [String: Int] = [:]
        for row in rows {
            pageIdByGuid[row.guid] = Int(row.msgId)
        }
        for row in contextRows {
            pageIdByGuid[row.guid] = Int(row.msgId)
        }
        let annotations = try MessageAnnotations.loadIfNeeded(
            db: db,
            guids: Array(pageIdByGuid.keys),
            pageIdByGuid: pageIdByGuid,
            originatorGuids: rows.compactMap(\.threadOriginatorGuid) + contextRows.compactMap(\.threadOriginatorGuid),
            fetchReactions: !pageIdByGuid.isEmpty,
            fetchReplies: rows.contains(where: { $0.hasReplies || ($0.threadOriginatorGuid?.isEmpty == false) })
                || contextRows.contains(where: { $0.hasReplies || ($0.threadOriginatorGuid?.isEmpty == false) })
        )
        var reactorNames: [String: String] = [:]
        for recs in annotations.reactions.values {
            for reaction in recs {
                guard let handle = reaction.fromHandle, reactorNames[handle] == nil else { continue }
                reactorNames[handle] = await IdentityDisplayFormatter.displayName(
                    handle: handle, resolver: resolver
                )
            }
        }
        let reactorName: (String?) -> String = { handle in
            guard let handle else { return "Me" }
            return reactorNames[handle] ?? handle
        }

        var contextByAnchor: [String: (before: [SearchContextMessage], after: [SearchContextMessage])] = [:]
        for (key, raw) in contextRowsByAnchor {
            var before: [SearchContextMessage] = []
            for row in raw.before {
                before.append(await formatContextMessage(row: row, annotations: annotations, reactorName: reactorName, resolver: resolver))
            }
            var after: [SearchContextMessage] = []
            for row in raw.after {
                after.append(await formatContextMessage(row: row, annotations: annotations, reactorName: reactorName, resolver: resolver))
            }
            contextByAnchor[key] = (before, after)
        }

        for row in rows {
            let text = MessageTextExtractor.extract(text: row.text, attributedBody: row.attributedBody)
            let msgDate = AppleTime.toDate(row.date)
            let senderName = await resolveSenderName(
                isFromMe: row.isFromMe,
                handle: row.senderHandle,
                resolver: resolver
            )

            let chatName = identityByChat[row.chatId]?.displayName ?? "Unknown Chat"

            var result = SearchResult(
                id: "msg_\(row.msgId)",
                chat: ChatReference(id: "chat\(row.chatId)", name: chatName),
                from: senderName,
                excerpt: makeExcerpt(text: text, query: query),
                ago: TimeUtils.formatCompactRelative(msgDate),
                ts: TimeUtils.formatISO(msgDate),
                contextBefore: nil,
                contextAfter: nil,
                reactions: MessageAnnotations.render(
                    annotations.reactions[row.guid] ?? [],
                    reactorName: reactorName
                ),
                replyTo: row.threadOriginatorGuid.flatMap { annotations.replies.originatorIdByGuid[$0] },
                replyCount: annotations.replies.replyCountByGuid[row.guid],
                edited: row.dateEdited != 0 ? true : nil
            )

            if includeContext, let msgDate = row.date {
                if let ctx = contextByAnchor["\(row.chatId):\(msgDate)"] {
                    result.contextBefore = ctx.before.isEmpty ? nil : ctx.before
                    result.contextAfter = ctx.after.isEmpty ? nil : ctx.after
                }
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
        let identityByChat = try await identitiesByChat(db: db, rows: rows, resolver: resolver)
        let recentSenderChatIds = identityByChat.compactMap { chatId, identity -> Int64? in
            (identity.isNamed && identity.participantCount > 4) ? chatId : nil
        }
        let recentSendersByChat = try ChatSummaryQueries.recentSendersByChat(
            db: db,
            chatIds: recentSenderChatIds
        )
        var summaryByChat: [Int64: ChatSummary] = [:]
        for (chatId, identity) in identityByChat {
            summaryByChat[chatId] = try ChatSummaryBuilder.buildSummary(
                db: db,
                chatId: chatId,
                identity: identity,
                recentSenders: recentSendersByChat[chatId]
            )
        }

        for row in rows {
            let chatId = row.chatId
            let senderName = await resolveSenderName(
                isFromMe: row.isFromMe,
                handle: row.senderHandle,
                resolver: resolver
            )
            let text = MessageTextExtractor.extract(text: row.text, attributedBody: row.attributedBody)
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
                    id: "msg_\(row.msgId)",
                    from: senderName,
                    excerpt: makeExcerpt(text: text, query: query),
                    ts: TimeUtils.formatISO(msgDate)
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
        chats.sort { $0.matchCount > $1.matchCount }

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

    /// One statement per distinct chat: UNION ALL of per-anchor LIMIT 2
    /// before/after windows. `getContext` stays for the get_context tool.
    static func getContextBatch(
        db: Database,
        anchors: [(chatId: Int64, date: Int64)]
    ) throws -> [String: (before: [ContextRow], after: [ContextRow])] {
        guard !anchors.isEmpty else { return [:] }

        var datesByChat: [Int64: [Int64]] = [:]
        for anchor in anchors {
            datesByChat[anchor.chatId, default: []].append(anchor.date)
        }

        let schema = try db.schema()
        var result: [String: (before: [ContextRow], after: [ContextRow])] = [:]
        for (chatId, dates) in datesByChat {
            var rowsById: [Int64: ContextRow] = [:]
            var beforeIdsByDate: [Int64: [Int64]] = [:]
            var afterIdsByDate: [Int64: [Int64]] = [:]

            var chunkStart = 0
            while chunkStart < dates.count {
                let chunkEnd = min(chunkStart + 100, dates.count)
                let chunk = Array(dates[chunkStart..<chunkEnd])
                let (sql, params) = perAnchorContextSQL(chatId: chatId, dates: chunk, schema: schema)
                let rows = try db.query(sql, params: params) { row in
                    (
                        anchorDate: row.int(0),
                        side: row.string(1) ?? "",
                        context: mapContextRow(row, columnOffset: 2)
                    )
                }

                for item in rows {
                    if rowsById[item.context.msgId] == nil {
                        rowsById[item.context.msgId] = item.context
                    }
                    if item.side == "before" {
                        beforeIdsByDate[item.anchorDate, default: []].append(item.context.msgId)
                    } else {
                        afterIdsByDate[item.anchorDate, default: []].append(item.context.msgId)
                    }
                }
                chunkStart = chunkEnd
            }

            for date in dates {
                let before = Array((beforeIdsByDate[date] ?? []).reversed().compactMap { rowsById[$0] })
                let after = (afterIdsByDate[date] ?? []).compactMap { rowsById[$0] }
                result["\(chatId):\(date)"] = (before, after)
            }
        }
        return result
    }

    /// Caps at 100 anchors (200 subselects, 600 bindings). SQLite's default
    /// variable limit is 32766.
    private static func perAnchorContextSQL(
        chatId: Int64,
        dates: [Int64],
        schema: SchemaCapabilities
    ) -> (String, [Any]) {
        let columns = contextSelectColumns(schema)
        let fromJoin = """
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            """
        var parts: [String] = []
        var params: [Any] = []
        for date in dates {
            parts.append("""
                SELECT * FROM (
                  SELECT ? AS anchor_date, 'before' AS side, \(columns)
                  \(fromJoin)
                  WHERE cmj.chat_id = ? AND m.date < ? AND m.associated_message_type = 0
                  ORDER BY m.date DESC LIMIT 2
                )
                """)
            params.append(contentsOf: [date, chatId, date])
            parts.append("""
                SELECT * FROM (
                  SELECT ? AS anchor_date, 'after' AS side, \(columns)
                  \(fromJoin)
                  WHERE cmj.chat_id = ? AND m.date > ? AND m.associated_message_type = 0
                  ORDER BY m.date ASC LIMIT 2
                )
                """)
            params.append(contentsOf: [date, chatId, date])
        }
        return (parts.joined(separator: "\nUNION ALL\n"), params)
    }

    static func contextSelectColumns(_ schema: SchemaCapabilities) -> String {
        """
        m.ROWID as msg_id, m.text, m.attributedBody, m.date, m.is_from_me, h.id as sender_handle,
        m.guid, \(schema.threadOriginatorGuidSQL), \(schema.dateEditedSQL),
        \(schema.hasRepliesSQL)
        """
    }

    static func mapContextRow(_ row: SQLiteRow, columnOffset: Int = 0) -> ContextRow {
        let base = Int32(columnOffset)
        return ContextRow(
            msgId: row.int(base + 0),
            text: row.string(base + 1),
            attributedBody: row.blob(base + 2),
            date: row.optionalInt(base + 3),
            isFromMe: row.int(base + 4) != 0,
            senderHandle: row.string(base + 5),
            guid: row.string(base + 6) ?? "",
            threadOriginatorGuid: row.string(base + 7),
            dateEdited: row.optionalInt(base + 8) ?? 0,
            hasReactions: false,
            hasReplies: row.int(base + 9) != 0
        )
    }

    static func getContext(
        db: Database,
        chatId: Int64,
        msgDate: Int64,
        resolver: ContactResolver
    ) async throws -> ([SearchContextMessage], [SearchContextMessage]) {
        let schema = try db.schema()
        let columns = contextSelectColumns(schema)
        let beforeRows = try db.query("""
            SELECT \(columns)
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE cmj.chat_id = ? AND m.date < ? AND m.associated_message_type = 0
            ORDER BY m.date DESC LIMIT 2
            """,
            params: [chatId, msgDate]
        ) { mapContextRow($0) }

        let afterRows = try db.query("""
            SELECT \(columns)
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE cmj.chat_id = ? AND m.date > ? AND m.associated_message_type = 0
            ORDER BY m.date ASC LIMIT 2
            """,
            params: [chatId, msgDate]
        ) { mapContextRow($0) }

        let allRows = beforeRows + afterRows
        var pageIdByGuid: [String: Int] = [:]
        for row in allRows {
            pageIdByGuid[row.guid] = Int(row.msgId)
        }
        let annotations = try MessageAnnotations.loadIfNeeded(
            db: db,
            guids: Array(pageIdByGuid.keys),
            pageIdByGuid: pageIdByGuid,
            originatorGuids: allRows.compactMap(\.threadOriginatorGuid),
            fetchReactions: !pageIdByGuid.isEmpty,
            fetchReplies: allRows.contains(where: { $0.hasReplies || ($0.threadOriginatorGuid?.isEmpty == false) })
        )
        var reactorNames: [String: String] = [:]
        for recs in annotations.reactions.values {
            for reaction in recs {
                guard let handle = reaction.fromHandle, reactorNames[handle] == nil else { continue }
                reactorNames[handle] = await IdentityDisplayFormatter.displayName(
                    handle: handle, resolver: resolver
                )
            }
        }
        let reactorName: (String?) -> String = { handle in
            guard let handle else { return "Me" }
            return reactorNames[handle] ?? handle
        }

        var contextBefore: [SearchContextMessage] = []
        var contextAfter: [SearchContextMessage] = []

        for row in beforeRows.reversed() {
            let msg = await formatContextMessage(
                row: row,
                annotations: annotations,
                reactorName: reactorName,
                resolver: resolver
            )
            contextBefore.append(msg)
        }

        for row in afterRows {
            let msg = await formatContextMessage(
                row: row,
                annotations: annotations,
                reactorName: reactorName,
                resolver: resolver
            )
            contextAfter.append(msg)
        }

        return (contextBefore, contextAfter)
    }

    static func formatContextMessage(
        row: ContextRow,
        annotations: MessageAnnotations.Loaded,
        reactorName: (String?) -> String,
        resolver: ContactResolver
    ) async -> SearchContextMessage {
        let text = MessageTextExtractor.extract(text: row.text, attributedBody: row.attributedBody)
        let msgDate = AppleTime.toDate(row.date)

        return SearchContextMessage(
            id: "msg_\(row.msgId)",
            from: await resolveSenderName(
                isFromMe: row.isFromMe,
                handle: row.senderHandle,
                resolver: resolver
            ),
            text: text,
            ts: TimeUtils.formatISO(msgDate),
            reactions: MessageAnnotations.render(
                annotations.reactions[row.guid] ?? [],
                reactorName: reactorName
            ),
            replyTo: row.threadOriginatorGuid.flatMap { annotations.replies.originatorIdByGuid[$0] },
            replyCount: annotations.replies.replyCountByGuid[row.guid],
            edited: row.dateEdited != 0 ? true : nil
        )
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

    static func resolveSenderName(
        isFromMe: Bool,
        handle: String?,
        resolver: ContactResolver
    ) async -> String {
        if isFromMe {
            return "Me"
        }
        guard let handle else { return "Unknown" }
        return await IdentityDisplayFormatter.displayName(handle: handle, resolver: resolver)
    }

    static func identitiesByChat(
        db: Database,
        rows: [SearchRow],
        resolver: ContactResolver
    ) async throws -> [Int64: ChatIdentity] {
        let chatIds = Array(Set(rows.map(\.chatId)))
        let participantsByChat = try await ChatSummaryQueries.participantsByChat(
            db: db,
            chatIds: chatIds,
            resolver: resolver
        )
        var explicitNameByChat: [Int64: String?] = [:]
        for row in rows where explicitNameByChat[row.chatId] == nil {
            explicitNameByChat[row.chatId] = row.chatDisplayName
        }
        var result: [Int64: ChatIdentity] = [:]
        for chatId in chatIds {
            result[chatId] = ChatIdentity.from(
                chatId: chatId,
                guid: nil,
                explicitName: explicitNameByChat[chatId] ?? nil,
                rows: participantsByChat[chatId] ?? []
            )
        }
        return result
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
        return TimelineCursor.encode(date: last.date, messageId: last.msgId)
    }
}
