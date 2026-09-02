import Foundation

enum MessageAnnotations {
    struct Reaction {
        let type: Int
        let fromHandle: String?
        let emoji: String?
        let date: Int64
    }

    static func reactionsMap(db: Database, messageGuids: [String]) throws -> [String: [Reaction]] {
        guard !messageGuids.isEmpty else { return [:] }

        let placeholders = messageGuids.map { _ in "?" }.joined(separator: ", ")
        let sql = """
            SELECT m.associated_message_guid, m.associated_message_type, h.id,
                   m.associated_message_emoji, m.date
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.associated_message_type >= 2000
            AND (
                m.associated_message_guid IN (\(placeholders))
                OR substr(m.associated_message_guid, instr(m.associated_message_guid, '/') + 1)
                   IN (\(placeholders))
            )
            """

        var map: [String: [Reaction]] = [:]

        let rows = try db.query(sql, params: messageGuids + messageGuids) { row in
            (
                guid: row.string(0) ?? "",
                type: Int(row.int(1)),
                fromHandle: row.string(2),
                emoji: row.string(3),
                date: row.optionalInt(4) ?? 0
            )
        }

        for row in rows {
            let originalGuid = row.guid.hasPrefix("p:") || row.guid.hasPrefix("bp:")
                ? String(row.guid.split(separator: "/").last ?? "")
                : row.guid

            map[originalGuid, default: []].append(
                Reaction(
                    type: row.type,
                    fromHandle: row.fromHandle,
                    emoji: row.emoji,
                    date: row.date
                )
            )
        }

        return map
    }

    static func applyingRemovals(_ rows: [Reaction]) -> [Reaction] {
        let sorted = rows.sorted { $0.date < $1.date }
        struct Key: Hashable {
            let handle: String?
            let type: Int
        }
        var kept: [Key: Reaction] = [:]
        var order: [Key] = []

        for r in sorted {
            if ReactionType.isRemoval(r.type) {
                let key = Key(handle: r.fromHandle, type: r.type - 1000)
                if kept.removeValue(forKey: key) != nil {
                    order.removeAll { $0 == key }
                }
            } else if ReactionType(rawValue: r.type) != nil {
                let key = Key(handle: r.fromHandle, type: r.type)
                if kept[key] == nil {
                    order.append(key)
                }
                kept[key] = r
            }
        }

        return order.compactMap { kept[$0] }
    }

    struct ReplyLookup {
        let originatorIdByGuid: [String: String]
        let replyCountByGuid: [String: Int]
    }

    /// Two batched queries per page: originator ROWIDs not already on the page,
    /// then reply counts via GROUP BY. Never per row.
    static func replyLookup(
        db: Database,
        pageGuids: [String],
        pageIdByGuid: [String: Int],
        originatorGuids: [String]
    ) throws -> ReplyLookup {
        var originatorIdByGuid: [String: String] = [:]
        for (guid, id) in pageIdByGuid {
            originatorIdByGuid[guid] = "msg_\(id)"
        }

        let missing = Array(Set(originatorGuids.filter { !$0.isEmpty }).subtracting(pageIdByGuid.keys))
        if !missing.isEmpty {
            let placeholders = missing.map { _ in "?" }.joined(separator: ", ")
            let rows = try db.query(
                "SELECT guid, ROWID FROM message WHERE guid IN (\(placeholders))",
                params: missing
            ) { row in
                (guid: row.string(0) ?? "", id: Int(row.int(1)))
            }
            for row in rows {
                originatorIdByGuid[row.guid] = "msg_\(row.id)"
            }
        }

        var replyCountByGuid: [String: Int] = [:]
        if !pageGuids.isEmpty {
            let placeholders = pageGuids.map { _ in "?" }.joined(separator: ", ")
            let rows = try db.query(
                """
                SELECT thread_originator_guid, COUNT(*)
                FROM message
                WHERE thread_originator_guid IN (\(placeholders))
                GROUP BY 1
                """,
                params: pageGuids
            ) { row in
                (guid: row.string(0) ?? "", count: Int(row.int(1)))
            }
            for row in rows where row.count > 0 {
                replyCountByGuid[row.guid] = row.count
            }
        }

        return ReplyLookup(
            originatorIdByGuid: originatorIdByGuid,
            replyCountByGuid: replyCountByGuid
        )
    }

    static func render(
        _ rows: [Reaction],
        reactorName: (String?) -> String
    ) -> [String]? {
        var reactionStrings: [String] = []
        for r in applyingRemovals(rows) {
            guard let reactionType = ReactionType(rawValue: r.type) else { continue }

            let token: String
            switch reactionType {
            case .customEmoji:
                token = r.emoji ?? "?"
            case .sticker:
                token = ReactionType.stickerToken
            default:
                token = reactionType.emoji
            }
            reactionStrings.append("\(token) \(reactorName(r.fromHandle))")
        }
        return reactionStrings.isEmpty ? nil : reactionStrings
    }
}

