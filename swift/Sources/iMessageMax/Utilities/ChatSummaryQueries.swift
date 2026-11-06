import Foundation

enum ChatSummaryQueries {

    struct LastMessage {
        let info: LastMessageSummary
        let awaitingReply: Bool
    }

    static func participantsByChat(
        db: Database,
        chatIds: [Int64],
        resolver: ContactResolver
    ) async throws -> [Int64: [ResolvedParticipant]] {
        guard !chatIds.isEmpty else { return [:] }

        let placeholders = SQLFragments.placeholders(chatIds.count)
        let sql = """
            SELECT DISTINCT chj.chat_id, h.id as handle
            FROM chat_handle_join chj
            JOIN handle h ON chj.handle_id = h.ROWID
            WHERE chj.chat_id IN (\(placeholders))
            """

        let params: [Any] = chatIds.map { $0 as Any }

        let rows = try db.query(sql, params: params) { row in
            (chatId: row.int(0), handle: row.string(1) ?? "")
        }

        let uniqueHandles = Set(rows.map(\.handle))
        var resolvedNames: [String: String] = [:]
        for handle in uniqueHandles {
            if let name = await resolver.resolve(handle) {
                resolvedNames[handle] = name
            }
        }

        var result: [Int64: [ResolvedParticipant]] = [:]
        for chatId in chatIds {
            result[chatId] = []
        }
        for row in rows {
            result[row.chatId, default: []].append(ResolvedParticipant(handle: row.handle, name: resolvedNames[row.handle]))
        }

        return result
    }

    static func participants(
        db: Database,
        chatId: Int64,
        resolver: ContactResolver
    ) async throws -> [ResolvedParticipant] {
        try await participantsByChat(db: db, chatIds: [chatId], resolver: resolver)[chatId] ?? []
    }

    static func recentSendersByChat(
        db: Database,
        chatIds: [Int64],
        perChatLimit: Int = 50
    ) throws -> [Int64: [String]] {
        guard !chatIds.isEmpty else { return [:] }

        let placeholders = SQLFragments.placeholders(chatIds.count)
        let sql = """
            SELECT chat_id, sender_handle FROM (
              SELECT cmj.chat_id AS chat_id,
                     h.id AS sender_handle,
                     ROW_NUMBER() OVER (PARTITION BY cmj.chat_id ORDER BY m.date DESC, m.ROWID DESC) AS rn
              FROM message m
              JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
              LEFT JOIN handle h ON m.handle_id = h.ROWID
              WHERE cmj.chat_id IN (\(placeholders))
                AND \(SQLFragments.notReaction())
                AND m.is_from_me = 0
                AND h.id IS NOT NULL
            )
            WHERE rn <= ?
            ORDER BY chat_id, rn
            """

        var params: [Any] = chatIds.map { $0 as Any }
        params.append(perChatLimit)

        var result: [Int64: [String]] = [:]
        for chatId in chatIds {
            result[chatId] = []
        }
        let rows = try db.query(sql, params: params) { row in
            (chatId: row.int(0), handle: row.string(1) ?? "")
        }
        for row in rows {
            result[row.chatId, default: []].append(row.handle)
        }
        return result
    }

    static func lastMessagesByChat(
        db: Database,
        chatIds: [Int64],
        resolver: ContactResolver,
        options: ChatPage.LastMessageOptions = .init(),
        newestDates: [Int64: Int64]? = nil
    ) async throws -> [Int64: LastMessage] {
        guard !chatIds.isEmpty else { return [:] }

        let pinnedDates: [Int64]? = {
            guard let newestDates else { return nil }
            let pins = chatIds.compactMap { newestDates[$0] }
            return pins.count == chatIds.count ? pins : nil
        }()

        var params: [Any] = []
        var pickParams: [Any] = []
        var pick = ""
        if let pinnedDates {
            for (chatId, date) in zip(chatIds, pinnedDates) {
                params.append(chatId)
                params.append(date)
            }
            pick = "\n      AND m2.date = i.newest_date"
        } else {
            params.append(contentsOf: chatIds.map { $0 as Any })
            if let since = options.sinceApple {
                pick = "\n      AND m2.date >= ?"
                pickParams.append(since)
            }
        }
        let awaiting = "CASE WHEN \(SQLFragments.conversational("m")) THEN m.is_from_me = 0 ELSE "
            + SQLFragments.awaitingReply(chat: "i.chat_id", sinceBound: options.sinceApple != nil) + " END"
        if let since = options.sinceApple {
            params.append(since)
        }
        params += pickParams
        if options.onlyUnreadInbound {
            pick += "\n      AND \(SQLFragments.unreadInbound("m2"))"
        }

        let width = pinnedDates == nil ? 1 : 2
        let row = "(" + SQLFragments.placeholders(width) + ")"
        let sql = """
            WITH ids(\(pinnedDates == nil ? "chat_id" : "chat_id, newest_date")) AS (
              VALUES \(Array(repeating: row, count: chatIds.count).joined(separator: ","))
            )
            SELECT \(MessageRecord.selectList(try db.schema())), i.chat_id, \(awaiting)
            FROM ids i
            JOIN message m ON m.ROWID = (
              SELECT cmj.message_id
              FROM chat_message_join cmj
              JOIN message m2 ON m2.ROWID = cmj.message_id
              WHERE cmj.chat_id = i.chat_id
                AND \(SQLFragments.notReaction("m2"))\(pick)
              ORDER BY m2.date DESC, m2.ROWID DESC
              LIMIT 1
            )
            \(MessageRecord.handleJoinsSQL)
            """

        let rows = try db.query(sql, params: params) { row in
            (chatId: row.int(MessageRecord.columnCount), message: MessageRecord(row),
             awaitingReply: row.int(MessageRecord.columnCount + 1) != 0)
        }
        let messages = rows.map(\.message)

        let typesByMessage = try MessagePreviewResolver.attachmentTypesByMessage(
            db: db,
            messageIds: messages.map(\.id)
        )
        let renderer = MessageRenderer(
            annotations: .none,
            labels: await SenderLabels.displayNames(
                me: "Me", unknown: options.unknownSenderLabel, for: messages, resolver: resolver
            ),
            eventNames: await MessageRenderer.eventNames(for: messages, resolver: resolver)
        )

        var result: [Int64: LastMessage] = [:]
        for (chatId, message, awaitingReply) in rows {
            let rendered = renderer.render(message)
            let text = rendered.event?.previewText ?? MessagePreviewResolver.messageSummary(
                text: message.text,
                maxLength: options.previewMaxLength,
                attachmentTypes: typesByMessage[message.id] ?? []
            )
            result[chatId] = LastMessage(
                info: LastMessageSummary(
                    from: rendered.from,
                    text: text,
                    ago: rendered.ago ?? options.agoFallback,
                    ts: rendered.ts
                ),
                awaitingReply: awaitingReply
            )
        }
        return result
    }
}
