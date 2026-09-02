import Foundation

/// Batched query layer for list/overview tools.
///
/// Replaces per-chat N+1 participant and last-message queries with two
/// IN-clause queries that cover all requested chat IDs at once.
enum ChatSummaryQueries {

    struct Participant {
        let handle: String
        let name: String?
        let service: String?
    }

    /// Mirrors `ListChats.LastMessageResult` exactly.
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

        let placeholders = chatIds.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT DISTINCT chj.chat_id, h.id as handle, h.service
            FROM chat_handle_join chj
            JOIN handle h ON chj.handle_id = h.ROWID
            WHERE chj.chat_id IN (\(placeholders))
            """

        let params: [Any] = chatIds.map { $0 as Any }

        let rows = try db.query(sql, params: params) { row in
            (chatId: row.int(0), handle: row.string(1) ?? "", service: row.string(2))
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
        // DISTINCT above collapses exact duplicate rows; this collapses the
        // rest by handle, keeping the first row seen so order stays stable.
        var result: [Int64: [Participant]] = [:]
        var seenHandlesByChat: [Int64: Set<String>] = [:]
        for chatId in chatIds {
            result[chatId] = []
        }
        for row in rows {
            guard seenHandlesByChat[row.chatId, default: []].insert(row.handle).inserted else {
                continue
            }
            let participant = Participant(
                handle: row.handle,
                name: resolvedNames[row.handle],
                service: row.service
            )
            result[row.chatId, default: []].append(participant)
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

    /// Participant-row counts keyed by chat ID. One `COUNT(*)` over the
    /// candidate set; callers that historically added 1 for "me" still do so.
    static func participantCountsByChat(
        db: Database,
        chatIds: [Int64]
    ) throws -> [Int64: Int] {
        guard !chatIds.isEmpty else { return [:] }

        let placeholders = chatIds.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT chat_id, COUNT(*)
            FROM chat_handle_join
            WHERE chat_id IN (\(placeholders))
            GROUP BY chat_id
            """

