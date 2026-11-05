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
        let attachments: [GetMessagesResponse.AttachmentSummary]?
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
    static let defaultLimit = 100
    static let maxLimit = 500

    private let db: Database
    private let resolver: ContactResolver

    init(db: Database, resolver: ContactResolver) {
        self.db = db
        self.resolver = resolver
    }

    static func clampLimit(_ raw: Int?) -> Int {
        max(1, min(raw ?? defaultLimit, maxLimit))
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
                    "limit": .integer(description: "Maximum messages to return (default 100, max 500)"),
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
        let limit = Self.clampLimit(args["limit"]?.intValue)
        let includeFiltered = args["include_filtered"]?.boolValue ?? false
        let includeReactions = args["include_reactions"]?.boolValue ?? true
        let schema = try db.schema()

        // SQL LIMIT limit+1 starves the page when filtered/orphan rows are
        // consumed but not kept. Fetch batches until the walk fills `limit`
        // kept rows, stalls, or exhausts the closed range.
        var consumed = sinceRowid
        var kept: [SinceScanRow] = []
        var stalled = false
        var hidden = 0
        var hasMore = false
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
            if rows.isEmpty { break }

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
                    hidden += 1
                    continue
                }
                kept.append(row)
            }
            if hasMore || stalled { break }
            scanFrom = Int(rows.last!.message.id)
            if rows.count < batchLimit { break }
        }

        let nextRowid = hasMore ? consumed : currentRowid

        let messages = kept.map(\.message)
        let annotations = try MessageAnnotations.load(
            for: messages,
            include: includeReactions ? [.reactions, .replies, .attachments] : [.replies, .attachments],
            db: db
        )

        let chatIds = Array(Set(kept.compactMap(\.chatId)))
        let participantsByChat = try await ChatSummaryQueries.participantsByChat(
            db: db, chatIds: chatIds, resolver: resolver
        )

        var otherHandleNames: [String: String] = [:]
        for handle in Set(messages.compactMap(\.otherHandle)) {
            otherHandleNames[handle] = await IdentityDisplayFormatter.displayName(
                handle: handle, resolver: resolver
            )
        }

        var items: [GetMessagesSinceResponse.Item] = []
        for scanned in kept {
            let row = scanned.message
            let chatId = scanned.chatId ?? 0
            let identity = ChatIdentity.from(
                chatId: chatId,
                guid: nil,
                explicitName: scanned.chatDisplayName,
                rows: participantsByChat[chatId] ?? []
            )

            let from: String
            if row.isFromMe {
                from = "me"
            } else if let handle = row.senderHandle {
                from = await IdentityDisplayFormatter.displayName(handle: handle, resolver: resolver)
            } else {
                from = "unknown"
            }

            var reactions: [String]?
            if let rowReactions = annotations.reactions[row.guid] {
                var reactorNames: [String: String] = [:]
                for reaction in rowReactions {
                    guard let handle = reaction.fromHandle, reactorNames[handle] == nil else { continue }
                    reactorNames[handle] = await IdentityDisplayFormatter.displayName(
                        handle: handle, resolver: resolver
                    )
                }
                reactions = MessageRenderer.reactions(rowReactions) { handle in
                    guard let handle else { return "me" }
                    return reactorNames[handle] ?? handle
                }
            }

            var attachments: [GetMessagesResponse.AttachmentSummary]?
            if let rowAttachments = annotations.attachments[row.id] {
                attachments = rowAttachments.map {
                    GetMessagesResponse.AttachmentSummary(
                        id: AttachmentIdentifier.format($0.id),
                        type: AttachmentType.from(mimeType: $0.mimeType, uti: $0.uti).rawValue,
                        filename: $0.filename?.components(separatedBy: "/").last,
                        size: $0.totalBytes
                    )
                }
                if attachments?.isEmpty == true { attachments = nil }
            }

            var links: [String]?
            if let text = row.text {
                let extracted = MessageRenderer.links(in: text)
                if !extracted.isEmpty { links = extracted }
            }

            let ts = row.date.flatMap { AppleTime.toDate($0) }.flatMap { TimeUtils.formatISO($0) } ?? ""

            items.append(GetMessagesSinceResponse.Item(
                id: MessageIdentifier.format(row.id),
                rowid: Int(row.id),
                chat: ChatReference(id: identity.mcpId, name: identity.displayName),
                from: from,
                text: row.text,
                ts: ts,
                reactions: reactions,
                attachments: attachments,
                links: links,
                replyTo: annotations.replyTo(row),
                replyCount: annotations.replyCount(row),
                edited: row.isEdited ? true : nil,
                event: GroupEvent.classify(
                    itemType: row.itemType,
                    groupActionType: row.groupActionType,
                    groupTitle: row.groupTitle,
                    otherHandleName: row.otherHandle.flatMap { otherHandleNames[$0] }
                )
            ))
        }

        return GetMessagesSinceResponse(
            sinceRowid: sinceRowid,
            messages: items,
            nextRowid: nextRowid,
            hasMore: hasMore,
            currentRowid: currentRowid,
            stalled: stalled,
            filteredHidden: hidden
        )
    }

    private func scanRows(
        schema: SchemaCapabilities,
        sinceRowid: Int,
        currentRowid: Int,
        chatFilter: Int64?,
        limit: Int
    ) throws -> [SinceScanRow] {
        let query = QueryBuilder()
            .selectMessages(
                schema,
                "(SELECT MIN(cmj.chat_id) FROM chat_message_join cmj WHERE cmj.message_id = m.ROWID) AS chat_id",
                "c.display_name AS chat_display_name",
                "c.is_filtered AS chat_is_filtered"
            )
            .from("message m")
            .joinMessageHandles()
            .leftJoin("chat c ON c.ROWID = (SELECT MIN(cmj2.chat_id) FROM chat_message_join cmj2 WHERE cmj2.message_id = m.ROWID)")
            .where("m.ROWID > ?", sinceRowid)
            .where("m.ROWID <= ?", currentRowid)
            .where(SQLFragments.notReaction())
        if let chatFilter {
            query.where(
                "(SELECT MIN(cmj3.chat_id) FROM chat_message_join cmj3 WHERE cmj3.message_id = m.ROWID) = ?",
                chatFilter
            )
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
