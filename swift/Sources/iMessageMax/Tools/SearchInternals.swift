import Foundation

struct SearchCursor {
    let date: Int64
    let messageId: Int64
}

struct SearchSenderFilter {
    let value: String
    let exact: Bool
}

struct SearchRow {
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

struct ContextRow {
    let msgId: Int64
    let text: String?
    let attributedBody: Data?
    let date: Int64?
    let isFromMe: Bool
    let senderHandle: String?
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
    static func buildQuery(
        query: String?,
        fromPerson: SearchSenderFilter?,
        inChat: String?,
        isGroup: Bool?,
        has: String?,
        since: String?,
        before: String?,
        cursor: SearchCursor?,
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

        if query != nil && !query!.isEmpty {
            builder.where("(m.text IS NOT NULL OR m.attributedBody IS NOT NULL)")
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
                builder.where("(m.date < ? OR (m.date = ? AND m.ROWID < ?))", cursor.date, cursor.date, cursor.messageId)
            case .oldestFirst:
                builder.where("(m.date > ? OR (m.date = ? AND m.ROWID > ?))", cursor.date, cursor.date, cursor.messageId)
            }
        }

        if let chatStr = inChat {
            let chatIdStr = chatStr.hasPrefix("chat") ? String(chatStr.dropFirst(4)) : chatStr
            if let chatId = Int64(chatIdStr) {
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

        if sort == .oldestFirst {
            builder.orderBy("m.date ASC", "m.ROWID ASC")
        } else {
            builder.orderBy("m.date DESC", "m.ROWID DESC")
        }

        builder.limit(limit)

        return builder.build()
    }

    static func looksLikeQuestion(_ text: String?) -> Bool {
        guard let text = text, !text.isEmpty else { return false }

        let textLower = text.lowercased().trimmingCharacters(in: .whitespaces)

        if text.contains("?") { return true }

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

    static func hasReplyWithinWindow(
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

    static func filterUnanswered(
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

    static func buildFlatResponse(
        db: Database,
        rows: [SearchRow],
        query: String?,
        limit: Int,
        includeContext: Bool,
        resolver: ContactResolver
    ) async throws -> String {
        var results: [SearchResult] = []
        var chatNamesCache: [Int64: String] = [:]

        for row in rows {
            let text = MessageTextExtractor.extract(text: row.text, attributedBody: row.attributedBody)
            let msgDate = AppleTime.toDate(row.date)
            let senderName = await resolveSenderName(
                isFromMe: row.isFromMe,
                handle: row.senderHandle,
                resolver: resolver
            )

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
                chat: ChatReference(id: "chat\(row.chatId)", name: chatName ?? "Unknown Chat"),
                from: senderName,
                excerpt: makeExcerpt(text: text, query: query),
                ago: TimeUtils.formatCompactRelative(msgDate),
                ts: TimeUtils.formatISO(msgDate),
                contextBefore: nil,
                contextAfter: nil
            )

            if includeContext, let msgDate = row.date {
                let (before, after) = try await getContext(
                    db: db,
                    chatId: row.chatId,
                    msgDate: msgDate,
                    resolver: resolver
                )
                result.contextBefore = before.isEmpty ? nil : before
                result.contextAfter = after.isEmpty ? nil : after
            }

            results.append(result)
        }

        let response = SearchFlatResponse(
            results: results,
            total: results.count,
            more: results.count >= limit,
            cursor: nextCursor(from: rows, limit: limit)
        )
        return try FormatUtils.encodeJSON(response)
    }

    static func buildGroupedResponse(
        db: Database,
        rows: [SearchRow],
        query: String?,
        limit: Int,
        resolver: ContactResolver
    ) async throws -> String {
        var chatsData: [Int64: GroupedChatData] = [:]
        var chatNamesCache: [Int64: String] = [:]
        var chatSummaryCache: [Int64: ChatSummary] = [:]

        for row in rows {
            let chatId = row.chatId
            let senderName = await resolveSenderName(
                isFromMe: row.isFromMe,
                handle: row.senderHandle,
                resolver: resolver
            )
            let text = MessageTextExtractor.extract(text: row.text, attributedBody: row.attributedBody)
            let msgDate = AppleTime.toDate(row.date)

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

            let chatSummary: ChatSummary
            if let cached = chatSummaryCache[chatId] {
                chatSummary = cached
            } else {
                let summary = try await buildChatSummary(
                    db: db,
                    chatId: chatId,
                    explicitName: chatName,
                    resolver: resolver
                )
                chatSummaryCache[chatId] = summary
                chatSummary = summary
            }

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

        let response = SearchGroupedResponse(
            chats: chats,
            total: chats.reduce(0) { $0 + $1.matchCount },
            chatCount: chats.count,
            query: query,
            more: rows.count >= limit,
            cursor: nextCursor(from: rows, limit: limit)
        )
        return try FormatUtils.encodeJSON(response)
    }

    static func getContext(
        db: Database,
        chatId: Int64,
        msgDate: Int64,
        resolver: ContactResolver
    ) async throws -> ([SearchContextMessage], [SearchContextMessage]) {
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

        for row in beforeRows.reversed() {
            let msg = await formatContextMessage(
                row: row,
                resolver: resolver
            )
            contextBefore.append(msg)
        }

        for row in afterRows {
            let msg = await formatContextMessage(
                row: row,
                resolver: resolver
            )
            contextAfter.append(msg)
        }

        return (contextBefore, contextAfter)
    }

    static func formatContextMessage(
        row: ContextRow,
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
            ts: TimeUtils.formatISO(msgDate)
        )
    }

    static func makeExcerpt(text: String?, query: String?) -> String {
        guard let text else { return "" }
        let normalized = SummaryPreviewFormatter.formattedTextPreview(
            text: text,
            attributedBody: nil,
            maxLength: Int.max
        ) ?? text
        guard normalized.count > 160 else { return normalized }

        let excerptLength = 160
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
                return prefix + excerpt + suffix
            }
        }

        let excerpt = nsText.substring(to: min(excerptLength, nsText.length))
        return nsText.length > excerptLength ? excerpt + "..." : excerpt
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

    static func buildChatSummary(
        db: Database,
        chatId: Int64,
        explicitName: String?,
        resolver: ContactResolver
    ) async throws -> ChatSummary {
        let participants = try db.query("""
            SELECT h.id as handle
            FROM handle h
            JOIN chat_handle_join chj ON h.ROWID = chj.handle_id
            WHERE chj.chat_id = ?
            ORDER BY h.id ASC
            """,
            params: [chatId]
        ) { row in
            row.string(0) ?? "unknown"
        }

        let identityParticipants = await withTaskGroup(of: ChatIdentity.Participant.self, returning: [ChatIdentity.Participant].self) { group in
            for handle in participants {
                group.addTask { [resolver] in
                    ChatIdentity.makeParticipant(
                        handle: handle,
                        contactName: await resolver.resolve(handle)
                    )
                }
            }
            var resolved: [ChatIdentity.Participant] = []
            for await participant in group {
                resolved.append(participant)
            }
            return resolved
        }

        let identity = ChatIdentity(
            mcpId: "chat\(chatId)",
            guid: nil,
            explicitName: explicitName,
            participants: identityParticipants
        )
        return try ChatSummaryBuilder.buildSummary(db: db, chatId: chatId, identity: identity)
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

    static func generateChatDisplayName(
        db: Database,
        chatId: Int64,
        resolver: ContactResolver
    ) async throws -> String {
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

    static func encodeCursor(date: Int64?, messageId: Int64) -> String? {
        guard let date else { return nil }
        return "\(date):\(messageId)"
    }

    static func decodeCursor(_ raw: String) -> SearchCursor? {
        let parts = raw.split(separator: ":")
        guard parts.count == 2,
              let date = Int64(parts[0]),
              let messageId = Int64(parts[1]) else {
            return nil
        }
        return SearchCursor(date: date, messageId: messageId)
    }

    static func nextCursor(from rows: [SearchRow], limit: Int) -> String? {
        guard rows.count >= limit, let last = rows.last else { return nil }
        return encodeCursor(date: last.date, messageId: last.msgId)
    }
}
