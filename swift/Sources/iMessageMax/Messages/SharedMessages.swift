import Foundation

/// Messages that shared attachments, one item per message with its shown
/// attachments: list_attachments' page and get_chat_details' shared summary.
enum SharedMessages {
    static func page(
        db: Database,
        resolver: ContactResolver,
        chatId: Int64?,
        sender: SenderFilter?,
        typeFilter: String?,
        since: String?,
        before: String?,
        limit: Int,
        sort: AttachmentSort,
        cursor: TimelineCursor?
    ) async throws -> (messages: [SharedMessageItem], more: Bool, cursor: String?) {
        let supportsCursor = sort != .largestFirst
        let fetchLimit = supportsCursor ? limit + 1 : limit
        let (sql, params) = try query(
            db: db,
            chatId: chatId,
            sender: sender,
            typeFilter: typeFilter,
            since: since,
            before: before,
            limit: fetchLimit,
            sort: sort,
            cursor: supportsCursor ? cursor : nil
        )

        let messageRows = try db.query(sql, params: params, map: MessageInChat.init)

        let hasMore = supportsCursor && messageRows.count > limit
        let pageRows = Array(messageRows.prefix(limit))

        let attachmentsByMessage = try attachments(
            db: db,
            messageIds: pageRows.map(\.message.id),
            typeFilter: typeFilter
        )

        let chatByID = try await ChatReferences(pageRows.chats, db: db, resolver: resolver)
        let labels = await SenderLabels.displayNames(
            me: "Me", unknown: "Unknown", for: pageRows.map(\.message), resolver: resolver
        )
        var results: [SharedMessageItem] = []

        for row in pageRows {
            let attachments = attachmentsByMessage[row.message.id] ?? []
            guard !attachments.isEmpty else { continue }

            let attachmentTypes = attachments.map(\.type)
            let date = AppleTime.toDate(row.message.date)
            let messagePreview = SummaryPreviewFormatter.formattedTextPreview(
                text: row.message.text,
                attributedBody: nil,
                maxLength: 80
            )

            results.append(
                SharedMessageItem(
                    messageId: MessageIdentifier.format(row.message.id),
                    chat: chatByID[row.chatId],
                    from: labels.sender(row.message),
                    messagePreview: messagePreview,
                    sharedSummary: SummaryPreviewFormatter.sharedSummary(for: attachmentTypes),
                    ts: TimeUtils.formatISO(date),
                    ago: TimeUtils.formatCompactRelative(date),
                    attachments: attachments.map { attachment in
                        SharedAttachmentSummary(
                            id: AttachmentIdentifier.format(attachment.id),
                            type: attachment.type.rawValue,
                            name: attachment.name,
                            available: attachment.available,
                            sizeHuman: attachment.sizeHuman
                        )
                    }
                )
            )
        }

        let nextCursor = TimelineCursor.next(after: pageRows.last?.message, pageFull: hasMore)

        return (results, nextCursor != nil, nextCursor)
    }

