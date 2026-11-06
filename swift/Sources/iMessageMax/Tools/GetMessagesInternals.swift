import Foundation

extension GetMessagesTool {
    func resolveParticipantsToChat(participants: [String]) async throws -> String {
        let match = await ParticipantChats.resolve(participants, resolver: resolver)
        guard match.unresolved.isEmpty else {
            throw ToolFailure("invalid_participants", "Could not resolve any handles for participants: \(match.unresolved)")
        }

        let chats = try match.chats(db: db, order: .recent, limit: 5)
        guard chats.count != 1 else { return ChatIdentifier.format(chats[0].id) }
        guard !chats.isEmpty else {
            throw ToolFailure("chat_not_found", "No chat found with participants: \(participants)")
        }

        let participantsByChat = try await ChatSummaryQueries.participantsByChat(
            db: db,
            chatIds: chats.map(\.id),
            resolver: resolver
        )
        throw ToolFailure(code: "ambiguous_participants", body: GetMessagesErrorResponse(
            error: "ambiguous_participants",
            message: "Multiple chats found with participants: \(participants)",
            candidates: chats.map { chat in
                let identity = ChatIdentity.from(
                    chatId: chat.id,
                    guid: nil,
                    explicitName: chat.displayName,
                    rows: participantsByChat[chat.id] ?? []
                )
                return GetMessagesErrorResponse.Candidate(
                    chatId: identity.mcpId,
                    name: identity.displayName,
                    participantCount: chat.participantCount
                )
            },
            suggestion: "Specify chat_id to target the exact conversation."
        ))
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
            let older = cursor.predicate(descending: true)
            query.where(older.sql, params: older.params)
        }

        if let sender {
            query.where(sender)
        }

        if let contains {
            let match = SQLFragments.textMayContain(contains)
            query.where(match.sql, params: match.bindings)
        }

        if let has = SQLFragments.has(has) {
            query.where(has)
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
