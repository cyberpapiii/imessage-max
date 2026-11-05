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
        limit: Int = ListAttachments.limit.defaultValue,
        sort: String = "recent_first",
        cursor: String? = nil
    ) async throws -> ListAttachmentsResponse {
        let effectiveLimit = Self.limit.clamp(limit)
        let effectiveSort = AttachmentSort(rawValue: sort) ?? .recentFirst

        let validTypes = Set(["image", "video", "audio", "pdf", "document", "any"])
        let typeFilter: String? = if let t = type, validTypes.contains(t) { t } else { nil }

        let numericChatId = try chatId.map { try ChatIdentifier.resolve($0, db: db) }

        let timelineCursor = cursor.flatMap(TimelineCursor.decode)
        let (sharedMessages, hasMore, nextCursor) = try await SharedMessages.page(
            db: db,
            resolver: resolver,
            chatId: numericChatId,
            sender: await SenderFilter.resolve(fromPerson, resolver: resolver),
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
}
