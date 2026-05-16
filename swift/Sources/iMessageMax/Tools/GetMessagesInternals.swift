import Foundation

struct GetMessagesCursor {
    let date: Int64
    let messageId: Int
}

struct MessageRow {
    let id: Int
    let guid: String
    let text: String?
    let date: Int64?
    let isFromMe: Bool
    let senderHandle: String?
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

        let exactMatches = try rows.filter { row in
            let chatHandles = try getHandlesForChat(chatId: row.id)
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

        if chatId.hasPrefix("chat"), let numId = Int(chatId.dropFirst(4)) {
            return numId
        }

        let rows = try? db.query(
            "SELECT ROWID FROM chat WHERE guid LIKE ?",
            params: ["%\(chatId)%"]
        ) { row in
            Int(row.int(0))
        }

        return rows?.first
    }

    func getChatInfo(chatId: Int) throws -> (displayName: String?, serviceName: String?) {
        let rows = try db.query(
            "SELECT display_name, service_name FROM chat WHERE ROWID = ?",
            params: [chatId]
        ) { row in
            (displayName: row.string(0), serviceName: row.string(1))
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
        let sql = """
            SELECT h.id, h.service
            FROM handle h
            JOIN chat_handle_join chj ON h.ROWID = chj.handle_id
            WHERE chj.chat_id = ?
            """

        let handles = try db.query(sql, params: [chatId]) { row in
            (handle: row.string(0) ?? "", service: row.string(1))
        }

        var people: [String: String] = ["me": "Me"]
        var handleToKey: [String: String] = [:]
        var unknownCount = 0

        for (i, h) in handles.enumerated() {
            let handle = h.handle
            let name = await resolver.resolve(handle)

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

    func getHandlesForChat(chatId: Int) throws -> Set<String> {
        let sql = """
            SELECT h.id
            FROM handle h
            JOIN chat_handle_join chj ON h.ROWID = chj.handle_id
            WHERE chj.chat_id = ?
            """

        let handles = try db.query(sql, params: [chatId]) { row in
            row.string(0) ?? ""
        }

        return Set(handles)
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
        cursor: GetMessagesCursor?,
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
                "h.id as sender_handle"
            )
            .from("message m")
            .join("chat_message_join cmj ON m.ROWID = cmj.message_id")
            .leftJoin("handle h ON m.handle_id = h.ROWID")
            .where("cmj.chat_id = ?", chatId)
            .where("m.associated_message_type = 0")

        if let since = sinceApple {
            query.where("m.date >= ?", since)
        }

        if let before = beforeApple {
            query.where("m.date <= ?", before)
        }

        if let cursor {
            query.where("(m.date < ? OR (m.date = ? AND m.ROWID < ?))", cursor.date, cursor.date, cursor.messageId)
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
            case "attachments", "images":
                query.join("message_attachment_join maj ON m.ROWID = maj.message_id")
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
                senderHandle: row.string(6)
            )
        }
    }

    func filterUnanswered(
        messageRows: [MessageRow],
        chatId: Int,
        hours: Int,
        limit: Int
    ) throws -> [MessageRow] {
        var filtered: [MessageRow] = []

        for row in messageRows {
            guard let text = row.text, looksLikeQuestion(text) else { continue }
            guard let date = row.date else { continue }

            let hasReply = try hasReplyWithinWindow(chatId: chatId, messageDate: date, hours: hours)
            if !hasReply {
                filtered.append(row)
                if filtered.count >= limit {
                    break
                }
            }
        }

        return filtered
    }

    func looksLikeQuestion(_ text: String) -> Bool {
        if text.contains("?") { return true }

        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
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
            if lower.hasSuffix(ending) { return true }
        }

        return false
    }

    func hasReplyWithinWindow(chatId: Int, messageDate: Int64, hours: Int) throws -> Bool {
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

    func getReactionsMap(messageGuids: [String]) throws -> [String: [(type: Int, fromHandle: String?)]] {
        guard !messageGuids.isEmpty else { return [:] }

        let placeholders = messageGuids.map { _ in "?" }.joined(separator: ", ")
        let sql = """
            SELECT m.associated_message_guid, m.associated_message_type, h.id
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.associated_message_guid IN (\(placeholders))
            AND m.associated_message_type >= 2000
            """

        var map: [String: [(type: Int, fromHandle: String?)]] = [:]

        let rows = try db.query(sql, params: messageGuids) { row in
            (
                guid: row.string(0) ?? "",
                type: Int(row.int(1)),
                fromHandle: row.string(2)
            )
        }

        for row in rows {
            let originalGuid = row.guid.hasPrefix("p:") || row.guid.hasPrefix("bp:")
                ? String(row.guid.split(separator: "/").last ?? "")
                : row.guid

            if map[originalGuid] == nil {
                map[originalGuid] = []
            }
            map[originalGuid]?.append((type: row.type, fromHandle: row.fromHandle))
        }

        return map
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

    func getAttachmentType(mimeType: String?, uti: String?) -> String {
        let mime = (mimeType ?? "").lowercased()
        let utiStr = (uti ?? "").lowercased()

        if mime.contains("image") || utiStr.contains("image") ||
           utiStr.contains("jpeg") || utiStr.contains("png") || utiStr.contains("heic") {
            return "image"
        } else if mime.contains("video") || utiStr.contains("movie") || utiStr.contains("video") {
            return "video"
        } else if mime.contains("audio") || utiStr.contains("audio") {
            return "audio"
        } else if mime.contains("pdf") || utiStr.contains("pdf") {
            return "pdf"
        }
        return "other"
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

        let reversedIndices = (0..<messages.count).reversed()

        for (i, idx) in reversedIndices.enumerated() {
            let row = messageRows[idx]
            let msgDate = row.date ?? 0

            var sessionStart = false
            var sessionGapHours: Double? = nil

            if i > 0 {
                let prevIdx = Array(reversedIndices)[i - 1]
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
                sessionGapHours: sessionGapHours
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

    static func decodeCursor(_ raw: String) -> GetMessagesCursor? {
        let parts = raw.split(separator: ":")
        guard parts.count == 2,
              let date = Int64(parts[0]),
              let messageId = Int(parts[1]) else {
            return nil
        }
        return GetMessagesCursor(date: date, messageId: messageId)
    }

    static func encodeCursor(date: Int64?, messageId: Int) -> String? {
        guard let date else { return nil }
        return "\(date):\(messageId)"
    }

    static func nextCursor(from rows: [MessageRow], limit: Int) -> String? {
        guard rows.count >= limit, let last = rows.last else { return nil }
        return encodeCursor(date: last.date, messageId: last.id)
    }
}
