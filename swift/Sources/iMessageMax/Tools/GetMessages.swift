// Sources/iMessageMax/Tools/GetMessages.swift
import Foundation
import MCP

// MARK: - Constants

private let defaultLimit = 50
private let maxLimit = 200
private let defaultUnansweredHours = 24
private let sessionGapHours = 4
private let sessionGapNanoseconds: Int64 = Int64(sessionGapHours) * 60 * 60 * 1_000_000_000
private let maxMedia = 10
private let maxLinks = 10

// MARK: - Response Types

struct GetMessagesResponse: Encodable {
    let chat: ChatInfo
    let people: [String: String]
    let messages: [MessageInfo]
    let sessions: [SessionInfo]
    let more: Bool
    let cursor: String?
    let mediaTruncated: Bool?
    let mediaTotal: Int?
    let mediaIncluded: Int?
    let suggestions: [String]?

    struct ChatInfo: Encodable {
        let id: String
        let name: String
    }

    struct MessageInfo: Encodable {
        let id: String
        let ts: String?
        let text: String?
        let from: String
        let reactions: [String]?
        let media: [MediaInfo]?
        let attachments: [AttachmentSummary]?
        let links: [String]?
        let sessionId: String?
        let sessionStart: Bool?
        let sessionGapHours: Double?

        private enum CodingKeys: String, CodingKey {
            case id, ts, text, from, reactions, media, attachments, links
            case sessionId = "session_id"
            case sessionStart = "session_start"
            case sessionGapHours = "session_gap_hours"
        }
    }

    struct MediaInfo: Encodable {
        let type: String
        let id: String
        let filename: String?
        let sizeBytes: Int?
        let sizeHuman: String?
        let dimensions: Dimensions?

        struct Dimensions: Encodable {
            let width: Int
            let height: Int
        }

        private enum CodingKeys: String, CodingKey {
            case type, id, filename, dimensions
            case sizeBytes = "size_bytes"
            case sizeHuman = "size_human"
        }
    }

    struct AttachmentSummary: Encodable {
        let type: String
        let filename: String?
        let size: Int?
    }

    struct SessionInfo: Encodable {
        let sessionId: String
        let started: String?
        let messageCount: Int

        private enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case started
            case messageCount = "message_count"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case chat, people, messages, sessions, more, cursor, suggestions
        case mediaTruncated = "media_truncated"
        case mediaTotal = "media_total"
        case mediaIncluded = "media_included"
    }
}

struct GetMessagesErrorResponse: Encodable {
    let error: String
    let message: String
    let candidates: [Candidate]?
    let suggestion: String?

    struct Candidate: Encodable {
        let chatId: String
        let name: String
        let participantCount: Int

        private enum CodingKeys: String, CodingKey {
            case chatId = "chat_id"
            case name
            case participantCount = "participant_count"
        }
    }
}

// MARK: - Tool Implementation

