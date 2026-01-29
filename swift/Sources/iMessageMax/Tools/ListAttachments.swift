// Sources/iMessageMax/Tools/ListAttachments.swift
import Foundation
import MCP

/// Attachment type derived from MIME type or UTI
enum AttachmentType: String, Codable {
    case image
    case video
    case audio
    case pdf
    case document
    case other

    static func from(mimeType: String?, uti: String?) -> AttachmentType {
        let mime = (mimeType ?? "").lowercased()
        let utiStr = (uti ?? "").lowercased()

        if mime.contains("image") || utiStr.contains("image") ||
            utiStr.contains("jpeg") || utiStr.contains("png") {
            return .image
        } else if mime.contains("video") || utiStr.contains("movie") || utiStr.contains("video") {
            return .video
        } else if mime.contains("audio") || utiStr.contains("audio") {
            return .audio
        } else if mime.contains("pdf") || utiStr.contains("pdf") {
            return .pdf
        } else if mime.contains("document") || mime.contains("msword") ||
            mime.contains("spreadsheet") || mime.contains("presentation") {
            return .document
        } else {
            return .other
        }
    }
}

/// Sort options for attachments
enum AttachmentSort: String {
    case recentFirst = "recent_first"
    case oldestFirst = "oldest_first"
    case largestFirst = "largest_first"
}

/// Attachment list item with full metadata
struct AttachmentListItem: Codable {
    let id: String
    let type: String
    let mime: String?
    let name: String?
    let size: Int?
    let sizeHuman: String?
    let ts: String?
    let ago: String?
    let from: String
    let chat: String
    let msgId: String
    let msgPreview: String?

    enum CodingKeys: String, CodingKey {
        case id, type, mime, name, size
        case sizeHuman = "size_human"
        case ts, ago, from, chat
        case msgId = "msg_id"
        case msgPreview = "msg_preview"
    }
}

/// Result from list_attachments tool
struct ListAttachmentsResult: Codable {
    let attachments: [AttachmentListItem]
    let people: [String: PersonInfo]
    let total: Int
    let more: Bool
    let cursor: String?

    struct PersonInfo: Codable {
        let name: String
        let handle: String?
        let isMe: Bool?