struct MessageRow {
    let id: Int
    let guid: String
    let text: String?
    let date: Int64?
    let isFromMe: Bool
    let senderHandle: String?
    let itemType: Int
    let groupActionType: Int
    let groupTitle: String?
    let otherHandle: String?
    let threadOriginatorGuid: String?
    let dateEdited: Int64
}

struct AttachmentRow {
    let id: Int
    let filename: String?
    let mimeType: String?
    let uti: String?
    let totalBytes: Int?
}

struct GetMessagesToolError: Error {
    let errorResponse: GetMessagesErrorResponse
}

extension GetMessagesTool {
    func resolveParticipantsToChat(participants: [String]) async throws -> String {
        var handleGroups: [Set<String>] = []

        for p in participants {
            var handlesForParticipant: Set<String> = []
            if p.hasPrefix("+") {
                handlesForParticipant.insert(p)
            } else if let normalized = PhoneUtils.normalizeToE164(p) {
                handlesForParticipant.insert(normalized)
            }

            let matches = await resolver.searchByName(p)
            for (handle, _) in matches {
                handlesForParticipant.insert(handle)
            }

            if !handlesForParticipant.isEmpty {
                handleGroups.append(handlesForParticipant)
            }
        }

        let allHandles = handleGroups.reduce(into: Set<String>()) { partialResult, handles in
            partialResult.formUnion(handles)
        }

        guard !allHandles.isEmpty else {
            throw GetMessagesToolError(errorResponse: GetMessagesErrorResponse(
                error: "invalid_participants",
                message: "Could not resolve any handles for participants: \(participants)",
                candidates: nil,
                suggestion: nil
            ))
        }

        let placeholders = allHandles.map { _ in "?" }.joined(separator: ", ")
        let sql = """
            SELECT c.ROWID, c.display_name,
                   (SELECT COUNT(DISTINCT chj.handle_id) FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID) as participant_count
            FROM chat c
            JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
            JOIN handle h ON chj.handle_id = h.ROWID
            WHERE h.id IN (\(placeholders))
            GROUP BY c.ROWID
            ORDER BY (SELECT MAX(m.date) FROM message m JOIN chat_message_join cmj ON m.ROWID = cmj.message_id WHERE cmj.chat_id = c.ROWID) DESC
            LIMIT 10
            """

        let rows = try db.query(sql, params: Array(allHandles)) { row in
            (
                id: Int(row.int(0)),
                displayName: row.string(1),
                participantCount: Int(row.int(2))
            )
        }

        let participantsByChat = try await ChatSummaryQueries.participantsByChat(
            db: db,
            chatIds: rows.map { Int64($0.id) },
            resolver: resolver
        )
        let exactMatches = rows.filter { row in
            let chatHandles = Set((participantsByChat[Int64(row.id)] ?? []).map(\.handle))
            return handleGroups.allSatisfy { !chatHandles.intersection($0).isEmpty }
        }

        if exactMatches.count == 1 {
            return "chat\(exactMatches[0].id)"
        } else if !exactMatches.isEmpty {
            throw GetMessagesToolError(errorResponse: GetMessagesErrorResponse(
                error: "ambiguous_participants",
                message: "Multiple chats found with participants: \(participants)",
                candidates: exactMatches.prefix(5).map { row in
                    GetMessagesErrorResponse.Candidate(
                        chatId: "chat\(row.id)",
                        name: row.displayName ?? "(Unnamed)",
                        participantCount: row.participantCount
                    )
                },
                suggestion: "Please specify chat_id to target the exact conversation."
            ))
        } else if rows.count == 1 {
            return "chat\(rows[0].id)"
        } else if !rows.isEmpty {
            throw GetMessagesToolError(errorResponse: GetMessagesErrorResponse(
                error: "ambiguous_participants",
                message: "Multiple chats found with participants: \(participants)",
                candidates: rows.prefix(5).map { row in
                    GetMessagesErrorResponse.Candidate(
                        chatId: "chat\(row.id)",
                        name: row.displayName ?? "(Unnamed)",
                        participantCount: row.participantCount
                    )
                },
                suggestion: "Did you mean the \(rows[0].participantCount)-person chat or a different one?"
            ))
        } else {
            throw GetMessagesToolError(errorResponse: GetMessagesErrorResponse(
                error: "chat_not_found",
                message: "No chat found with participants: \(participants)",
                candidates: nil,
                suggestion: nil
            ))
        }
    }

