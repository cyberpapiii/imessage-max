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
        /// true when the row is late-synced history (see LateHistory); omitted otherwise.
        let late: Bool?

        private enum CodingKeys: String, CodingKey {
            case id, rowid, chat, from, text, ts, reactions, attachments, links, event, edited, late
            case replyTo = "reply_to"
            case replyCount = "reply_count"
        }
    }

    var sinceRowid: Int
    let messages: [Item]
    let nextRowid: Int
    let hasMore: Bool
    let currentRowid: Int
    let stalled: Bool
    let filteredHidden: Int
    /// Rows skipped by `max_age`; omitted when the call did not pass it.
    var skippedOld: Int? = nil

    private enum CodingKeys: String, CodingKey {
        case messages, stalled
        case sinceRowid = "since_rowid"
        case nextRowid = "next_rowid"
        case hasMore = "has_more"
        case currentRowid = "current_rowid"
        case filteredHidden = "filtered_hidden"
        case skippedOld = "skipped_old"
    }
}

actor GetMessagesSinceTool {
    static let unresolvedJoinGrace: TimeInterval = 30
    static let limit = IntArgument(name: "limit", defaultValue: 100, range: 1...500)
    static let maxAgeRange = 1...(3650 * 86_400)

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
                Get messages across all chats with a ROWID greater than since_rowid, in arrival order. \
                To page or poll, pass the returned next_rowid back as since_rowid. next_rowid can be \
                larger than the last returned message's rowid, because rows that are read but not \
                returned (reactions, filtered chats, orphans) still advance it. Omit since_rowid to \
                get only the current cursor. A cursor is valid only against this Mac's chat.db.                 A message with late: true is old history that synced into chat.db late, often from                 iCloud on a newly set-up Mac: its date is more than an hour older than messages that                 were already there. Do not treat it as new mail. Pass max_age to skip anything                 dated more than that many seconds ago.
                """,
            inputSchema: InputSchema.object(
                properties: [
                    "since_rowid": .integer(description: "Exclusive ROWID cursor. Omit or pass -1 to return the current cursor only."),
                    "chat_id": .string(description: "Restrict to one chat (chat123 or 123)"),
                    "limit": .integer(description: "Maximum messages to return (\(limit.defaultAndMax))"),
                    "include_filtered": .boolean(description: "Include chats Messages.app has filtered as junk or unknown senders (default false)"),
                    "include_reactions": .boolean(description: "Attach reaction strings to returned messages (default true)"),
                    "max_age": .integer(description: "Skip messages dated more than this many seconds before now. Skipped rows still advance next_rowid and are counted in skipped_old."),
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

    /// One read of the rows above a cursor. `wait_for_messages` reads with
    /// the sender filters and without late history; `get_messages_since`
    /// reads everything.
    struct Query {
        var sinceRowid: Int
        var scope: ChatScope
        var limit: Int
        var includeReactions = true
        var oldest: Int64? = nil
        var sender: SenderFilter? = nil
        var incomingOnly = false
        var keepLate = true
    }

    func currentRowid() throws -> Int {
        Int(try db.query("SELECT COALESCE(MAX(ROWID), 0) FROM message") { $0.int(0) }.first ?? 0)
    }

    private func executeImpl(args: [String: Value]) async throws -> GetMessagesSinceResponse {

        let chatFilter = try args["chat_id"]?.stringValue.map { try ChatIdentifier.resolve($0, db: db) }

        let rawSince = args["since_rowid"]?.intValue
        if rawSince == nil || (rawSince ?? 0) < 0 {
            let currentRowid = try currentRowid()
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

        let now = Date()
        return try await read(Query(
            sinceRowid: rawSince ?? 0,
            scope: ChatScope(named: chatFilter, includeFiltered: args["include_filtered"]?.boolValue ?? false),
            limit: Self.limit.read(args),
            includeReactions: args["include_reactions"]?.boolValue ?? true,
            oldest: args["max_age"]?.intValue.map { seconds in
                let clamped = min(max(seconds, Self.maxAgeRange.lowerBound), Self.maxAgeRange.upperBound)
                return AppleTime.fromDate(now.addingTimeInterval(-TimeInterval(clamped)))
            }
        ), now: now)
    }

    func read(_ request: Query, now: Date = Date()) async throws -> GetMessagesSinceResponse {
        let currentRowid = try currentRowid()
        let sinceRowid = request.sinceRowid
        let limit = request.limit
        let scope = request.scope
        let includeReactions = request.includeReactions
        let oldest = request.oldest
        let schema = try db.schema()
        var skippedOld = 0
        var lateness = LateHistory.Tracker(
            baseline: try LateHistory.baseline(db: db, atOrBelow: Int64(sinceRowid), now: now), now: now)
        var lateRows: Set<Int64> = []

        var consumed = sinceRowid
        var kept: [SinceScanRow] = []
        var stalled = false
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
                request: request,
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
                let late = lateness.observe(row.message.date)
                if scope.hidesChats && row.chatIsFiltered != 0 {
                    hiddenChats.insert(row.chatId ?? 0)
                    continue
                }
                if let oldest, (row.message.date ?? 0) < oldest {
                    skippedOld += 1
                    continue
                }
                if late {
                    guard request.keepLate else { continue }
                    lateRows.insert(row.message.id)
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
                event: message.event,
                late: lateRows.contains(scanned.message.id) ? true : nil
            )
        }

        return GetMessagesSinceResponse(
            sinceRowid: sinceRowid,
            messages: items,
            nextRowid: nextRowid,
            hasMore: hasMore,
            currentRowid: currentRowid,
            stalled: stalled,
            filteredHidden: scope.filteredHidden { hiddenChats.count } ?? 0,
            skippedOld: oldest == nil ? nil : skippedOld
        )
    }

    private func scanRows(
        schema: SchemaCapabilities,
        sinceRowid: Int,
        currentRowid: Int,
        request: Query,
        limit: Int
    ) throws -> [SinceScanRow] {
        let scope = request.scope
        let query = QueryBuilder()
            .selectMessages(
                schema,
                "\(scope.listedChat()) AS chat_id",
                "c.display_name AS chat_display_name",
                "c.is_filtered AS chat_is_filtered"
            )
        scope.read(query, screened: false)
        let rowid = scope.messageRowid
        query
            .joinMessageHandles()
            .where("\(rowid) > ?", sinceRowid)
            .where("\(rowid) <= ?", currentRowid)
            .where(SQLFragments.notReaction())
        if let sender = request.sender { query.where(sender) }
        if request.incomingOnly { query.where("m.is_from_me = 0") }
        query
            .orderBy("\(rowid) ASC")
            .limit(limit)

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
