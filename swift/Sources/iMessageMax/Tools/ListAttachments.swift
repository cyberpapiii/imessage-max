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
            ]),
            "additionalProperties": false,
        ])

        server.registerTool(
            name: "list_attachments",
            description: "Browse shared items grouped by message. Returns chat ids for follow-up tool calls and chat names for user-facing summaries. When explaining results to the user, refer to chats by name, not by id. Good for discovering the message where photos, videos, audio, PDFs, or documents were sent before fetching a specific attachment.",
            inputSchema: inputSchema,
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

            let tool = ListAttachments(db: db, resolver: resolver)
            let result = await tool.execute(
                chatId: chatId,
                fromPerson: fromPerson,
                type: type,
                since: since,
                before: before,
                limit: limit,
                sort: sort
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
        sort: String = "recent_first"
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
                let cidStr = chatId.hasPrefix("chat") ? String(chatId.dropFirst(4)) : chatId
                guard let cid = Int64(cidStr) else {
                    return .failure(ListAttachmentsError(
                        error: "invalid_id",
                        message: "Invalid chat ID format: \(chatId)"
                    ))
                }
                numericChatId = cid
            } else {
                numericChatId = nil
            }

            let sharedMessages = try await browseSharedMessages(
                chatId: numericChatId,
                fromPerson: fromPerson,
                typeFilter: typeFilter,
                since: since,
                before: before,
                limit: effectiveLimit,
                sort: effectiveSort
            )

            return .success(ListAttachmentsResponse(
                messages: sharedMessages,
                total: sharedMessages.count,
                more: sharedMessages.count == effectiveLimit,
                cursor: nil
            ))

        } catch let error as DatabaseError {
            switch error {
            case .notFound(let path):
                return .failure(ListAttachmentsError(
                    error: "database_not_found",
                    message: "Database not found at \(path)"
                ))
            case .permissionDenied(let path):
                return .failure(ListAttachmentsError(
                    error: "permission_denied",
                    message: "Permission denied for \(path)"
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
                message: error.localizedDescription
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
        let maxAttachmentSize: Int
    }

    private struct AttachmentRow {
        let attId: Int64
        let filename: String?
        let mimeType: String?
        let uti: String?
        let totalBytes: Int?
    }

    func browseSharedMessages(
        chatId: Int64?,
        fromPerson: String?,
        typeFilter: String?,
        since: String?,
        before: String?,
        limit: Int,
        sort: AttachmentSort
    ) async throws -> [SharedMessageItem] {
        let (sql, params) = buildMessageQuery(
            chatId: chatId,
            fromPerson: fromPerson,
            typeFilter: typeFilter,
            since: since,
            before: before,
            limit: limit,
            sort: sort
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
                chatName: row.string(7),
                maxAttachmentSize: Int(row.int(8))
            )
        }

        var chatNameCache: [Int64: String] = [:]
        var results: [SharedMessageItem] = []

        for row in messageRows {
            let attachments = try attachmentsForMessage(messageId: row.msgId, typeFilter: typeFilter)
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

        return results
    }

    private func buildMessageQuery(
        chatId: Int64?,
        fromPerson: String?,
        typeFilter: String?,
        since: String?,
        before: String?,
        limit: Int,
        sort: AttachmentSort
    ) -> (String, [Any]) {
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
                MAX(COALESCE(a.total_bytes, 0)) as max_attachment_size
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            JOIN chat c ON cmj.chat_id = c.ROWID
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            JOIN message_attachment_join maj ON m.ROWID = maj.message_id
            JOIN attachment a ON maj.attachment_id = a.ROWID
            WHERE m.associated_message_type = 0
            """

        var params: [Any] = []

        if let chatId {
            sql += " AND c.ROWID = ?"
            params.append(chatId)
        }

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

        if let predicate = typePredicateSQL(typeFilter, attachmentAlias: "a") {
            sql += " AND (\(predicate))"
        }

        sql += " GROUP BY m.ROWID"

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

    func attachmentsForMessage(
        messageId: Int64,
        typeFilter: String?
    ) throws -> [(id: Int64, type: AttachmentType, name: String?, available: Bool, sizeHuman: String?)] {
        var sql = """
            SELECT a.ROWID, a.filename, a.mime_type, a.uti, a.total_bytes
            FROM attachment a
            JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
            WHERE maj.message_id = ?
            """
        if let predicate = typePredicateSQL(typeFilter, attachmentAlias: "a") {
            sql += " AND (\(predicate))"
        }
        sql += " ORDER BY a.ROWID ASC"

        return try db.query(sql, params: [messageId]) { row in
            let path = row.string(1)
            let expandedPath = path.map { ($0 as NSString).expandingTildeInPath }
            let available = expandedPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
            let name = path.map { ($0 as NSString).lastPathComponent }
            let bytes = row.optionalInt(4).map { Int($0) }
            return (
                id: row.int(0),
                type: AttachmentType.from(mimeType: row.string(2), uti: row.string(3)),
                name: name,
                available: available,
                sizeHuman: bytes.map { FormatUtils.fileSize($0) }
            )
        }
    }

    func typePredicateSQL(_ typeFilter: String?, attachmentAlias: String) -> String? {
        guard let typeFilter, typeFilter != "any" else { return nil }

        let mime = "LOWER(COALESCE(\(attachmentAlias).mime_type, ''))"
        let uti = "LOWER(COALESCE(\(attachmentAlias).uti, ''))"
        switch typeFilter {
        case "image":
            return "\(mime) LIKE '%image%' OR \(uti) LIKE '%image%' OR \(uti) LIKE '%jpeg%' OR \(uti) LIKE '%png%' OR \(uti) LIKE '%heic%'"
        case "video":
            return "\(mime) LIKE '%video%' OR \(uti) LIKE '%movie%' OR \(uti) LIKE '%video%'"
        case "audio":
            return "\(mime) LIKE '%audio%' OR \(uti) LIKE '%audio%'"
        case "pdf":
            return "\(mime) LIKE '%pdf%' OR \(uti) LIKE '%pdf%'"
        case "document":
            return "\(mime) LIKE '%document%' OR \(mime) LIKE '%msword%' OR \(mime) LIKE '%spreadsheet%' OR \(mime) LIKE '%presentation%'"
        default:
            return nil
        }
    }

    private func normalizedPreview(
        messageId: Int64,
        text: String?,
        attributedBody: Data?,
        attachmentType: AttachmentType
    ) async throws -> String? {
        if let formatted = SummaryPreviewFormatter.formattedTextPreview(
            text: text,
            attributedBody: attributedBody,
            maxLength: 50
        ) {
            return formatted
        }

        return SummaryPreviewFormatter.attachmentPlaceholder(for: [attachmentType])
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

        let sql = """
            SELECT h.id
            FROM handle h
            JOIN chat_handle_join chj ON h.ROWID = chj.handle_id
            WHERE chj.chat_id = ?
            """

        let handles = try db.query(sql, params: [chatId]) { row in
            row.string(0) ?? ""
        }

        let names = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for handle in handles {
                group.addTask { [resolver] in
                    await resolver.resolve(handle) ?? PhoneUtils.formatDisplay(handle)
                }
            }
            var resolved: [String] = []
            for await name in group {
                resolved.append(name)
            }
            return resolved.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }

        let generated = DisplayNameGenerator.fromNames(names)
        cache[chatId] = generated
        return generated
    }

}