    func parseChatId(_ chatId: String?) -> Int? {
        guard let chatId = chatId else { return nil }
        return try? ChatIdentifier.resolve(chatId, db: db).map { Int($0) }
    }

    func getChatInfo(chatId: Int) throws -> String? {
        let rows = try db.query(
            "SELECT display_name FROM chat WHERE ROWID = ?",
            params: [chatId]
        ) { row in
            row.string(0)
        }

        guard let info = rows.first else {
            throw GetMessagesToolError(errorResponse: GetMessagesErrorResponse(
                error: "chat_not_found",
                message: "Chat not found: chat\(chatId)",
                candidates: nil,
                suggestion: nil
            ))
        }

        return info
    }

    func buildPeopleMap(chatId: Int) async throws -> (people: [String: String], handleToKey: [String: String]) {
        let handles = try await ChatSummaryQueries.participants(
            db: db,
            chatId: Int64(chatId),
            resolver: resolver
        )

        var people: [String: String] = ["me": "Me"]
        var handleToKey: [String: String] = [:]
        var unknownCount = 0

        for (i, h) in handles.enumerated() {
            let handle = h.handle
            let name = h.name

            if let name = name {
                var key = name.components(separatedBy: " ").first?.lowercased() ?? "person\(i)"
                if people[key] != nil {
                    key = "\(key)\(i)"
                }
                people[key] = name
                handleToKey[handle] = key
            } else {
                unknownCount += 1
                let key = "unknown\(unknownCount)"
                people[key] = PhoneUtils.formatDisplay(handle)
                handleToKey[handle] = key
            }
        }

        return (people, handleToKey)
    }

    func resolveFromPerson(
        fromPerson: String?,
        unanswered: Bool
    ) async -> (fromHandle: String?, fromMeOnly: Bool) {
        if unanswered {
            return (nil, true)
        }

        guard let fromPerson = fromPerson else {
            return (nil, false)
        }

        if fromPerson.lowercased() == "me" {
            return (nil, true)
        }

        if let normalized = PhoneUtils.normalizeToE164(fromPerson) {
            return (normalized, false)
        }

        let matches = await resolver.searchByName(fromPerson)
        if let first = matches.first {
            return (first.handle, false)
        }

        return (nil, false)
    }

    func queryMessages(
        chatId: Int,
        sinceApple: Int64?,
        beforeApple: Int64?,
        cursor: TimelineCursor?,
        limit: Int,
        fromHandle: String?,
        fromMeOnly: Bool,
        contains: String?,
        has: String?
    ) throws -> [MessageRow] {
        let query = QueryBuilder()
            .select(
                "m.ROWID as id",
                "m.guid",
                "m.text",
                "m.attributedBody",
                "m.date",
                "m.is_from_me",
                "h.id as sender_handle",
                "m.item_type",
                "m.group_action_type",
                "m.group_title",
                "oh.id as other_handle_id",
                "m.thread_originator_guid",
                "m.date_edited"
            )
            .from("message m")
            .join("chat_message_join cmj ON m.ROWID = cmj.message_id")
            .leftJoin("handle h ON m.handle_id = h.ROWID")
            .leftJoin("handle oh ON m.other_handle = oh.ROWID")
            .where("cmj.chat_id = ?", chatId)
            .where("m.associated_message_type = 0")

        if let since = sinceApple {
            query.where("m.date >= ?", since)
        }

        if let before = beforeApple {
            query.where("m.date <= ?", before)
        }

        if let cursor {
            query.where(cursor.olderThanSQL, cursor.date, cursor.date, cursor.messageId)
        }

        if fromMeOnly {
            query.where("m.is_from_me = 1")
        } else if let handle = fromHandle {
            query.where("h.id = ?", handle)
        }

        if let contains = contains {
            let escaped = QueryBuilder.escapeLike(contains)
            query.where("m.text LIKE ? ESCAPE '\\'", "%\(escaped)%")
        }

        if let has = has {
            switch has {
            case "links":
                query.where("(m.text LIKE '%http://%' OR m.text LIKE '%https://%')")
            case "attachments":
                query.where("""
                    EXISTS (
                        SELECT 1 FROM message_attachment_join maj
                        WHERE maj.message_id = m.ROWID
                    )
                    """)
            case "images":
                if let imagePredicate = AttachmentType.sqlPredicate(for: "image", alias: "a") {
                    query.where("""
                        EXISTS (
                            SELECT 1 FROM attachment a
                            JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
                            WHERE maj.message_id = m.ROWID
                              AND (\(imagePredicate))
                        )
                        """)
                }
            default:
                break
            }
        }

        query.orderBy("m.date DESC", "m.ROWID DESC")
            .limit(limit)

        let (sql, params) = query.build()

        return try db.query(sql, params: params) { row in
            MessageRow(
                id: Int(row.int(0)),
                guid: row.string(1) ?? "",
                text: MessageTextExtractor.extract(text: row.string(2), attributedBody: row.blob(3)),
                date: row.optionalInt(4),
                isFromMe: row.int(5) == 1,
                senderHandle: row.string(6),
                itemType: Int(row.int(7)),
                groupActionType: Int(row.int(8)),
                groupTitle: row.string(9),
                otherHandle: row.string(10),
                threadOriginatorGuid: row.string(11),
                dateEdited: row.optionalInt(12) ?? 0
            )
        }
    }