        var result: [Int64: Int] = [:]
        for chatId in chatIds {
            result[chatId] = 0
        }
        let rows = try db.query(sql, params: chatIds.map { $0 as Any }) { row in
            (chatId: row.int(0), count: Int(row.int(1)))
        }
        for row in rows {
            result[row.chatId] = row.count
        }
        return result
    }

    /// Most-recent inbound sender handles per chat, newest first, at most
    /// `perChatLimit` rows per chat. Reactions and outbound rows excluded.
    static func recentSendersByChat(
        db: Database,
        chatIds: [Int64],
        perChatLimit: Int = 50
    ) throws -> [Int64: [String]] {
        guard !chatIds.isEmpty else { return [:] }

        let placeholders = chatIds.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT chat_id, sender_handle FROM (
              SELECT cmj.chat_id AS chat_id,
                     h.id AS sender_handle,
                     ROW_NUMBER() OVER (PARTITION BY cmj.chat_id ORDER BY m.date DESC, m.ROWID DESC) AS rn
              FROM message m
              JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
              LEFT JOIN handle h ON m.handle_id = h.ROWID
              WHERE cmj.chat_id IN (\(placeholders))
                AND m.associated_message_type = 0
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

    /// Newest `message.date` keyed by chat ID. Same join as the former
    /// per-chat `MAX(m.date)` lookup: `chat_message_join` to `message`.
    static func lastMessageDatesByChat(
        db: Database,
        chatIds: [Int64]
    ) throws -> [Int64: Int64] {
        guard !chatIds.isEmpty else { return [:] }

        let placeholders = chatIds.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT cmj.chat_id, MAX(m.date)
            FROM chat_message_join cmj
            JOIN message m ON m.ROWID = cmj.message_id
            WHERE cmj.chat_id IN (\(placeholders))
            GROUP BY cmj.chat_id
            """

        var result: [Int64: Int64] = [:]
        let rows = try db.query(sql, params: chatIds.map { $0 as Any }) { row in
            (chatId: row.int(0), date: row.optionalInt(1) ?? 0)
        }
        for row in rows {
            result[row.chatId] = row.date
        }
        return result
    }

    // MARK: - Last messages

    /// Returns the newest non-reaction message per chat, keyed by chat ID.
    ///
    /// One query for all chats using a window function. Formatting defaults
    /// preserve `ListChats`' historical behavior exactly (maxLength 50,
    /// "unknown" sender fallback, `ago ?? "unknown"`). Callers with different
    /// historical output (GetActiveConversations: maxLength 80, "Unknown",
    /// nullable `ago`) pass their own values. `awaitingReply = !isFromMe`.
    ///
    /// - Parameters:
    ///   - sinceApple: When non-nil, adds `AND m.date >= ?` so only messages
    ///     at or after this Apple-epoch nanosecond timestamp are considered.
    ///     Pass `nil` to search the full history.
    ///   - previewMaxLength: Max length for the message text preview.
    ///   - unknownSenderLabel: Sender label when the message is not from me
    ///     and has no sender handle.
    ///   - agoFallback: Value for `ago` when the date cannot be formatted;
    ///     pass `nil` to keep `ago` nullable.
    ///   - onlyUnreadInbound: When true, only unread inbound messages
    ///     (`is_read = 0 AND is_from_me = 0`) are considered, matching
    ///     `get_unread`'s latest-unread selection. Default false preserves
    ///     the newest-message behavior for all existing callers.
    ///   - newestDates: Each chat's newest qualifying message date, when the
    ///     caller already computed it under the same filters passed here.
    ///     Turns the per-chat search into a seek. Ignored unless every chat in
    ///     `chatIds` has one.
    static func lastMessagesByChat(
        db: Database,
        chatIds: [Int64],
        resolver: ContactResolver,
        sinceApple: Int64? = nil,
        previewMaxLength: Int = 50,
        unknownSenderLabel: String = "unknown",
        agoFallback: String? = "unknown",
        onlyUnreadInbound: Bool = false,
        newestDates: [Int64: Int64]? = nil
    ) async throws -> [Int64: LastMessage] {
        guard !chatIds.isEmpty else { return [:] }

        // A caller that already knows each chat's newest qualifying date can
        // hand it over, and the lookup becomes a seek into message(date)
        // instead of a walk over everything the chat has ever held. Used only
        // when every requested chat has a date, so a single statement covers
        // the batch. The date must be the newest under the same filters this
        // call applies, unread ones included.
        let pinnedDates: [Int64]? = {
            guard let newestDates else { return nil }
            let pins = chatIds.compactMap { newestDates[$0] }
            return pins.count == chatIds.count ? pins : nil
        }()

        var params: [Any] = []
        let idRows: String
        if let pinnedDates {
            idRows = chatIds.map { _ in "(?,?)" }.joined(separator: ",")
            for (chatId, date) in zip(chatIds, pinnedDates) {
                params.append(chatId)
                params.append(date)
            }
        } else {
            idRows = chatIds.map { _ in "(?)" }.joined(separator: ",")
            params.append(contentsOf: chatIds.map { $0 as Any })
        }

        var sinceClause = ""
        if let since = sinceApple, pinnedDates == nil {
            // A pinned date is already at or after any `since` the caller
            // applied when it computed the date, so repeating the bound would
            // only cost another term.
            sinceClause = "\n                  AND m2.date >= ?"
            params.append(since)
        }

        let unreadClause = onlyUnreadInbound
            ? "\n                  AND m2.is_read = 0 AND m2.is_from_me = 0"
            : ""

        // One correlated LIMIT 1 per requested chat. The previous form ranked
        // every message in every requested chat with ROW_NUMBER() and then kept
        // rank 1, so a caller asking for 20 chats sorted tens of thousands of
        // rows to return 20. Ordering on m2.date (not the cached
        // chat_message_join.message_date) keeps message.date as the single
        // source of truth for recency.
        // Both forms pick the same row: newest date first, highest ROWID to
        // break a tie. The pinned form states the date instead of sorting to
        // find it, which lets the message(date) index do the work; ordering
        // still runs on message.date rather than the cached copy in
        // chat_message_join, so message.date stays the source of truth.
        let sql: String
        if pinnedDates != nil {
            sql = """
                WITH ids(chat_id, newest_date) AS (VALUES \(idRows))
                SELECT i.chat_id, m.text, m.attributedBody, m.is_from_me,
                       h.id as sender_handle, m.date, m.ROWID as message_id
                FROM ids i
                JOIN message m ON m.ROWID = (
                    SELECT cmj.message_id
                    FROM chat_message_join cmj
                    JOIN message m2 ON m2.ROWID = cmj.message_id
                    WHERE cmj.chat_id = i.chat_id
                      AND m2.associated_message_type = 0
                      AND m2.date = i.newest_date\(unreadClause)
                    ORDER BY m2.ROWID DESC
                    LIMIT 1
                )
                LEFT JOIN handle h ON m.handle_id = h.ROWID
                """
        } else {
            sql = """
                WITH ids(chat_id) AS (VALUES \(idRows))
                SELECT i.chat_id, m.text, m.attributedBody, m.is_from_me,
                       h.id as sender_handle, m.date, m.ROWID as message_id
                FROM ids i
                JOIN message m ON m.ROWID = (
                    SELECT cmj.message_id
                    FROM chat_message_join cmj
                    JOIN message m2 ON m2.ROWID = cmj.message_id
                    WHERE cmj.chat_id = i.chat_id
                      AND m2.associated_message_type = 0\(sinceClause)\(unreadClause)
                    ORDER BY m2.date DESC, m2.ROWID DESC
                    LIMIT 1
                )
                LEFT JOIN handle h ON m.handle_id = h.ROWID
                """
        }

        struct RawRow {
            let chatId: Int64
            let text: String?
            let attributedBody: Data?
            let isFromMe: Bool
            let senderHandle: String?
            let date: Int64?
            let messageId: Int64
        }

        let rows = try db.query(sql, params: params) { row in
            RawRow(
                chatId: row.int(0),
                text: row.string(1),
                attributedBody: row.blob(2),
                isFromMe: row.int(3) == 1,
                senderHandle: row.string(4),
                date: row.optionalInt(5),
                messageId: row.int(6)
            )
        }

        // Collect unique sender handles for batched name resolution.
        let uniqueHandles = Set(rows.compactMap(\.senderHandle))
        var resolvedNames: [String: String] = [:]
        for handle in uniqueHandles {
            resolvedNames[handle] = await IdentityDisplayFormatter.displayName(
                handle: handle, resolver: resolver
            )
        }

        let typesByMessage = try MessagePreviewResolver.attachmentTypesByMessage(
            db: db,
            messageIds: rows.map(\.messageId)
        )

        var result: [Int64: LastMessage] = [:]
        for row in rows {
            // Sender logic shared by both list tools; only the unknown label differs.
            let sender: String
            if row.isFromMe {
                sender = "Me"
            } else if let handle = row.senderHandle {
                sender = resolvedNames[handle] ?? IdentityDisplayFormatter.displayName(
                    handle: handle, contactName: nil
                )
            } else {
                sender = unknownSenderLabel
            }

            let date = AppleTime.toDate(row.date)
            let ago = TimeUtils.formatCompactRelative(date) ?? agoFallback

            let summary = LastMessageSummary(
                from: sender,
                text: MessagePreviewResolver.messageSummary(
                    text: row.text,
                    attributedBody: row.attributedBody,
                    maxLength: previewMaxLength,
                    attachmentTypes: typesByMessage[row.messageId] ?? []
                ),
                ago: ago,
                ts: TimeUtils.formatISO(date)
            )

            result[row.chatId] = LastMessage(
                info: summary,
                awaitingReply: !row.isFromMe
            )
        }

        return result
    }
}
