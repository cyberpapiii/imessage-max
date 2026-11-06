import Foundation

/// Batched query layer for list/overview tools: one IN-clause query covers
/// all requested chat IDs at once instead of one query per chat.
enum ChatSummaryQueries {

    struct Participant {
        let handle: String
        let name: String?
    }

    struct LastMessage {
        let info: LastMessageSummary
        let awaitingReply: Bool
    }

    // MARK: - Participants

    /// Returns participants grouped by chat ID.
    ///
    /// One query for all chats. Contact names are resolved with one
    /// `resolver.resolve` call per *unique* handle so the same person
    /// in many chats is not looked up repeatedly.
    static func participantsByChat(
        db: Database,
        chatIds: [Int64],
        resolver: ContactResolver
    ) async throws -> [Int64: [Participant]] {
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

        // Collect unique handles and resolve all at once.
        let uniqueHandles = Set(rows.map(\.handle))
        var resolvedNames: [String: String] = [:]
        for handle in uniqueHandles {
            if let name = await resolver.resolve(handle) {
                resolvedNames[handle] = name
            }
        }

        // Group by chat id. chat_handle_join has no unique constraint, and the
        // same handle can be joined to one chat more than once (iCloud sync
        // merges, SMS and iMessage handles that normalize to the same string).
        // DISTINCT above collapses those to one row per handle.
        var result: [Int64: [Participant]] = [:]
        for chatId in chatIds {
            result[chatId] = []
        }
        for row in rows {
            result[row.chatId, default: []].append(Participant(handle: row.handle, name: resolvedNames[row.handle]))
        }

        return result
    }

    /// Single-chat wrapper around `participantsByChat`.
    static func participants(
        db: Database,
        chatId: Int64,
        resolver: ContactResolver
    ) async throws -> [Participant] {
        try await participantsByChat(db: db, chatIds: [chatId], resolver: resolver)[chatId] ?? []
    }

    /// Most-recent inbound sender handles per chat, newest first, at most
    /// `perChatLimit` rows per chat. Reactions and outbound rows excluded.
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

    // MARK: - Last messages

    /// The newest non-reaction message per chat that `options` admits,
    /// keyed by chat ID; a chat with none is absent. One query for all
    /// chats, then one for the attachment kinds of text-less previews.
    ///
    /// - Parameter newestDates: Each chat's newest admitted message date,
    ///   when the caller's own query already found it under the same
    ///   filters. The lookup then seeks to that date instead of searching
    ///   the chat's history. Used only when every chat in `chatIds` has one.
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
            // A pinned date already satisfies the caller's `since`.
            pick = "\n      AND m2.date = i.newest_date"
        } else {
            params.append(contentsOf: chatIds.map { $0 as Any })
            if let since = options.sinceApple {
                pick = "\n      AND m2.date >= ?"
                pickParams.append(since)
            }
        }
        // A conversational last message answers awaiting_reply itself; only
        // a group event sends the lookup back for the newest one before it.
        let awaiting = "CASE WHEN \(SQLFragments.conversational("m")) THEN m.is_from_me = 0 ELSE "
            + SQLFragments.awaitingReply(chat: "i.chat_id", sinceBound: options.sinceApple != nil) + " END"
        if let since = options.sinceApple {
            params.append(since)
        }
        params += pickParams
        if options.onlyUnreadInbound {
            pick += "\n      AND \(SQLFragments.unreadInbound("m2"))"
        }

        // One correlated LIMIT 1 per chat, ordered on message.date rather
        // than the copy in chat_message_join, newest ROWID breaking ties.
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