actor GetMessagesTool {
    private let db: Database
    private let resolver: ContactResolver

    init(db: Database, resolver: ContactResolver) {
        self.db = db
        self.resolver = resolver
    }

    // MARK: - Tool Registration

    static func register(on server: Server, db: Database, resolver: ContactResolver) {
        let tool = GetMessagesTool(db: db, resolver: resolver)

        server.registerTool(
            name: "get_messages",
            description: """
                Retrieve messages from a chat with flexible filtering. Either chat_id or participants must be provided.
                Returns messages with metadata (images return metadata only - use get_attachment for content).
                Messages are grouped into sessions (4+ hour gaps start new sessions).

                Examples:
                - get_messages(chat_id: "chat123") - get recent messages from chat
                - get_messages(participants: ["Nick"]) - find chat with Nick and get messages
                - get_messages(chat_id: "chat123", since: "24h") - messages from last 24 hours
                - get_messages(chat_id: "chat123", from_person: "me") - only my messages
                - get_messages(chat_id: "chat123", unanswered: true) - my questions without replies
                """,
            inputSchema: InputSchema.object(
                properties: [
                    "chat_id": .string(description: "Chat identifier (e.g., 'chat123')"),
                    "participants": .array(
                        description: "Find chat by participant names/handles (alternative to chat_id)",
                        items: .string(description: "Participant name or handle")
                    ),
                    "since": .string(description: "Time bound (ISO, relative like '24h', or 'yesterday')"),
                    "before": .string(description: "Upper time bound"),
                    "limit": .integer(description: "Maximum messages to return (default 50, max 200)"),
                    "from_person": .string(description: "Filter to messages from specific person (or 'me')"),
                    "contains": .string(description: "Text search within messages"),
                    "has": .string(
                        description: "Filter by content type",
                        enumValues: ["links", "attachments", "images"]
                    ),
                    "include_reactions": .boolean(description: "Include reaction data (default true)"),
                    "cursor": .string(description: "Pagination cursor for continuing retrieval"),
                    "unanswered": .boolean(description: "Only return my messages that didn't receive a reply"),
                    "unanswered_hours": .integer(description: "Window in hours to check for replies (default 24)"),
                    "session": .string(description: "Filter to specific session ID (e.g., 'session_1')")
                ]
            ),
            annotations: .init(
                title: "Get Messages",
                readOnlyHint: true,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { args in
            try await tool.execute(args: args)
        }
    }

    // MARK: - Execution

    func execute(args: [String: Value]?) async throws -> [Tool.Content] {
        do {
            let response = try await executeImpl(args: args)
            return [.text(try encodeJSON(response))]
        } catch let error as GetMessagesToolError {
            return [.text(try encodeJSON(error.errorResponse))]
        } catch {
            let errorResponse = GetMessagesErrorResponse(
                error: "internal_error",
                message: error.localizedDescription,
                candidates: nil,
                suggestion: nil
            )
            return [.text(try encodeJSON(errorResponse))]
        }
    }

    private func executeImpl(args: [String: Value]?) async throws -> GetMessagesResponse {
        let args = args ?? [:]

        // Parse arguments
        var chatId = args["chat_id"]?.stringValue
        let participants = args["participants"]?.arrayValue?.compactMap { $0.stringValue }
        let since = args["since"]?.stringValue
        let before = args["before"]?.stringValue
        let limit = min(args["limit"]?.intValue ?? defaultLimit, maxLimit)
        let fromPerson = args["from_person"]?.stringValue
        let contains = args["contains"]?.stringValue
        let has = args["has"]?.stringValue
        let includeReactions = args["include_reactions"]?.boolValue ?? true
        let cursor = args["cursor"]?.stringValue
        let unanswered = args["unanswered"]?.boolValue ?? false
        let unansweredHours = args["unanswered_hours"]?.intValue ?? defaultUnansweredHours
        let sessionFilter = args["session"]?.stringValue

        // Validate input
        guard chatId != nil || (participants != nil && !participants!.isEmpty) else {
            throw GetMessagesToolError(errorResponse: GetMessagesErrorResponse(
                error: "validation_error",
                message: "Either chat_id or participants must be provided",
                candidates: nil,
                suggestion: nil
            ))
        }

        // Initialize resolver
        try await resolver.initialize()

        // Resolve participants to chat_id if needed
        if chatId == nil, let participants = participants {
            chatId = try await resolveParticipantsToChat(participants: participants)
        }

        // Parse chat_id to numeric ID
        guard let numericChatId = parseChatId(chatId) else {
            throw GetMessagesToolError(errorResponse: GetMessagesErrorResponse(
                error: "chat_not_found",
                message: "Chat not found: \(chatId ?? "nil")",
                candidates: nil,
                suggestion: nil
            ))
        }

        // Get chat info
        let chatInfo = try getChatInfo(chatId: numericChatId)

        // Get participants and build people map
        let (people, handleToKey) = try await buildPeopleMap(chatId: numericChatId)

        // Parse time filters
        let sinceApple = since.flatMap { AppleTime.parse($0) }
        let beforeApple = before.flatMap { AppleTime.parse($0) }

        // Resolve from_person
        let (fromHandle, fromMeOnly) = await resolveFromPerson(
            fromPerson: fromPerson,
            unanswered: unanswered
        )

        // Build and execute query
        let fetchLimit = unanswered ? limit * 3 : limit
        var messageRows = try queryMessages(
            chatId: numericChatId,
            sinceApple: sinceApple,
            beforeApple: beforeApple,
            limit: fetchLimit,
            fromHandle: fromHandle,
            fromMeOnly: fromMeOnly,
            contains: contains,
            has: has
        )

        // Filter for unanswered if requested
        if unanswered {
            messageRows = try filterUnanswered(
                messageRows: messageRows,
                chatId: numericChatId,
                hours: unansweredHours,
                limit: limit
            )
        }

        // Get reactions
        let reactionsMap: [String: [(type: Int, fromHandle: String?)]]
        if includeReactions && !messageRows.isEmpty {
            reactionsMap = try getReactionsMap(messageGuids: messageRows.map { $0.guid })
        } else {
            reactionsMap = [:]
        }

        // Get attachments
        let attachmentsMap = try getAttachmentsMap(messageIds: messageRows.map { $0.id })

        // Build messages
        var messages: [GetMessagesResponse.MessageInfo] = []
        var mediaCount = 0

        for row in messageRows {
            let fromKey: String
            if row.isFromMe {
                fromKey = "me"
            } else if let handle = row.senderHandle {
                fromKey = handleToKey[handle] ?? handle
            } else {
                fromKey = "unknown"
            }

            // Build reactions
            var reactions: [String]? = nil
            if includeReactions, let rowReactions = reactionsMap[row.guid] {
                var reactionStrings: [String] = []
                for r in rowReactions {
                    guard let reactionType = ReactionType.fromType(r.type),
                          !ReactionType.isRemoval(r.type) else { continue }

                    let reactor: String
                    if let handle = r.fromHandle {
                        reactor = handleToKey[handle] ?? "unknown"
                    } else {
                        reactor = "me"
                    }
                    reactionStrings.append("\(reactionType.emoji) \(reactor)")
                }
                if !reactionStrings.isEmpty {
                    reactions = reactionStrings
                }
            }

            // Build media and attachments
            var media: [GetMessagesResponse.MediaInfo]? = nil
            var attachments: [GetMessagesResponse.AttachmentSummary]? = nil

            if let rowAttachments = attachmentsMap[row.id] {
                for att in rowAttachments {
                    let attType = getAttachmentType(mimeType: att.mimeType, uti: att.uti)

                    if attType == "image" && mediaCount < maxMedia {
                        // Get image metadata
                        if let path = att.filename {
                            let expandedPath = (path as NSString).expandingTildeInPath
                            let processor = ImageProcessor()
                            if let metadata = processor.getMetadata(at: expandedPath) {
                                if media == nil { media = [] }
                                media?.append(GetMessagesResponse.MediaInfo(
                                    type: "image",
                                    id: "att\(att.id)",
                                    filename: metadata.filename,
                                    sizeBytes: metadata.sizeBytes,
                                    sizeHuman: formatFileSize(metadata.sizeBytes),
                                    dimensions: .init(width: metadata.width, height: metadata.height)
                                ))
                                mediaCount += 1
                                continue
                            }
                        }
                    }

                    // Fall back to attachment summary
                    if attachments == nil { attachments = [] }
                    attachments?.append(GetMessagesResponse.AttachmentSummary(
                        type: attType,
                        filename: att.filename?.components(separatedBy: "/").last,
                        size: att.totalBytes
                    ))
                }
            }

            // Extract links from text
            var links: [String]? = nil
            if let text = row.text {
                let extractedLinks = extractLinks(from: text)
                if !extractedLinks.isEmpty {
                    links = Array(extractedLinks.prefix(maxLinks))
                }
            }

            messages.append(GetMessagesResponse.MessageInfo(
                id: "msg_\(row.id)",
                ts: row.date.flatMap { AppleTime.toDate($0) }.flatMap { TimeUtils.formatISO($0) },
                text: row.text,
                from: fromKey,
                reactions: reactions,
                media: media,
                attachments: attachments,
                links: links,
                sessionId: nil,
                sessionStart: nil,
                sessionGapHours: nil
            ))
        }

        // Assign sessions
        let (messagesWithSessions, sessions) = assignSessions(
            messages: messages,
            messageRows: messageRows
        )

        // Filter by session if requested
        var finalMessages = messagesWithSessions
        var finalSessions = sessions
        if let sessionFilter = sessionFilter {
            finalMessages = finalMessages.filter { $0.sessionId == sessionFilter }
            finalSessions = finalSessions.filter { $0.sessionId == sessionFilter }
        }

        // Build display name
        let displayName = chatInfo.displayName ?? generateDisplayName(people: people)

        // Build response
        let mediaTruncated = mediaCount > maxMedia

        return GetMessagesResponse(
            chat: .init(id: "chat\(numericChatId)", name: displayName),
            people: people,
            messages: finalMessages,
            sessions: finalSessions,
            more: messages.count == limit,
            cursor: cursor,
            mediaTruncated: mediaTruncated ? true : nil,
            mediaTotal: mediaTruncated ? mediaCount : nil,
            mediaIncluded: mediaTruncated ? maxMedia : nil,
            suggestions: messages.isEmpty ? ["Try different filters or time range"] : nil
        )
    }

    // MARK: - Helper Functions

    private func resolveParticipantsToChat(participants: [String]) async throws -> String {
        // Build handle groups for each participant
        var allHandles: Set<String> = []

        for p in participants {
            if p.hasPrefix("+") {
                allHandles.insert(p)
            } else if let normalized = PhoneUtils.normalizeToE164(p) {
                allHandles.insert(normalized)
            }

            // Also search by name
            let matches = await resolver.searchByName(p)
            for (handle, _) in matches {
                allHandles.insert(handle)
            }
        }

        guard !allHandles.isEmpty else {
            throw GetMessagesToolError(errorResponse: GetMessagesErrorResponse(
                error: "invalid_participants",
                message: "Could not resolve any handles for participants: \(participants)",
                candidates: nil,
                suggestion: nil
            ))
        }

        // Find chats containing these handles
        let placeholders = allHandles.map { _ in "?" }.joined(separator: ", ")
        let sql = """
            SELECT c.ROWID, c.display_name,
                   (SELECT COUNT(DISTINCT chj.handle_id) FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID) as participant_count
            FROM chat c
            JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
            JOIN handle h ON chj.handle_id = h.ROWID
            WHERE h.id IN (\(placeholders))
            GROUP BY c.ROWID
            ORDER BY (SELECT MAX(m.date) FROM message m JOIN chat_message_join cmj ON m.ROWID = cmj.message_id WHERE cmj.chat_id = c.ROWID) DESC
            LIMIT 10
            """

        let rows = try db.query(sql, params: Array(allHandles)) { row in
            (
                id: Int(row.int(0)),
                displayName: row.string(1),
                participantCount: Int(row.int(2))
            )
        }

        let targetCount = participants.count + 1  // +1 for me
        let exactMatches = rows.filter { $0.participantCount == targetCount }

        if exactMatches.count == 1 {
            return "chat\(exactMatches[0].id)"
        } else if !exactMatches.isEmpty {
            return "chat\(exactMatches[0].id)"
        } else if rows.count == 1 {
            return "chat\(rows[0].id)"
        } else if !rows.isEmpty {
            throw GetMessagesToolError(errorResponse: GetMessagesErrorResponse(
                error: "ambiguous_participants",
                message: "Multiple chats found with participants: \(participants)",
                candidates: rows.prefix(5).map { row in
                    GetMessagesErrorResponse.Candidate(
                        chatId: "chat\(row.id)",
                        name: row.displayName ?? "(Unnamed)",
                        participantCount: row.participantCount
                    )
                },
                suggestion: "Did you mean the \(rows[0].participantCount)-person chat or a different one?"
            ))
        } else {
            throw GetMessagesToolError(errorResponse: GetMessagesErrorResponse(
                error: "chat_not_found",
                message: "No chat found with participants: \(participants)",
                candidates: nil,
                suggestion: nil
            ))
        }
    }

    private func parseChatId(_ chatId: String?) -> Int? {
        guard let chatId = chatId else { return nil }

        // Try "chatXXX" format
        if chatId.hasPrefix("chat"), let numId = Int(chatId.dropFirst(4)) {
            return numId
        }

        // Try GUID lookup
        let rows = try? db.query(
            "SELECT ROWID FROM chat WHERE guid LIKE ?",
            params: ["%\(chatId)%"]
        ) { row in
            Int(row.int(0))
        }

        return rows?.first
    }

    private func getChatInfo(chatId: Int) throws -> (displayName: String?, serviceName: String?) {
        let rows = try db.query(
            "SELECT display_name, service_name FROM chat WHERE ROWID = ?",
            params: [chatId]
        ) { row in
            (displayName: row.string(0), serviceName: row.string(1))
        }

        guard let info = rows.first else {
            throw GetMessagesToolError(errorResponse: GetMessagesErrorResponse(
                error: "chat_not_found",
                message: "Chat not found: chat\(chatId)",
                candidates: nil,
                suggestion: nil
            ))
        }

        return info
    }

    private func buildPeopleMap(chatId: Int) async throws -> (people: [String: String], handleToKey: [String: String]) {
        let sql = """
            SELECT h.id, h.service
            FROM handle h
            JOIN chat_handle_join chj ON h.ROWID = chj.handle_id
            WHERE chj.chat_id = ?
            """

        let handles = try db.query(sql, params: [chatId]) { row in
            (handle: row.string(0) ?? "", service: row.string(1))
        }

        var people: [String: String] = ["me": "Me"]
        var handleToKey: [String: String] = [:]
        var unknownCount = 0

        for (i, h) in handles.enumerated() {
            let handle = h.handle
            let name = await resolver.resolve(handle)

            if let name = name {
                // Use first name as key
                var key = name.components(separatedBy: " ").first?.lowercased() ?? "person\(i)"
                // Handle duplicates
                if people[key] != nil {
                    key = "\(key)\(i)"
                }
                people[key] = name
                handleToKey[handle] = key
            } else {
                unknownCount += 1
                let key = "unknown\(unknownCount)"
                people[key] = PhoneUtils.formatDisplay(handle)
                handleToKey[handle] = key
            }
        }

        return (people, handleToKey)
    }

    private func resolveFromPerson(
        fromPerson: String?,
        unanswered: Bool
    ) async -> (fromHandle: String?, fromMeOnly: Bool) {
        if unanswered {
            return (nil, true)
        }

        guard let fromPerson = fromPerson else {
            return (nil, false)
        }

        if fromPerson.lowercased() == "me" {
            return (nil, true)
        }

        // Try to normalize as phone
        if let normalized = PhoneUtils.normalizeToE164(fromPerson) {
            return (normalized, false)
        }

        // Search by name
        let matches = await resolver.searchByName(fromPerson)
        if let first = matches.first {
            return (first.handle, false)
        }

        return (nil, false)
    }

    private func queryMessages(
        chatId: Int,
        sinceApple: Int64?,
        beforeApple: Int64?,
        limit: Int,
        fromHandle: String?,
        fromMeOnly: Bool,
        contains: String?,
        has: String?
    ) throws -> [MessageRow] {
        let query = QueryBuilder()
            .select(
                "m.ROWID as id",
                "m.guid",
                "m.text",
                "m.attributedBody",
                "m.date",
                "m.is_from_me",
                "h.id as sender_handle"
            )
            .from("message m")
            .join("chat_message_join cmj ON m.ROWID = cmj.message_id")
            .leftJoin("handle h ON m.handle_id = h.ROWID")
            .where("cmj.chat_id = ?", chatId)
            .where("m.associated_message_type = 0")  // Exclude reactions

        if let since = sinceApple {
            query.where("m.date >= ?", since)
        }

        if let before = beforeApple {
            query.where("m.date <= ?", before)
        }

        if fromMeOnly {
            query.where("m.is_from_me = 1")
        } else if let handle = fromHandle {
            query.where("h.id = ?", handle)
        }

        if let contains = contains {
            let escaped = QueryBuilder.escapeLike(contains)
            query.where("m.text LIKE ? ESCAPE '\\'", "%\(escaped)%")
        }

        if let has = has {
            switch has {
            case "links":
                query.where("(m.text LIKE '%http://%' OR m.text LIKE '%https://%')")
            case "attachments", "images":
                query.join("message_attachment_join maj ON m.ROWID = maj.message_id")
            default:
                break
            }
        }

        query.orderBy("m.date DESC")
            .limit(limit)

        let (sql, params) = query.build()

        return try db.query(sql, params: params) { row in
            MessageRow(
                id: Int(row.int(0)),
                guid: row.string(1) ?? "",
                text: getMessageText(text: row.string(2), attributedBody: row.blob(3)),
                date: row.optionalInt(4),
                isFromMe: row.int(5) == 1,
                senderHandle: row.string(6)
            )
        }
    }

    private func getMessageText(text: String?, attributedBody: Data?) -> String? {
        // Try plain text first
        if let text = text, !text.isEmpty {
            return text
        }

        // Try to extract from attributedBody (binary plist format)
        guard let data = attributedBody else { return nil }

        // attributedBody is a serialized NSAttributedString in binary plist format
        // The text content is stored under the "NSString" key
        do {
            if let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                // Direct NSString key
                if let nsString = plist["NSString"] as? String, !nsString.isEmpty {
                    return nsString
                }
                // Sometimes nested under NSAttributedString
                if let attrDict = plist["NSAttributedString"] as? [String: Any],
                   let nsString = attrDict["NSString"] as? String, !nsString.isEmpty {
                    return nsString
                }
            }
        } catch {
            // Fall through to regex extraction
        }

        // Fallback: Try to extract text using pattern matching on raw bytes
        // The text in attributedBody often appears after "NSString" marker
        if let str = String(data: data, encoding: .ascii) {
            // Look for readable text sequences (at least 3 consecutive printable chars)
            let pattern = "[\\x20-\\x7E]{3,}"
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(str.startIndex..., in: str)
                let matches = regex.matches(in: str, options: [], range: range)

                // Find the longest match that isn't just metadata keywords
                var bestMatch: String?
                var bestLength = 0
                let keywords = Set(["NSString", "NSAttributedString", "NSMutableAttributedString",
                                   "NSAttributes", "NSColor", "NSFont", "bplist"])

                for match in matches {
                    if let swiftRange = Range(match.range, in: str) {
                        let candidate = String(str[swiftRange])
                        if candidate.count > bestLength && !keywords.contains(candidate) {
                            bestMatch = candidate
                            bestLength = candidate.count
                        }
                    }
                }

                if let text = bestMatch, text.count >= 3 {
                    return text
                }
            }
        }

        return nil
    }

    private func filterUnanswered(
        messageRows: [MessageRow],
        chatId: Int,
        hours: Int,
        limit: Int
    ) throws -> [MessageRow] {
        var filtered: [MessageRow] = []

        for row in messageRows {
            guard let text = row.text, looksLikeQuestion(text) else { continue }
            guard let date = row.date else { continue }

            let hasReply = try hasReplyWithinWindow(chatId: chatId, messageDate: date, hours: hours)
            if !hasReply {
                filtered.append(row)
                if filtered.count >= limit {
                    break
                }
            }
        }

        return filtered
    }

    private func looksLikeQuestion(_ text: String) -> Bool {
        if text.contains("?") { return true }

        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        let questionEndings = [
            "what do you think",
            "let me know",
            "thoughts",
            "can you",
            "could you",
            "would you",
            "will you",
            "please",
            "lmk"
        ]

        for ending in questionEndings {
            if lower.hasSuffix(ending) { return true }
        }

        return false
    }

    private func hasReplyWithinWindow(chatId: Int, messageDate: Int64, hours: Int) throws -> Bool {
        let windowNs = Int64(hours) * 60 * 60 * 1_000_000_000

        let rows = try db.query("""
            SELECT 1 FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            WHERE cmj.chat_id = ?
            AND m.date > ?
            AND m.date <= ?
            AND m.is_from_me = 0
            AND m.associated_message_type = 0
            LIMIT 1
            """,
            params: [chatId, messageDate, messageDate + windowNs]
        ) { _ in true }

        return !rows.isEmpty
    }

    private func getReactionsMap(messageGuids: [String]) throws -> [String: [(type: Int, fromHandle: String?)]] {
        guard !messageGuids.isEmpty else { return [:] }

        let placeholders = messageGuids.map { _ in "?" }.joined(separator: ", ")
        let sql = """
            SELECT m.associated_message_guid, m.associated_message_type, h.id
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.associated_message_guid IN (\(placeholders))
            AND m.associated_message_type >= 2000
            """

        var map: [String: [(type: Int, fromHandle: String?)]] = [:]

        let rows = try db.query(sql, params: messageGuids) { row in
            (
                guid: row.string(0) ?? "",
                type: Int(row.int(1)),
                fromHandle: row.string(2)
            )
        }

        for row in rows {
            // Extract original message GUID from associated_message_guid
            let originalGuid = row.guid.hasPrefix("p:") || row.guid.hasPrefix("bp:")
                ? String(row.guid.split(separator: "/").last ?? "")
                : row.guid

            if map[originalGuid] == nil {
                map[originalGuid] = []
            }
            map[originalGuid]?.append((type: row.type, fromHandle: row.fromHandle))
        }

        return map
    }

    private func getAttachmentsMap(messageIds: [Int]) throws -> [Int: [AttachmentRow]] {
        guard !messageIds.isEmpty else { return [:] }

        let placeholders = messageIds.map { _ in "?" }.joined(separator: ", ")
        let sql = """
            SELECT maj.message_id, a.ROWID, a.filename, a.mime_type, a.uti, a.total_bytes
            FROM attachment a
            JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
            WHERE maj.message_id IN (\(placeholders))
            """

        var map: [Int: [AttachmentRow]] = [:]

        let rows = try db.query(sql, params: messageIds) { row in
            (
                messageId: Int(row.int(0)),
                attachment: AttachmentRow(
                    id: Int(row.int(1)),
                    filename: row.string(2),
                    mimeType: row.string(3),
                    uti: row.string(4),
                    totalBytes: row.optionalInt(5).map { Int($0) }
                )
            )
        }

        for row in rows {
            if map[row.messageId] == nil {
                map[row.messageId] = []
            }
            map[row.messageId]?.append(row.attachment)
        }

        return map
    }

    private func getAttachmentType(mimeType: String?, uti: String?) -> String {
        let mime = (mimeType ?? "").lowercased()
        let utiStr = (uti ?? "").lowercased()

        if mime.contains("image") || utiStr.contains("image") ||
           utiStr.contains("jpeg") || utiStr.contains("png") || utiStr.contains("heic") {
            return "image"
        } else if mime.contains("video") || utiStr.contains("movie") || utiStr.contains("video") {
            return "video"
        } else if mime.contains("audio") || utiStr.contains("audio") {
            return "audio"
        } else if mime.contains("pdf") || utiStr.contains("pdf") {
            return "pdf"
        }
        return "other"
    }

    private func extractLinks(from text: String) -> [String] {
        let pattern = #"https?://[^\s<>\"{}|\\^`\[\]]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)

        return matches.compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private func formatFileSize(_ bytes: Int) -> String {
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

    private func assignSessions(
        messages: [GetMessagesResponse.MessageInfo],
        messageRows: [MessageRow]
    ) -> ([GetMessagesResponse.MessageInfo], [GetMessagesResponse.SessionInfo]) {
        guard !messages.isEmpty else { return ([], []) }

        var updatedMessages = messages
        var sessions: [GetMessagesResponse.SessionInfo] = []
        var currentSession = 1
        var sessionMessageCount = 0
        var sessionStartTs: String? = nil

        // Messages are in DESC order (most recent first)
        // Reverse to process oldest first
        let reversedIndices = (0..<messages.count).reversed()

        for (i, idx) in reversedIndices.enumerated() {
            let row = messageRows[idx]
            let msgDate = row.date ?? 0

            var sessionStart = false
            var sessionGapHours: Double? = nil

            if i > 0 {
                let prevIdx = Array(reversedIndices)[i - 1]
                let prevDate = messageRows[prevIdx].date ?? 0
                let gap = msgDate - prevDate

                if gap >= sessionGapNanoseconds {
                    // Save previous session
                    sessions.append(GetMessagesResponse.SessionInfo(
                        sessionId: "session_\(currentSession)",
                        started: sessionStartTs,
                        messageCount: sessionMessageCount
                    ))
                    currentSession += 1
                    sessionMessageCount = 0
                    sessionStart = true
                    sessionGapHours = Double(gap) / Double(60 * 60 * 1_000_000_000)
                }
            } else {
                sessionStart = true
            }

            let sessionId = "session_\(currentSession)"
            sessionMessageCount += 1

            if sessionStart {
                sessionStartTs = row.date.flatMap { AppleTime.toDate($0) }.flatMap { TimeUtils.formatISO($0) }
            }

            // Update message with session info
            let msg = updatedMessages[idx]
            updatedMessages[idx] = GetMessagesResponse.MessageInfo(
                id: msg.id,
                ts: msg.ts,
                text: msg.text,
                from: msg.from,
                reactions: msg.reactions,
                media: msg.media,
                attachments: msg.attachments,
                links: msg.links,
                sessionId: sessionId,
                sessionStart: sessionStart ? true : nil,
                sessionGapHours: sessionGapHours
            )
        }

        // Save final session
        sessions.append(GetMessagesResponse.SessionInfo(
            sessionId: "session_\(currentSession)",
            started: sessionStartTs,
            messageCount: sessionMessageCount
        ))

        // Reverse sessions so most recent is first
        sessions.reverse()

        return (updatedMessages, sessions)
    }

    private func generateDisplayName(people: [String: String]) -> String {
        let names = people.filter { $0.key != "me" }.map { $0.value }

        if names.count <= 4 {
            return names.joined(separator: ", ")
        } else {
            let first3 = names.prefix(3).joined(separator: ", ")
            return "\(first3) and \(names.count - 3) others"
        }
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - Helper Types

private struct MessageRow {
    let id: Int
    let guid: String
    let text: String?
    let date: Int64?
    let isFromMe: Bool
    let senderHandle: String?
}

private struct AttachmentRow {
    let id: Int
    let filename: String?
    let mimeType: String?
    let uti: String?
    let totalBytes: Int?
}

private struct GetMessagesToolError: Error {
    let errorResponse: GetMessagesErrorResponse
}