    func getReactionsMap(messageGuids: [String]) throws -> [String: [MessageAnnotations.Reaction]] {
        try MessageAnnotations.reactionsMap(db: db, messageGuids: messageGuids)
    }

    func getAttachmentsMap(messageIds: [Int]) throws -> [Int: [AttachmentRow]] {
        guard !messageIds.isEmpty else { return [:] }

        let placeholders = messageIds.map { _ in "?" }.joined(separator: ", ")
        let sql = """
            SELECT maj.message_id, a.ROWID, a.filename, a.mime_type, a.uti, a.total_bytes
            FROM attachment a
            JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
            WHERE maj.message_id IN (\(placeholders))
            """

        var map: [Int: [AttachmentRow]] = [:]

        let rows = try db.query(sql, params: messageIds) { row in
            (
                messageId: Int(row.int(0)),
                attachment: AttachmentRow(
                    id: Int(row.int(1)),
                    filename: row.string(2),
                    mimeType: row.string(3),
                    uti: row.string(4),
                    totalBytes: row.optionalInt(5).map { Int($0) }
                )
            )
        }

        for row in rows {
            if map[row.messageId] == nil {
                map[row.messageId] = []
            }
            map[row.messageId]?.append(row.attachment)
        }

        return map
    }

    func extractLinks(from text: String) -> [String] {
        let pattern = #"https?://[^\s<>\"{}|\\^`\[\]]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)

        return matches.compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    func assignSessions(
        messages: [GetMessagesResponse.MessageInfo],
        messageRows: [MessageRow]
    ) -> ([GetMessagesResponse.MessageInfo], [GetMessagesResponse.SessionInfo]) {
        guard !messages.isEmpty else { return ([], []) }

        var updatedMessages = messages
        var sessions: [GetMessagesResponse.SessionInfo] = []
        var currentSession = 1
        var sessionMessageCount = 0
        var sessionStartTs: String? = nil

        let reversedIndices = Array((0..<messages.count).reversed())

        for (i, idx) in reversedIndices.enumerated() {
            let row = messageRows[idx]
            let msgDate = row.date ?? 0

            var sessionStart = false
            var sessionGapHours: Double? = nil

            if i > 0 {
                let prevIdx = reversedIndices[i - 1]
                let prevDate = messageRows[prevIdx].date ?? 0
                let gap = msgDate - prevDate

                if gap >= sessionGapNanoseconds {
                    sessions.append(GetMessagesResponse.SessionInfo(
                        sessionId: "session_\(currentSession)",
                        started: sessionStartTs,
                        messageCount: sessionMessageCount
                    ))
                    currentSession += 1
                    sessionMessageCount = 0
                    sessionStart = true
                    let rawGapHours = Double(gap) / Double(60 * 60 * 1_000_000_000)
                    sessionGapHours = (rawGapHours * 10).rounded() / 10
                }
            } else {
                sessionStart = true
            }

            let sessionId = "session_\(currentSession)"
            sessionMessageCount += 1

            if sessionStart {
                sessionStartTs = row.date.flatMap { AppleTime.toDate($0) }.flatMap { TimeUtils.formatISO($0) }
            }

            let msg = updatedMessages[idx]
            updatedMessages[idx] = GetMessagesResponse.MessageInfo(
                id: msg.id,
                ts: msg.ts,
                text: msg.text,
                from: msg.from,
                reactions: msg.reactions,
                media: msg.media,
                attachments: msg.attachments,
                links: msg.links,
                sessionId: sessionId,
                sessionStart: sessionStart ? true : nil,
                sessionGapHours: sessionGapHours,
                event: msg.event,
                replyTo: msg.replyTo,
                replyCount: msg.replyCount
            )
        }

        sessions.append(GetMessagesResponse.SessionInfo(
            sessionId: "session_\(currentSession)",
            started: sessionStartTs,
            messageCount: sessionMessageCount
        ))

        sessions.reverse()

        return (updatedMessages, sessions)
    }

    static func nextCursor(from rows: [MessageRow], limit: Int) -> String? {
        guard rows.count >= limit, let last = rows.last else { return nil }
        return TimelineCursor.encode(date: last.date, messageId: Int64(last.id))
    }
}
