// Sources/iMessageMax/Tools/ListAttachments.swift
import Foundation
import MCP

/// Sort options for attachments
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

/// Error result
struct ListAttachmentsError: LocalizedError, Codable {
    let error: String
    let message: String

    var errorDescription: String? {
        message
    }
}

/// List attachments tool implementation
final class ListAttachments {
    private let db: Database
    private let resolver: ContactResolver

    init(db: Database = Database(), resolver: ContactResolver = ContactResolver()) {
        self.db = db
        self.resolver = resolver
    }

    // MARK: - Tool Registration

    static func register(on server: Server, db: Database, resolver: ContactResolver) {
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
                    "description": "Max results (default 50, max 100)",
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

        server.registerTool(
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
            let limit = arguments?["limit"]?.intValue ?? 50
            let sort = arguments?["sort"]?.stringValue ?? "recent_first"
            let cursor = arguments?["cursor"]?.stringValue

            let tool = ListAttachments(db: db, resolver: resolver)
            let result = await tool.execute(
                chatId: chatId,
                fromPerson: fromPerson,
                type: type,
                since: since,
                before: before,
                limit: limit,
                sort: sort,
                cursor: cursor
            )

            switch result {
            case .success(let response):
                return [.plainText(try FormatUtils.encodeJSON(response))]
            case .failure(let error):
                throw ToolError(content: [.plainText(try FormatUtils.encodeJSON(error))])
            }
        }
    }