        enum CodingKeys: String, CodingKey {
            case name, handle
            case isMe = "is_me"
        }
    }
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
            description: "List attachments with filters by chat, sender, type, or time range. Returns metadata for images, videos, audio, PDFs, and documents.",
            inputSchema: inputSchema,
            annotations: Tool.Annotations(
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

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            switch result {
            case .success(let response):
                let json = try encoder.encode(response)
                return [.text(String(data: json, encoding: .utf8) ?? "{}")]
            case .failure(let error):
                let json = try encoder.encode(error)
                return [.text(String(data: json, encoding: .utf8) ?? "{}")]
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
    ) async -> Result<ListAttachmentsResult, ListAttachmentsError> {
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

        // Build query
        let query = QueryBuilder()
            .select(
                "a.ROWID as att_id",
                "a.filename",
                "a.mime_type",
                "a.uti",
                "a.total_bytes",
                "m.ROWID as msg_id",
                "m.text",
                "m.date",
                "m.is_from_me",
                "h.id as sender_handle",
                "c.ROWID as chat_id",
                "c.display_name as chat_name"
            )
            .from("attachment a")
            .join("message_attachment_join maj ON a.ROWID = maj.attachment_id")
            .join("message m ON maj.message_id = m.ROWID")
            .join("chat_message_join cmj ON m.ROWID = cmj.message_id")
            .join("chat c ON cmj.chat_id = c.ROWID")
            .leftJoin("handle h ON m.handle_id = h.ROWID")

        // Chat filter
        if let chatId = chatId {
            let cidStr = chatId.hasPrefix("chat") ? String(chatId.dropFirst(4)) : chatId
            guard let cid = Int(cidStr) else {
                return .failure(ListAttachmentsError(
                    error: "invalid_id",
                    message: "Invalid chat ID format: \(chatId)"
                ))
            }
            query.where("c.ROWID = ?", cid)
        }

        // From filter
        if let fromPerson = fromPerson {
            if fromPerson.lowercased() == "me" {
                query.where("m.is_from_me = 1")
            } else {
                let escaped = QueryBuilder.escapeLike(fromPerson)
                query.where("h.id LIKE ? ESCAPE '\\'", "%\(escaped)%")
            }
        }

        // Time filters
        if let since = since, let sinceTs = AppleTime.parse(since) {
            query.where("m.date >= ?", sinceTs)
        }

        if let before = before, let beforeTs = AppleTime.parse(before) {
            query.where("m.date <= ?", beforeTs)
        }

        // Sort order
        switch effectiveSort {
        case .recentFirst:
            query.orderBy("m.date DESC")
        case .oldestFirst:
            query.orderBy("m.date ASC")
        case .largestFirst:
            query.orderBy("a.total_bytes DESC")
        }

        // Fetch more than limit to allow for type filtering
        let fetchLimit = effectiveLimit * 3
        query.limit(fetchLimit)

        let (sql, params) = query.build()

        // Execute query
        do {
            let rows = try db.query(sql, params: params) { row -> AttachmentRow in
                AttachmentRow(
                    attId: row.int(0),
                    filename: row.string(1),
                    mimeType: row.string(2),
                    uti: row.string(3),
                    totalBytes: row.optionalInt(4).map { Int($0) },
                    msgId: row.int(5),
                    text: row.string(6),
                    date: row.optionalInt(7),
                    isFromMe: row.int(8) == 1,
                    senderHandle: row.string(9),
                    chatId: row.int(10),
                    chatName: row.string(11)
                )
            }

            // Build results with type filtering and people map
            var attachments: [AttachmentListItem] = []
            var people: [String: ListAttachmentsResult.PersonInfo] = [:]
            var handleToKey: [String: String] = [:]
            var unknownCounter = 0

            for row in rows {
                if attachments.count >= effectiveLimit {
                    break
                }

                let attType = AttachmentType.from(mimeType: row.mimeType, uti: row.uti)

                // Type filter
                if let typeFilter = typeFilter, typeFilter != "any" {
                    if attType.rawValue != typeFilter {
                        continue
                    }
                }

                // Get person key
                let senderKey: String
                if row.isFromMe {
                    senderKey = "me"
                    if people["me"] == nil {
                        people["me"] = ListAttachmentsResult.PersonInfo(
                            name: "Me",
                            handle: nil,
                            isMe: true
                        )
                    }
                } else {
                    let handle = row.senderHandle ?? "unknown"
                    if let existingKey = handleToKey[handle] {
                        senderKey = existingKey
                    } else {
                        let name = await resolver.resolve(handle)
                        let key = generatePersonKey(
                            name: name,
                            handle: handle,
                            existingPeople: people,
                            unknownCounter: &unknownCounter
                        )
                        handleToKey[handle] = key
                        people[key] = ListAttachmentsResult.PersonInfo(
                            name: name ?? handle,
                            handle: handle,
                            isMe: nil
                        )
                        senderKey = key
                    }
                }

                let msgDate = AppleTime.toDate(row.date)

                // Extract filename from path
                var filename = row.filename
                if let path = filename {
                    filename = (path as NSString).lastPathComponent
                }

                let attachment = AttachmentListItem(
                    id: "att\(row.attId)",
                    type: attType.rawValue,
                    mime: row.mimeType,
                    name: filename,
                    size: row.totalBytes,
                    sizeHuman: formatFileSize(row.totalBytes),
                    ts: TimeUtils.formatISO(msgDate),
                    ago: TimeUtils.formatCompactRelative(msgDate),
                    from: senderKey,
                    chat: "chat\(row.chatId)",
                    msgId: "msg\(row.msgId)",
                    msgPreview: row.text.map { String($0.prefix(50)) }
                )

                attachments.append(attachment)
            }

            return .success(ListAttachmentsResult(
                attachments: attachments,
                people: people,
                total: attachments.count,
                more: rows.count >= fetchLimit,
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

    private struct AttachmentRow {
        let attId: Int64
        let filename: String?
        let mimeType: String?
        let uti: String?
        let totalBytes: Int?
        let msgId: Int64
        let text: String?
        let date: Int64?
        let isFromMe: Bool
        let senderHandle: String?
        let chatId: Int64
        let chatName: String?
    }

    private func generatePersonKey(
        name: String?,
        handle: String,
        existingPeople: [String: ListAttachmentsResult.PersonInfo],
        unknownCounter: inout Int
    ) -> String {
        if let name = name {
            let firstName = name.split(separator: " ").first.map(String.init) ?? name
            var key = firstName.lowercased()

            // Handle collisions
            if existingPeople[key] != nil {
                let parts = name.split(separator: " ")
                if parts.count > 1 {
                    let lastInitial = String(parts.last!.prefix(1)).lowercased()
                    key = "\(firstName.lowercased())_\(lastInitial)"
                }
                if existingPeople[key] != nil {
                    var suffix = 2
                    while existingPeople["\(firstName.lowercased())\(suffix)"] != nil {
                        suffix += 1
                    }
                    key = "\(firstName.lowercased())\(suffix)"
                }
            }
            return key
        } else {
            unknownCounter += 1
            return "unknown\(unknownCounter)"
        }
    }

    private func formatFileSize(_ bytes: Int?) -> String? {
        guard let bytes = bytes, bytes > 0 else { return nil }

        var size = Double(bytes)
        for unit in ["B", "KB", "MB", "GB"] {
            if size < 1024 {
                if unit == "B" {
                    return "\(Int(size)) \(unit)"
                }
                return String(format: "%.1f %@", size, unit)
            }
            size /= 1024
        }
        return String(format: "%.1f TB", size)
    }
}
