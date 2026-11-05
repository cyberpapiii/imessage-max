import Foundation
import MCP

enum AttachmentSort: String {
    case recentFirst = "recent_first"
    case oldestFirst = "oldest_first"
    case largestFirst = "largest_first"
}

struct ListAttachmentsResponse: Codable {
    let messages: [SharedMessageItem]
    let total: Int
    let more: Bool
    let cursor: String?
}

final class ListAttachments {
    static let limit = IntArgument(name: "limit", defaultValue: 50, range: 1...100)

    private let db: Database
    private let resolver: ContactResolver

    init(db: Database, resolver: ContactResolver) {
        self.db = db
        self.resolver = resolver
    }

    // MARK: - Tool Registration

    static func definition(db: Database, resolver: ContactResolver) -> ToolDefinition {
        let inputSchema: Value = .object([
            "type": "object",
            "properties": .object([
                "chat_id": .object([
                    "type": "string",
                    "description": "Filter to specific chat (e.g., \"chat123\")",
                ]),
                "from_person": .object([
                    "type": "string",
                    "description": "Filter by sender (or \"me\")",
                ]),
                "type": .object([
                    "type": "string",
                    "description": "Filter by type",
                    "enum": ["image", "video", "audio", "pdf", "document", "any"],
                ]),
                "since": .object([
                    "type": "string",
                    "description": "Lower time bound (ISO, relative, or natural)",
                ]),
                "before": .object([
                    "type": "string",
                    "description": "Upper time bound",
                ]),
                "limit": .object([
                    "type": "integer",
                    "description": "Max results (\(Self.limit.defaultAndMax))",
                ]),
                "sort": .object([
                    "type": "string",
                    "description": "Sort order",
                    "enum": ["recent_first", "oldest_first", "largest_first"],
                ]),
                "cursor": .object([
                    "type": "string",
                    "description": "Pagination cursor from a previous list_attachments response (date sorts only)",
                ]),
            ]),
            "additionalProperties": false,
        ])

        return ToolDefinition(
            name: "list_attachments",
            description: "Browse shared items grouped by message. Returns chat ids for follow-up tool calls and chat names for user-facing summaries. When explaining results to the user, refer to chats by name, not by id. Good for discovering the message where photos, videos, audio, PDFs, or documents were sent before fetching a specific attachment.",
            inputSchema: inputSchema,
            outputSchema: OutputSchema.object,
            annotations: Tool.Annotations(
                title: "List Attachments",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let chatId = arguments?["chat_id"]?.stringValue
            let fromPerson = arguments?["from_person"]?.stringValue
            let type = arguments?["type"]?.stringValue
            let since = arguments?["since"]?.stringValue
            let before = arguments?["before"]?.stringValue
            let limit = Self.limit.read(arguments)
            let sort = arguments?["sort"]?.stringValue ?? "recent_first"
            let cursor = arguments?["cursor"]?.stringValue

            let tool = ListAttachments(db: db, resolver: resolver)
            let result = try await tool.execute(
                chatId: chatId,
                fromPerson: fromPerson,
                type: type,
                since: since,
                before: before,
                limit: limit,
                sort: sort,
                cursor: cursor
            )

            return [.plainText(try FormatUtils.encodeJSON(result))]
        }
    }

    func execute(
        chatId: String? = nil,
        fromPerson: String? = nil,
        type: String? = nil,
        since: String? = nil,
        before: String? = nil,
        limit: Int = 50,
        sort: String = "recent_first",
        cursor: String? = nil
    ) async throws -> ListAttachmentsResponse {
        let effectiveLimit = Self.limit.clamp(limit)
        let effectiveSort = AttachmentSort(rawValue: sort) ?? .recentFirst

        let validTypes = Set(["image", "video", "audio", "pdf", "document", "any"])
        let typeFilter: String? = if let t = type, validTypes.contains(t) { t } else { nil }

        let numericChatId: Int64?
        if let chatId {
            guard let cid = ChatIdentifier.parseRowId(chatId) else {
                throw ToolFailure("invalid_id", "Invalid chat ID format: \(chatId)")
            }
            numericChatId = cid
        } else {
            numericChatId = nil
        }

        let timelineCursor = cursor.flatMap(TimelineCursor.decode)
        let (sharedMessages, hasMore, nextCursor) = try await browseSharedMessages(
            chatId: numericChatId,
            fromPerson: fromPerson,
            typeFilter: typeFilter,
            since: since,
            before: before,
            limit: effectiveLimit,
            sort: effectiveSort,
            cursor: timelineCursor
        )

        return ListAttachmentsResponse(
            messages: sharedMessages,
            total: sharedMessages.count,
            more: hasMore,
            cursor: nextCursor
        )
    }

    // MARK: - Private Helpers

    func browseSharedMessages(
        chatId: Int64?,
        fromPerson: String?,
        typeFilter: String?,
        since: String?,
        before: String?,
        limit: Int,
        sort: AttachmentSort,
        cursor: TimelineCursor?
    ) async throws -> (messages: [SharedMessageItem], more: Bool, cursor: String?) {
        let supportsCursor = sort != .largestFirst
        let fetchLimit = supportsCursor ? limit + 1 : limit
        let (sql, params) = try buildMessageQuery(
            chatId: chatId,
            sender: await SenderFilter.resolve(fromPerson, resolver: resolver),
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

        let attachmentsByMessage = try attachmentsForMessages(
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

    private func buildMessageQuery(
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

        if ranksBySize {
            query
                .selectMessages(schema, MessageInChat.chatColumns, "MAX(COALESCE(a.total_bytes, 0)) as max_attachment_size")
                .from("message m")
                .join("chat_message_join cmj ON m.ROWID = cmj.message_id")
                .join("chat c ON cmj.chat_id = c.ROWID")
                .joinMessageHandles()
                .join("message_attachment_join maj ON m.ROWID = maj.message_id")
                .join("attachment a ON maj.attachment_id = a.ROWID")
                .where(SQLFragments.notReaction())
                .where(SQLFragments.shownAttachment("a"))
            if let chatId {
                query.where("c.ROWID = ?", chatId)
            }
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
            // A message can belong to more than one chat, so picking the chat
            // with a subquery keeps the result one row per message without the
            // GROUP BY that joining chat_message_join would require.
            var chatPick = "SELECT cmj.chat_id FROM chat_message_join cmj"
                + " WHERE cmj.message_id = m.ROWID"
            var chatPickParams: [Any] = []
            if let chatId {
                chatPick += " AND cmj.chat_id = ?"
                chatPickParams.append(chatId)
            }
            chatPick += " ORDER BY cmj.chat_id LIMIT 1"

            query
                .selectMessages(schema, MessageInChat.chatColumns, sizeSelect)
                .from("message m")
                .join("chat c ON c.ROWID = (\(chatPick))", params: chatPickParams)
                .joinMessageHandles()
                .where(SQLFragments.notReaction())
                .where(SQLFragments.hasAttachment(ofType: typeFilter))
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
            switch sort {
            case .recentFirst:
                query.where(cursor.olderThanSQL, params: cursor.olderThanParams)
            case .oldestFirst:
                query.where(cursor.newerThanSQL, params: cursor.newerThanParams)
            case .largestFirst:
                break
            }
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

    func attachmentsForMessages(
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
