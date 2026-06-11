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
            SELECT chj.chat_id, h.id as handle, h.service
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

        // Group by chat id.
        var result: [Int64: [Participant]] = [:]
        for chatId in chatIds {
            result[chatId] = []
        }
        for row in rows {
            let participant = Participant(
                handle: row.handle,
                name: resolvedNames[row.handle],
                service: row.service
            )
            result[row.chatId, default: []].append(participant)
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
    static func lastMessagesByChat(
        db: Database,
        chatIds: [Int64],
        resolver: ContactResolver,
        sinceApple: Int64? = nil,
        previewMaxLength: Int = 50,
        unknownSenderLabel: String = "unknown",
        agoFallback: String? = "unknown",
        onlyUnreadInbound: Bool = false
    ) async throws -> [Int64: LastMessage] {
        guard !chatIds.isEmpty else { return [:] }

        let placeholders = chatIds.map { _ in "?" }.joined(separator: ",")
        var sinceClause = ""
        var params: [Any] = chatIds.map { $0 as Any }
        if let since = sinceApple {
            sinceClause = "\n    AND m.date >= ?"
            params.append(since)
        }

        let unreadClause = onlyUnreadInbound
            ? "\n    AND m.is_read = 0 AND m.is_from_me = 0"
            : ""

        let sql = """
            SELECT chat_id, text, attributedBody, is_from_me, sender_handle, date, message_id FROM (
                SELECT cmj.chat_id as chat_id, m.text, m.attributedBody, m.is_from_me,
                       h.id as sender_handle, m.date, m.ROWID as message_id,
                       ROW_NUMBER() OVER (PARTITION BY cmj.chat_id ORDER BY m.date DESC) as rn
                FROM message m
                JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
                LEFT JOIN handle h ON m.handle_id = h.ROWID
                WHERE cmj.chat_id IN (\(placeholders))\(sinceClause)\(unreadClause)
                AND m.associated_message_type = 0
            ) WHERE rn = 1
            """

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
                text: try MessagePreviewResolver.messageSummary(
                    db: db,
                    messageId: row.messageId,
                    text: row.text,
                    attributedBody: row.attributedBody,
                    maxLength: previewMaxLength
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
