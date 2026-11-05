import Foundation
import MCP

struct GetMessagesSinceResponse: Encodable {
    struct Item: Encodable {
        let id: String
        let rowid: Int
        let chat: ChatReference
        let from: String
        let text: String?
        let ts: String
        let reactions: [String]?
        let attachments: [MessageAttachmentSummary]?
        let links: [String]?
        let replyTo: String?
        let replyCount: Int?
        let edited: Bool?
        let event: GroupEvent?

        private enum CodingKeys: String, CodingKey {
            case id, rowid, chat, from, text, ts, reactions, attachments, links, event, edited
            case replyTo = "reply_to"
            case replyCount = "reply_count"
        }
    }

    let sinceRowid: Int
    let messages: [Item]
    let nextRowid: Int
    let hasMore: Bool
    let currentRowid: Int
    let stalled: Bool
    let filteredHidden: Int

    private enum CodingKeys: String, CodingKey {
        case messages, stalled
        case sinceRowid = "since_rowid"
        case nextRowid = "next_rowid"
        case hasMore = "has_more"
        case currentRowid = "current_rowid"
        case filteredHidden = "filtered_hidden"
    }
}

actor GetMessagesSinceTool {
    static let unresolvedJoinGrace: TimeInterval = 30
    static let limit = IntArgument(name: "limit", defaultValue: 100, range: 1...500)

    private let db: Database
    private let resolver: ContactResolver

    init(db: Database, resolver: ContactResolver) {
        self.db = db
        self.resolver = resolver
    }

    static func definition(db: Database, resolver: ContactResolver) -> ToolDefinition {
        let tool = GetMessagesSinceTool(db: db, resolver: resolver)
        return ToolDefinition(
            name: "get_messages_since",
            description: """
                Messages across all chats with ROWID greater than since_rowid, in arrival order. \
                Pass the returned next_rowid back as since_rowid to page or poll. next_rowid may be \
                larger than the last returned message's rowid because consumed rows \
                (reactions, filtered chats, orphans) advance it. Omit since_rowid to get \
                only the current cursor. Cursors are only valid against this Mac's chat.db.
                """,
            inputSchema: InputSchema.object(
                properties: [
                    "since_rowid": .integer(description: "Exclusive ROWID cursor. Omit or pass -1 to return the current cursor only."),
                    "chat_id": .string(description: "Restrict to one chat (chat123 or 123)"),
                    "limit": .integer(description: "Maximum messages to return (\(limit.defaultAndMax))"),
                    "include_filtered": .boolean(description: "Include junk / unknown-sender chats (default false)"),
                    "include_reactions": .boolean(description: "Attach reaction strings to returned messages (default true)"),
                ]
            ),
            outputSchema: OutputSchema.object,
            annotations: .init(
                title: "Get Messages Since",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { args in
            try await tool.execute(args: args)
        }
    }

    func execute(args: [String: Value]?) async throws -> [Tool.Content] {
        let response = try await executeImpl(args: args ?? [:])
        return [.plainText(try FormatUtils.encodeJSON(response))]
    }

    private func executeImpl(args: [String: Value]) async throws -> GetMessagesSinceResponse {

        var chatFilter: Int64?
        if let rawChat = args["chat_id"]?.stringValue {
            guard let parsed = ChatIdentifier.parseRowId(rawChat) else {
                throw ToolFailure("invalid_input", "Invalid chat_id: \(rawChat)")
            }
            chatFilter = parsed
        }

        let currentRowid = Int(try db.query("SELECT COALESCE(MAX(ROWID), 0) FROM message") { $0.int(0) }.first ?? 0)
        let rawSince = args["since_rowid"]?.intValue
        if rawSince == nil || (rawSince ?? 0) < 0 {
            return GetMessagesSinceResponse(
                sinceRowid: currentRowid,
                messages: [],
                nextRowid: currentRowid,
                hasMore: false,
                currentRowid: currentRowid,
                stalled: false,
                filteredHidden: 0
            )
        }

        let sinceRowid = rawSince ?? currentRowid
        let limit = Self.limit.read(args)
        let includeFiltered = args["include_filtered"]?.boolValue ?? false
        let includeReactions = args["include_reactions"]?.boolValue ?? true
        let schema = try db.schema()

        // SQL LIMIT limit+1 starves the page when filtered/orphan rows are
        // consumed but not kept. Fetch batches until the walk fills `limit`
        // kept rows, stalls, or exhausts the closed range.
        var consumed = sinceRowid
        var kept: [SinceScanRow] = []
        var stalled = false
        // Chats, as filtered_hidden counts in every other tool.
        var hiddenChats: Set<Int64> = []
        var hasMore = false
        var exhausted = false
        var scanFrom = sinceRowid

        while kept.count < limit && !stalled && scanFrom < currentRowid {
            let batchLimit = max(limit - kept.count + 1, 32)
            let rows = try scanRows(
                schema: schema,
                sinceRowid: scanFrom,
                currentRowid: currentRowid,
                chatFilter: chatFilter,
                limit: batchLimit
            )
            if rows.isEmpty {
                exhausted = true
                break
            }

            for row in rows {
                if kept.count == limit {
                    hasMore = true
                    break
                }
                if row.chatId == nil {
                    let age: TimeInterval
                    if let date = AppleTime.toDate(row.message.date) {
                        age = Date().timeIntervalSince(date)
                    } else {
                        age = .infinity
                    }
                    if age < Self.unresolvedJoinGrace {
                        stalled = true
                        hasMore = true
                        break
                    }
                    consumed = Int(row.message.id)
                    continue
                }
                consumed = Int(row.message.id)
                if !includeFiltered && row.chatIsFiltered != 0 {
                    hiddenChats.insert(row.chatId ?? 0)
                    continue
                }
                kept.append(row)
            }
            if hasMore || stalled { break }
            scanFrom = Int(rows.last!.message.id)
            if rows.count < batchLimit {
                exhausted = true
                break
            }
        }
        // A page that filled on a batch's last row never looked past it.
        if kept.count == limit && !exhausted && consumed < currentRowid {
            hasMore = true
        }

        let nextRowid = hasMore ? consumed : currentRowid

        let messages = kept.map(\.message)
        let annotations = try MessageAnnotations.load(
            for: messages,
            include: includeReactions ? [.reactions, .replies, .attachments] : [.replies, .attachments],
            db: db
        )

        let chatByID = try await ChatReferences(
            ChatPage.Chat.distinct(kept, id: { $0.chatId ?? 0 }, explicitName: \.chatDisplayName),
            db: db,
            resolver: resolver
        )

        let renderer = MessageRenderer(
            annotations: annotations,
            labels: await SenderLabels.displayNames(
                me: "me", unknown: "unknown", for: messages, annotations: annotations, resolver: resolver
            ),
            eventNames: await MessageRenderer.eventNames(for: messages, resolver: resolver)
        )

        let items = kept.map { scanned in
            let message = renderer.render(scanned.message)
            return GetMessagesSinceResponse.Item(
                id: message.id,
                rowid: Int(message.rowid),
                chat: chatByID[scanned.chatId ?? 0],
                from: message.from,
                text: message.text,
                ts: message.ts ?? "",
                reactions: message.reactions,
                attachments: message.attachments,
                links: message.links,
                replyTo: message.replyTo,
                replyCount: message.replyCount,
                edited: message.edited,
                event: message.event
            )
        }

        return GetMessagesSinceResponse(
            sinceRowid: sinceRowid,
            messages: items,
            nextRowid: nextRowid,
            hasMore: hasMore,
            currentRowid: currentRowid,
            stalled: stalled,
            filteredHidden: hiddenChats.count
        )
    }

    private func scanRows(
        schema: SchemaCapabilities,
        sinceRowid: Int,
        currentRowid: Int,
        chatFilter: Int64?,
        limit: Int
    ) throws -> [SinceScanRow] {
        // A message in the filtered chat is listed under that chat.
        let chat = chatFilter.map(String.init) ?? SQLFragments.homeChat()
        let query = QueryBuilder()
            .selectMessages(
                schema,
                "\(chat) AS chat_id",
                "c.display_name AS chat_display_name",
                "c.is_filtered AS chat_is_filtered"
            )
            .from("message m")
            .joinMessageHandles()
            .leftJoin("chat c ON c.ROWID = \(chat)")
            .where("m.ROWID > ?", sinceRowid)
            .where("m.ROWID <= ?", currentRowid)
            .where(SQLFragments.notReaction())
        if let chatFilter {
            query.where(SQLFragments.messageInChat(), chatFilter)
        }
        query.orderBy("m.ROWID ASC").limit(limit)

        let (sql, params) = query.build()
        let extra = MessageRecord.columnCount
        return try db.query(sql, params: params) { row in
            SinceScanRow(
                message: MessageRecord(row),
                chatId: row.optionalInt(extra),
                chatDisplayName: row.string(extra + 1),
                chatIsFiltered: Int(row.int(extra + 2))
            )
        }
    }
}

private struct SinceScanRow {
    let message: MessageRecord
    let chatId: Int64?
    let chatDisplayName: String?
    let chatIsFiltered: Int
}