    private static func query(
        db: Database,
        chatId: Int64?,
        sender: SenderFilter?,
        typeFilter: String?,
        since: String?,
        before: String?,
        limit: Int,
        sort: AttachmentSort,
        cursor: TimelineCursor?
    ) throws -> (String, [Any]) {
        let schema = try db.schema()
        let typeClause = AttachmentType.sqlPredicate(for: typeFilter, alias: "a")
            .map { " AND (\($0))" } ?? ""

        // The two sort families want different shapes. largest_first has to
        // rank every attachment message before it knows which page to return,
        // so it reads the attachment tables in one pass and collapses the rows
        // that join produces with GROUP BY m.ROWID. The date sorts can walk
        // message_idx_date and stop at LIMIT, but only if nothing forces a
        // GROUP BY first, so they resolve the chat and the attachments with
        // subqueries that keep the result one row per message on their own.
        let ranksBySize = sort == .largestFirst
        let query = QueryBuilder()
        // One row per message: a message in the filtered chat is listed
        // under that chat, any other under its home chat.
        let chat = chatId.map(String.init) ?? SQLFragments.homeChat()

        if ranksBySize {
            query
                .selectMessages(schema, MessageInChat.chatColumns, "MAX(COALESCE(a.total_bytes, 0)) as max_attachment_size")
                .from("message m")
                .join("chat c ON c.ROWID = \(chat)")
                .joinMessageHandles()
                .join("message_attachment_join maj ON m.ROWID = maj.message_id")
                .join("attachment a ON maj.attachment_id = a.ROWID")
                .where(SQLFragments.notReaction())
                .where(SQLFragments.shownAttachment("a"))
            if let pred = AttachmentType.sqlPredicate(for: typeFilter, alias: "a") {
                query.where("(\(pred))")
            }
            query.groupBy("m.ROWID")
        } else {
            let sizeSelect = """
                (SELECT MAX(COALESCE(a.total_bytes, 0))
                 FROM message_attachment_join maj
                 JOIN attachment a ON maj.attachment_id = a.ROWID
                 WHERE maj.message_id = m.ROWID AND \(SQLFragments.shownAttachment("a"))\(typeClause)) as max_attachment_size
                """
            query
                .selectMessages(schema, MessageInChat.chatColumns, sizeSelect)
                .from("message m")
                .join("chat c ON c.ROWID = \(chat)")
                .joinMessageHandles()
                .where(SQLFragments.notReaction())
                .where(SQLFragments.hasAttachment(ofType: typeFilter))
        }
        if let chatId {
            query.where(SQLFragments.messageInChat(), chatId)
        } else {
            // A chat named outright is shown even when Messages.app hides it.
            query.where(SQLFragments.shownChat())
        }

        if let sender {
            query.where(sender)
        }

        if let since, let sinceTs = AppleTime.parse(since) {
            query.where("m.date >= ?", sinceTs)
        }

        if let before, let beforeTs = AppleTime.parse(before) {
            query.where("m.date <= ?", beforeTs)
        }

        if let cursor {
            let after = cursor.predicate(descending: sort == .recentFirst)
            query.where(after.sql, params: after.params)
        }

        switch sort {
        case .recentFirst:
            query.orderBy("m.date DESC", "m.ROWID DESC")
        case .oldestFirst:
            query.orderBy("m.date ASC", "m.ROWID ASC")
        case .largestFirst:
            query.orderBy("max_attachment_size DESC", "m.date DESC", "m.ROWID DESC")
        }

        query.limit(limit)
        return query.build()
    }

    typealias AttachmentSummary = (
        id: Int64, type: AttachmentType, name: String?, available: Bool, sizeHuman: String?
    )

    static func attachments(
        db: Database,
        messageIds: [Int64],
        typeFilter: String?,
        allowedRoots: [String] = AttachmentPathPolicy.defaultRoots
    ) throws -> [Int64: [AttachmentSummary]] {
        try MessageAnnotations.attachmentsByMessage(db: db, messageIds: messageIds, ofType: typeFilter)
            .mapValues { attachments in
                attachments.map { attachment in
                    // Route through policy: paths outside allowed roots are treated as unavailable,
                    // identical to a missing file. List output stays total (no error thrown).
                    let path = attachment.filename
                    let validatedPath = path.flatMap { AttachmentPathPolicy.validatedPath($0, allowedRoots: allowedRoots) }
                    return (
                        id: attachment.id,
                        type: AttachmentType.from(mimeType: attachment.mimeType, uti: attachment.uti),
                        name: path.map { ($0 as NSString).lastPathComponent },
                        available: validatedPath.map { FileManager.default.fileExists(atPath: $0) } ?? false,
                        sizeHuman: attachment.totalBytes.map { FormatUtils.fileSize($0) }
                    )
                }
            }
    }
}
