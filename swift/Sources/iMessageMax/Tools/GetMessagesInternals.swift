import Foundation

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
            throw ToolFailure("invalid_participants", "Could not resolve any handles for participants: \(participants)")
        }

        let placeholders = SQLFragments.placeholders(allHandles.count)
        let sql = """
            SELECT c.ROWID, c.display_name,
                   \(SQLFragments.participantCount()) as participant_count
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

        func candidate(_ row: (id: Int, displayName: String?, participantCount: Int)) -> GetMessagesErrorResponse.Candidate {
            let identity = ChatIdentity.from(
                chatId: Int64(row.id),
                guid: nil,
                explicitName: row.displayName,
                rows: participantsByChat[Int64(row.id)] ?? []
            )
            return GetMessagesErrorResponse.Candidate(
                chatId: identity.mcpId,
                name: identity.displayName,
                participantCount: row.participantCount
            )
        }

        if exactMatches.count == 1 {
            return ChatIdentifier.format(exactMatches[0].id)
        } else if !exactMatches.isEmpty {
            throw ToolFailure(code: "ambiguous_participants", body: GetMessagesErrorResponse(
                error: "ambiguous_participants",
                message: "Multiple chats found with participants: \(participants)",
                candidates: exactMatches.prefix(5).map(candidate),
                suggestion: "Please specify chat_id to target the exact conversation."
            ))
        } else if rows.count == 1 {
            return ChatIdentifier.format(rows[0].id)
        } else if !rows.isEmpty {
            throw ToolFailure(code: "ambiguous_participants", body: GetMessagesErrorResponse(
                error: "ambiguous_participants",
                message: "Multiple chats found with participants: \(participants)",
                candidates: rows.prefix(5).map(candidate),
                suggestion: "Did you mean the \(rows[0].participantCount)-person chat or a different one?"
            ))
        } else {
            throw ToolFailure("chat_not_found", "No chat found with participants: \(participants)")
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
            throw ToolFailure("chat_not_found", ClientErrorMessages.chatNotFound(ChatIdentifier.format(chatId)))
        }

        return info
    }

    func queryMessages(
        chatId: Int,
        sinceApple: Int64?,
        beforeApple: Int64?,
        cursor: TimelineCursor?,
        limit: Int,
        sender: SenderFilter?,
        contains: String?,
        has: String?
    ) throws -> [MessageRecord] {
        let query = QueryBuilder()
            .selectMessages(try db.schema())
            .from("message m")
            .join("chat_message_join cmj ON m.ROWID = cmj.message_id")
            .joinMessageHandles()
            .where("cmj.chat_id = ?", chatId)
            .where(SQLFragments.notReaction())

        if let since = sinceApple {
            query.where("m.date >= ?", since)
        }

        if let before = beforeApple {
            query.where("m.date <= ?", before)
        }

        if let cursor {
            query.where(cursor.olderThanSQL, cursor.date, cursor.date, cursor.messageId)
        }

        if let sender {
            query.where(sender)
        }

        if let contains = contains {
            let escaped = QueryBuilder.escapeLike(contains)
            query.where("m.text LIKE ? ESCAPE '\\'", "%\(escaped)%")
        }

        switch has {
        case "links": query.where(SQLFragments.hasLink())
        case "attachments": query.where(SQLFragments.hasAttachment())
        case "images": query.where(SQLFragments.hasAttachment(ofType: "image"))
        default: break
        }

        query.orderBy("m.date DESC", "m.ROWID DESC")
            .limit(limit)

        let (sql, params) = query.build()

        return try db.query(sql, params: params) { MessageRecord($0) }
    }

    func assignSessions(
        messages: [GetMessagesResponse.MessageInfo],
        messageRows: [MessageRecord]
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

            updatedMessages[idx].sessionId = sessionId
            updatedMessages[idx].sessionStart = sessionStart ? true : nil
            updatedMessages[idx].sessionGapHours = sessionGapHours
        }

        sessions.append(GetMessagesResponse.SessionInfo(
            sessionId: "session_\(currentSession)",
            started: sessionStartTs,
            messageCount: sessionMessageCount
        ))

        sessions.reverse()

        return (updatedMessages, sessions)
    }

}
