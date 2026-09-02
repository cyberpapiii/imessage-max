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

    static func register(on server: Server, db: Database, resolver: ContactResolver) {
        let tool = GetMessagesSinceTool(db: db, resolver: resolver)
        server.registerTool(
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
        do {
            let response = try await executeImpl(args: args ?? [:])
            return [.plainText(try FormatUtils.encodeJSON(response))]
        } catch let error as ToolError {
            throw error
        } catch {
            throw ToolError(content: [.plainText(try FormatUtils.encodeJSON([
                "error": "internal_error",
                "message": ClientErrorMessages.sanitized(error),
            ]))])
        }
    }

    private func executeImpl(args: [String: Value]) async throws -> GetMessagesSinceResponse {
        try await resolver.initialize()

        var chatFilter: Int64?
        if let rawChat = args["chat_id"]?.stringValue {
            guard let parsed = ChatIdentifier.parseRowId(rawChat) else {
                throw ToolError(content: [.plainText(try FormatUtils.encodeJSON([
                    "error": "invalid_input",
                    "message": "Invalid chat_id: \(rawChat)",
                ]))])
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
                    if let date = AppleTime.toDate(row.date) {
                        age = Date().timeIntervalSince(date)
                    } else {
                        age = .infinity
                    }
                    if age < Self.unresolvedJoinGrace {
                        stalled = true
                        hasMore = true
                        break
                    }
                    consumed = row.id
                    continue
                }
                consumed = row.id
                if !includeFiltered && row.chatIsFiltered != 0 {
                    hidden += 1
                    continue
                }
                kept.append(row)
            }
            if hasMore || stalled { break }
            scanFrom = rows.last!.id
            if rows.count < batchLimit { break }
        }

        let nextRowid = hasMore ? consumed : currentRowid

        let reactionsMap: [String: [MessageAnnotations.Reaction]]
        if includeReactions && !kept.isEmpty {
            reactionsMap = try MessageAnnotations.reactionsMap(db: db, messageGuids: kept.map(\.guid))
        } else {
            reactionsMap = [:]
        }

        let pageIdByGuid = Dictionary(uniqueKeysWithValues: kept.map { ($0.guid, $0.id) })
        let replies = try MessageAnnotations.replyLookup(
            db: db,
            pageGuids: kept.map(\.guid),
            pageIdByGuid: pageIdByGuid,
            originatorGuids: kept.compactMap(\.threadOriginatorGuid)
        )
        let attachmentsMap = try MessageQueryHelpers.attachmentsMap(db: db, messageIds: kept.map(\.id))

        let chatIds = Array(Set(kept.compactMap { $0.chatId.map { Int64($0) } }))
        let participantsByChat = try await ChatSummaryQueries.participantsByChat(
            db: db, chatIds: chatIds, resolver: resolver
        )

        var otherHandleNames: [String: String] = [:]
        for handle in Set(kept.compactMap(\.otherHandle)) {
            otherHandleNames[handle] = await IdentityDisplayFormatter.displayName(
                handle: handle, resolver: resolver
            )
        }

        var items: [GetMessagesSinceResponse.Item] = []
        for row in kept {
            let chatId = row.chatId ?? 0
            let identity = ChatIdentity.from(
                chatId: Int64(chatId),
                guid: nil,
                explicitName: row.chatDisplayName,
                rows: participantsByChat[Int64(chatId)] ?? []
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
            if includeReactions, let rowReactions = reactionsMap[row.guid] {
                var reactorNames: [String: String] = [:]
                for reaction in rowReactions {
                    guard let handle = reaction.fromHandle, reactorNames[handle] == nil else { continue }
                    reactorNames[handle] = await IdentityDisplayFormatter.displayName(
                        handle: handle, resolver: resolver
                    )
                }
                reactions = MessageAnnotations.render(rowReactions) { handle in
                    guard let handle else { return "me" }
                    return reactorNames[handle] ?? handle
                }
            }

            var attachments: [GetMessagesResponse.AttachmentSummary]?
            if let rowAttachments = attachmentsMap[row.id] {
                attachments = rowAttachments.map {
                    GetMessagesResponse.AttachmentSummary(
                        id: "att\($0.id)",
                        type: AttachmentType.from(mimeType: $0.mimeType, uti: $0.uti).rawValue,
                        filename: $0.filename?.components(separatedBy: "/").last,
                        size: $0.totalBytes
                    )
                }
                if attachments?.isEmpty == true { attachments = nil }
            }

            var links: [String]?
            if let text = row.text {
                let extracted = MessageQueryHelpers.extractLinks(from: text)
                if !extracted.isEmpty { links = extracted }
            }

            let ts = row.date.flatMap { AppleTime.toDate($0) }.flatMap { TimeUtils.formatISO($0) } ?? ""

            items.append(GetMessagesSinceResponse.Item(
                id: "msg_\(row.id)",
                rowid: row.id,
                chat: ChatReference(id: identity.mcpId, name: identity.displayName),
                from: from,
                text: row.text,
                ts: ts,
                reactions: reactions,
                attachments: attachments,
                links: links,
                replyTo: row.threadOriginatorGuid.flatMap { replies.originatorIdByGuid[$0] },
                replyCount: replies.replyCountByGuid[row.guid],
                edited: row.dateEdited != 0 ? true : nil,
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
        var query = QueryBuilder()
            .select(
                "m.ROWID AS id",
                "m.guid",
                "m.text",
                "m.attributedBody",
                "m.date",
                "m.is_from_me",
                "h.id AS sender_handle",
                "m.item_type",
                "m.group_action_type",
                "m.group_title",
                "oh.id AS other_handle_id",
                schema.threadOriginatorGuidSQL,
                schema.dateEditedSQL,
                "(SELECT MIN(cmj.chat_id) FROM chat_message_join cmj WHERE cmj.message_id = m.ROWID) AS chat_id",
                "c.display_name AS chat_display_name",
                "c.is_filtered AS chat_is_filtered"
            )
            .from("message m")
            .leftJoin("handle h ON m.handle_id = h.ROWID")
            .leftJoin("handle oh ON m.other_handle = oh.ROWID")
            .leftJoin("chat c ON c.ROWID = (SELECT MIN(cmj2.chat_id) FROM chat_message_join cmj2 WHERE cmj2.message_id = m.ROWID)")
            .where("m.ROWID > ?", sinceRowid)
            .where("m.ROWID <= ?", currentRowid)
            .where("m.associated_message_type = 0")
        if let chatFilter {
            query.where(
                "(SELECT MIN(cmj3.chat_id) FROM chat_message_join cmj3 WHERE cmj3.message_id = m.ROWID) = ?",
                chatFilter
            )
        }
        query.orderBy("m.ROWID ASC").limit(limit)

        let (sql, params) = query.build()
        return try db.query(sql, params: params) { row in
            SinceScanRow(
                id: Int(row.int(0)),
                guid: row.string(1) ?? "",
                text: MessageTextExtractor.extract(text: row.string(2), attributedBody: row.blob(3)),
                date: row.optionalInt(4),
                isFromMe: row.int(5) == 1,
                senderHandle: row.string(6),
                itemType: Int(row.int(7)),
                groupActionType: Int(row.int(8)),
                groupTitle: row.string(9),
                otherHandle: row.string(10),
                threadOriginatorGuid: row.string(11),
                dateEdited: row.optionalInt(12) ?? 0,
                chatId: row.optionalInt(13).map { Int($0) },
                chatDisplayName: row.string(14),
                chatIsFiltered: Int(row.int(15))
            )
        }
    }
}

private struct SinceScanRow {
    let id: Int
    let guid: String
    let text: String?
    let date: Int64?
    let isFromMe: Bool
    let senderHandle: String?
    let itemType: Int
    let groupActionType: Int
    let groupTitle: String?
    let otherHandle: String?
    let threadOriginatorGuid: String?
    let dateEdited: Int64
    let chatId: Int?
    let chatDisplayName: String?
    let chatIsFiltered: Int
}