    /// List attachments with filters
    /// - Parameters:
    ///   - chatId: Filter to specific chat (e.g., "chat123" or "123")
    ///   - fromPerson: Filter by sender handle (or "me")
    ///   - type: Filter by type: "image", "video", "audio", "pdf", "document", "any"
    ///   - since: Lower time bound (ISO, relative like "24h", or natural like "yesterday")
    ///   - before: Upper time bound
    ///   - limit: Max results (default 50, max 100)
    ///   - sort: "recent_first" (default), "oldest_first", "largest_first"
    func execute(
        chatId: String? = nil,
        fromPerson: String? = nil,
        type: String? = nil,
        since: String? = nil,
        before: String? = nil,
        limit: Int = 50,
        sort: String = "recent_first",
        cursor: String? = nil
    ) async -> Result<ListAttachmentsResponse, ListAttachmentsError> {
        // Validate and constrain inputs
        let effectiveLimit = max(1, min(limit, 100))
        let effectiveSort = AttachmentSort(rawValue: sort) ?? .recentFirst

        // Validate type filter
        let validTypes = Set(["image", "video", "audio", "pdf", "document", "any"])
        let typeFilter: String? = if let t = type, validTypes.contains(t) { t } else { nil }

        // Initialize contact resolver
        do {
            try await resolver.initialize()
        } catch {
            // Continue without contact resolution
        }

        do {
            let numericChatId: Int64?
            if let chatId {
                guard let cid = ChatIdentifier.parseRowId(chatId) else {
                    return .failure(ListAttachmentsError(
                        error: "invalid_id",
                        message: "Invalid chat ID format: \(chatId)"
                    ))
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

            return .success(ListAttachmentsResponse(
                messages: sharedMessages,
                total: sharedMessages.count,
                more: hasMore,
                cursor: nextCursor
            ))

        } catch let error as DatabaseError {
            switch error {
            case .notFound:
                return .failure(ListAttachmentsError(
                    error: "database_not_found",
                    message: ClientErrorMessages.databaseNotFound
                ))
            case .permissionDenied:
                return .failure(ListAttachmentsError(
                    error: "permission_denied",
                    message: ClientErrorMessages.permissionDenied
                ))
            case .queryFailed(let msg):
                return .failure(ListAttachmentsError(
                    error: "query_failed",
                    message: msg
                ))
            case .invalidData(let msg):
                return .failure(ListAttachmentsError(
                    error: "invalid_data",
                    message: msg
                ))
            }
        } catch {
            return .failure(ListAttachmentsError(
                error: "internal_error",
                message: ClientErrorMessages.sanitized(error)
            ))
        }
    }

    // MARK: - Private Helpers

    private struct SharedMessageRow {
        let msgId: Int64
        let text: String?
        let attributedBody: Data?
        let date: Int64?
        let isFromMe: Bool
        let senderHandle: String?
        let chatId: Int64
        let chatName: String?
    }

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
        let (sql, params) = buildMessageQuery(
            chatId: chatId,
            fromPerson: fromPerson,
            typeFilter: typeFilter,
            since: since,
            before: before,
            limit: fetchLimit,
            sort: sort,
            cursor: supportsCursor ? cursor : nil
        )

        let messageRows = try db.query(sql, params: params) { row in
            SharedMessageRow(
                msgId: row.int(0),
                text: row.string(1),
                attributedBody: row.blob(2),
                date: row.optionalInt(3),
                isFromMe: row.int(4) == 1,
                senderHandle: row.string(5),
                chatId: row.int(6),
                chatName: row.string(7)
            )
        }

        let hasMore = supportsCursor && messageRows.count > limit
        let pageRows = Array(messageRows.prefix(limit))

        // One lookup for the whole page. Asking per message opened a fresh
        // SQLite connection for each of the twenty rows a default page holds.
        let attachmentsByMessage = try attachmentsForMessages(
            messageIds: pageRows.map(\.msgId),
            typeFilter: typeFilter
        )

        var chatNameCache: [Int64: String] = [:]
        var results: [SharedMessageItem] = []

        for row in pageRows {
            let attachments = attachmentsByMessage[row.msgId] ?? []
            guard !attachments.isEmpty else { continue }

            let senderName: String
            if row.isFromMe {
                senderName = "Me"
            } else if let handle = row.senderHandle {
                senderName = await IdentityDisplayFormatter.displayName(handle: handle, resolver: resolver)
            } else {
                senderName = "Unknown"
            }

            let chatReference = ChatReference(
                id: "chat\(row.chatId)",
                name: try await resolveChatName(
                    chatId: row.chatId,
                    explicitName: row.chatName,
                    cache: &chatNameCache
                )
            )

            let attachmentTypes = attachments.map(\.type)
            let date = AppleTime.toDate(row.date)
            let messagePreview = SummaryPreviewFormatter.formattedTextPreview(
                text: row.text,
                attributedBody: row.attributedBody,
                maxLength: 80
            )

            results.append(
                SharedMessageItem(
                    messageId: "msg_\(row.msgId)",
                    chat: chatReference,
                    from: senderName,
                    messagePreview: messagePreview,
                    sharedSummary: SummaryPreviewFormatter.sharedSummary(for: attachmentTypes),
                    ts: TimeUtils.formatISO(date),
                    ago: TimeUtils.formatCompactRelative(date),
                    attachments: attachments.map { attachment in
                        SharedAttachmentSummary(
                            id: "att\(attachment.id)",
                            type: attachment.type.rawValue,
                            name: attachment.name,
                            available: attachment.available,
                            sizeHuman: attachment.sizeHuman
                        )
                    }
                )
            )
        }

        let nextCursor: String?
        if hasMore, let last = pageRows.last {
            nextCursor = TimelineCursor.encode(date: last.date, messageId: last.msgId)
        } else {
            nextCursor = nil
        }

        return (results, hasMore, nextCursor)
    }

    private func buildMessageQuery(
        chatId: Int64?,
        fromPerson: String?,
        typeFilter: String?,
        since: String?,
        before: String?,
        limit: Int,
        sort: AttachmentSort,
        cursor: TimelineCursor?
    ) -> (String, [Any]) {
        var params: [Any] = []

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

        let sizeSelect: String
        let fromClause: String
        var whereClause = "WHERE m.associated_message_type = 0"

        if ranksBySize {
            sizeSelect = "MAX(COALESCE(a.total_bytes, 0)) as max_attachment_size"
            fromClause = """
                FROM message m
                JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
                JOIN chat c ON cmj.chat_id = c.ROWID
                LEFT JOIN handle h ON m.handle_id = h.ROWID
                JOIN message_attachment_join maj ON m.ROWID = maj.message_id
                JOIN attachment a ON maj.attachment_id = a.ROWID
                """
            if let chatId {
                whereClause += " AND c.ROWID = ?"
                params.append(chatId)
            }
            whereClause += typeClause
        } else {
            sizeSelect = """
                (SELECT MAX(COALESCE(a.total_bytes, 0))
                 FROM message_attachment_join maj
                 JOIN attachment a ON maj.attachment_id = a.ROWID
                 WHERE maj.message_id = m.ROWID\(typeClause)) as max_attachment_size
                """
            // A message can belong to more than one chat, so picking the chat
            // with a subquery keeps the result one row per message without the
            // GROUP BY that joining chat_message_join would require.
            var chatPick = "SELECT cmj.chat_id FROM chat_message_join cmj"
                + " WHERE cmj.message_id = m.ROWID"
            if let chatId {
                chatPick += " AND cmj.chat_id = ?"
                params.append(chatId)
            }
            chatPick += " ORDER BY cmj.chat_id LIMIT 1"

            fromClause = """
                FROM message m
                JOIN chat c ON c.ROWID = (\(chatPick))
                LEFT JOIN handle h ON m.handle_id = h.ROWID
                """
            whereClause += """
                 AND EXISTS (SELECT 1
                             FROM message_attachment_join maj
                             JOIN attachment a ON maj.attachment_id = a.ROWID
                             WHERE maj.message_id = m.ROWID\(typeClause))
                """
        }

        var sql = """
            SELECT
                m.ROWID as msg_id,
                m.text,
                m.attributedBody,
                m.date,
                m.is_from_me,
                h.id as sender_handle,
                c.ROWID as chat_id,
                c.display_name as chat_name,
                \(sizeSelect)
            \(fromClause)
            \(whereClause)
            """

        if let fromPerson {
            if fromPerson.lowercased() == "me" {
                sql += " AND m.is_from_me = 1"
            } else {
                sql += " AND h.id LIKE ? ESCAPE '\\'"
                params.append("%\(QueryBuilder.escapeLike(fromPerson))%")
            }
        }

        if let since, let sinceTs = AppleTime.parse(since) {
            sql += " AND m.date >= ?"
            params.append(sinceTs)
        }

        if let before, let beforeTs = AppleTime.parse(before) {
            sql += " AND m.date <= ?"
            params.append(beforeTs)
        }

        if let cursor {
            switch sort {
            case .recentFirst:
                sql += " AND \(cursor.olderThanSQL)"
                params.append(contentsOf: cursor.olderThanParams)
            case .oldestFirst:
                sql += " AND \(cursor.newerThanSQL)"
                params.append(contentsOf: cursor.newerThanParams)
            case .largestFirst:
                break
            }
        }

        if ranksBySize {
            sql += " GROUP BY m.ROWID"
        }

        switch sort {
        case .recentFirst:
            sql += " ORDER BY m.date DESC, m.ROWID DESC"
        case .oldestFirst:
            sql += " ORDER BY m.date ASC, m.ROWID ASC"
        case .largestFirst:
            sql += " ORDER BY max_attachment_size DESC, m.date DESC, m.ROWID DESC"
        }

        sql += " LIMIT ?"
        params.append(limit)
        return (sql, params)
    }

    typealias AttachmentSummary = (
        id: Int64, type: AttachmentType, name: String?, available: Bool, sizeHuman: String?
    )

    func attachmentsForMessages(
        messageIds: [Int64],
        typeFilter: String?,
        allowedRoots: [String] = AttachmentPathPolicy.defaultRoots
    ) throws -> [Int64: [AttachmentSummary]] {
        guard !messageIds.isEmpty else { return [:] }

        let placeholders = messageIds.map { _ in "?" }.joined(separator: ", ")
        var sql = """
            SELECT maj.message_id, a.ROWID, a.filename, a.mime_type, a.uti, a.total_bytes
            FROM attachment a
            JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
            WHERE maj.message_id IN (\(placeholders))
            """
        if let predicate = AttachmentType.sqlPredicate(for: typeFilter, alias: "a") {
            sql += " AND (\(predicate))"
        }
        sql += " ORDER BY maj.message_id ASC, a.ROWID ASC"

        var byMessage: [Int64: [AttachmentSummary]] = [:]
        _ = try db.query(sql, params: messageIds.map { $0 as Any }) { row in
            let path = row.string(2)
            // Route through policy: paths outside allowed roots are treated as unavailable,
            // identical to a missing file. List output stays total (no error thrown).
            let validatedPath = path.flatMap { AttachmentPathPolicy.validatedPath($0, allowedRoots: allowedRoots) }
            let available = validatedPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
            let name = path.map { ($0 as NSString).lastPathComponent }
            let bytes = row.optionalInt(5).map { Int($0) }
            byMessage[row.int(0), default: []].append((
                id: row.int(1),
                type: AttachmentType.from(mimeType: row.string(3), uti: row.string(4)),
                name: name,
                available: available,
                sizeHuman: bytes.map { FormatUtils.fileSize($0) }
            ))
        }
        return byMessage
    }

    func resolveChatName(
        chatId: Int64,
        explicitName: String?,
        cache: inout [Int64: String]
    ) async throws -> String {
        let trimmed = explicitName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            cache[chatId] = trimmed
            return trimmed
        }

        if let cached = cache[chatId] {
            return cached
        }

        let rows = try await ChatSummaryQueries.participants(
            db: db,
            chatId: chatId,
            resolver: resolver
        )
        let names = rows.map {
            $0.name ?? PhoneUtils.formatDisplay($0.handle)
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        let generated = DisplayNameGenerator.fromNames(names)
        cache[chatId] = generated
        return generated
    }

}
