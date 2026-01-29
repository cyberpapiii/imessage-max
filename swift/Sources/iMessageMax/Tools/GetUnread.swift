// Sources/iMessageMax/Tools/GetUnread.swift
import Foundation

/// Response format for get_unread tool
enum UnreadFormat: String, CaseIterable {
    case messages
    case summary
}

/// Get unread messages or summary
final class GetUnread {
    private let database: Database
    private let contactResolver: ContactResolver

    init(database: Database = Database(), contactResolver: ContactResolver = ContactResolver()) {
        self.database = database
        self.contactResolver = contactResolver
    }

    /// Parameters for get_unread tool
    struct Parameters {
        var chatId: String?         // Filter to specific chat (e.g., "chat123")
        var since: String           // Time window (default "7d", accepts "all")
        var format: UnreadFormat    // "messages" or "summary"
        var limit: Int              // Max messages (default 50, max 100)
        var cursor: String?         // Pagination cursor

        init(
            chatId: String? = nil,
            since: String = "7d",
            format: UnreadFormat = .messages,
            limit: Int = 50,
            cursor: String? = nil
        ) {
            self.chatId = chatId
            self.since = since
            self.format = format
            self.limit = max(1, min(limit, 100))  // Clamp to 1-100
            self.cursor = cursor
        }
    }

    /// Execute get_unread with given parameters
    func execute(params: Parameters) async throws -> [String: Any] {
        // Initialize contact resolver
        try await contactResolver.initialize()

        // Parse since parameter - "all" means no time filter
        var sinceApple: Int64?
        if params.since.lowercased() != "all" {
            sinceApple = AppleTime.parse(params.since)
        }

        // Resolve chat_id to numeric ID if provided
        var numericChatId: Int64?
        if let chatId = params.chatId {
            numericChatId = try resolveChatId(chatId)
            if numericChatId == nil {
                return [
                    "error": "chat_not_found",
                    "message": "Chat not found: \(chatId)"
                ]
            }
        }

        switch params.format {
        case .summary:
            return try await getUnreadSummary(
                chatId: numericChatId,
                sinceApple: sinceApple
            )
        case .messages:
            return try await getUnreadMessages(
                chatId: numericChatId,
                sinceApple: sinceApple,
                limit: params.limit
            )
        }
    }

    // MARK: - Private Methods

    private func resolveChatId(_ chatId: String) throws -> Int64? {
        // Try parsing "chatXXX" format
        if chatId.hasPrefix("chat") {
            let numStr = String(chatId.dropFirst(4))
            if let num = Int64(numStr) {
                return num
            }
        }

        // Try to find by GUID
        let escapedChatId = QueryBuilder.escapeLike(chatId)
        let rows: [(Int64, String?)] = try database.query(
            "SELECT ROWID, guid FROM chat WHERE guid LIKE ? ESCAPE '\\'",
            params: ["%\(escapedChatId)%"]
        ) { row in
            (row.int(0), row.string(1))
        }

        return rows.first?.0
    }

    private func getUnreadMessages(
        chatId: Int64?,
        sinceApple: Int64?,
        limit: Int
    ) async throws -> [String: Any] {
        // Build query for unread messages
        // Unread = is_read = 0 AND is_from_me = 0
        var queryBuilder = QueryBuilder()
            .select(
                "m.ROWID as id",
                "m.guid",
                "m.text",
                "m.attributedBody",
                "m.date",
                "m.is_from_me",
                "m.handle_id",
                "h.id as sender_handle",
                "c.ROWID as chat_id",
                "c.display_name as chat_display_name",
                "c.guid as chat_guid"
            )
            .from("message m")
            .join("chat_message_join cmj ON m.ROWID = cmj.message_id")
            .join("chat c ON cmj.chat_id = c.ROWID")
            .leftJoin("handle h ON m.handle_id = h.ROWID")
            .where("m.is_read = 0")
            .where("m.is_from_me = 0")
            .where("m.associated_message_type = 0")

        // Apply time window filter (default 7 days to match Messages.app)
        if let sinceApple = sinceApple {
            queryBuilder = queryBuilder.where("m.date >= ?", sinceApple)
        }

        if let chatId = chatId {
            queryBuilder = queryBuilder.where("cmj.chat_id = ?", chatId)
        }

        queryBuilder = queryBuilder
            .orderBy("m.date ASC")
            .limit(limit)

        let (sql, params) = queryBuilder.build()

        // Fetch unread messages
        let rows: [UnreadMessageRow] = try database.query(sql, params: params) { row in
            UnreadMessageRow(
                id: row.int(0),
                guid: row.string(1),
                text: row.string(2),
                attributedBody: row.blob(3),
                date: row.optionalInt(4),
                isFromMe: row.int(5) == 1,
                handleId: row.optionalInt(6),
                senderHandle: row.string(7),
                chatId: row.int(8),
                chatDisplayName: row.string(9),
                chatGuid: row.string(10)
            )
        }

        // Get total count and chat count
        let (totalUnread, chatsWithUnread) = try getUnreadCounts(
            chatId: chatId,
            sinceApple: sinceApple
        )

        // Build people map and messages
        var people: [String: String] = [:]
        var handleToKey: [String: String] = [:]
        var unknownCount = 0

        // Cache for chat participants
        var chatParticipantsCache: [Int64: [ParticipantInfo]] = [:]

        var unreadMessages: [[String: Any]] = []

        for row in rows {
            let msgChatId = row.chatId
            let senderHandle = row.senderHandle

            // Build people map entry for sender
            if let handle = senderHandle, handleToKey[handle] == nil {
                let name = await contactResolver.resolve(handle)
                if let name = name {
                    var key = name.split(separator: " ").first.map(String.init)?.lowercased() ?? "p"
                    let baseKey = key
                    var suffix = 1
                    while people[key] != nil {
                        key = "\(baseKey)\(suffix)"
                        suffix += 1
                    }
                    people[key] = name
                    handleToKey[handle] = key
                } else {
                    unknownCount += 1
                    let key = "p\(unknownCount)"
                    people[key] = PhoneUtils.formatDisplay(handle)
                    handleToKey[handle] = key
                }
            }

            // Ensure participants are cached for this chat
            if chatParticipantsCache[msgChatId] == nil {
                chatParticipantsCache[msgChatId] = try await getChatParticipants(chatId: msgChatId)
            }

            // Get chat display name
            var chatDisplayName = row.chatDisplayName
            if chatDisplayName == nil || chatDisplayName?.isEmpty == true {
                // Generate from participants
                if let participants = chatParticipantsCache[msgChatId] {
                    chatDisplayName = generateDisplayName(participants: participants)
                }
            }

            // Determine if group chat
            let isGroup = (chatParticipantsCache[msgChatId]?.count ?? 0) > 1

            // Get message text
            let text = getMessageText(text: row.text, attributedBody: row.attributedBody)
            let msgDate = AppleTime.toDate(row.date)

            var msgItem: [String: Any] = [
                "message": [
                    "id": "msg_\(row.id)",
                    "ts": TimeUtils.formatISO(msgDate) ?? "",
                    "ago": TimeUtils.formatCompactRelative(msgDate) ?? "",
                    "text": text ?? ""
                ] as [String: Any],
                "chat": [
                    "id": "chat\(msgChatId)",
                    "name": chatDisplayName ?? ""
                ] as [String: Any]
            ]

            // Add sender
            if let handle = senderHandle, let key = handleToKey[handle] {
                if var message = msgItem["message"] as? [String: Any] {
                    message["from"] = key
                    msgItem["message"] = message
                }
            }

            // Add is_group flag only if True (token efficiency)
            if isGroup {
                if var chat = msgItem["chat"] as? [String: Any] {
                    chat["is_group"] = true
                    msgItem["chat"] = chat
                }
            }

            unreadMessages.append(msgItem)
        }

        return [
            "unread_messages": unreadMessages,
            "people": people,
            "total_unread": totalUnread,
            "chats_with_unread": chatsWithUnread,
            "more": unreadMessages.count < totalUnread,
            "cursor": NSNull()
        ]
    }

    private func getUnreadSummary(
        chatId: Int64?,
        sinceApple: Int64?
    ) async throws -> [String: Any] {
        // Build query for summary by chat
        var queryBuilder = QueryBuilder()
            .select(
                "cmj.chat_id",
                "c.display_name as chat_display_name",
                "COUNT(*) as unread_count",
                "MIN(m.date) as oldest_unread_date"
            )
            .from("message m")
            .join("chat_message_join cmj ON m.ROWID = cmj.message_id")
            .join("chat c ON cmj.chat_id = c.ROWID")
            .where("m.is_read = 0")
            .where("m.is_from_me = 0")
            .where("m.associated_message_type = 0")

        if let sinceApple = sinceApple {
            queryBuilder = queryBuilder.where("m.date >= ?", sinceApple)
        }

        if let chatId = chatId {
            queryBuilder = queryBuilder.where("cmj.chat_id = ?", chatId)
        }

        queryBuilder = queryBuilder
            .groupBy("cmj.chat_id")
            .orderBy("unread_count DESC")

        let (sql, params) = queryBuilder.build()

        let rows: [SummaryRow] = try database.query(sql, params: params) { row in
            SummaryRow(
                chatId: row.int(0),
                chatDisplayName: row.string(1),
                unreadCount: Int(row.int(2)),
                oldestUnreadDate: row.optionalInt(3)
            )
        }

        var totalUnread = 0
        var breakdown: [[String: Any]] = []

        for row in rows {
            let msgChatId = row.chatId
            let unreadCount = row.unreadCount
            totalUnread += unreadCount

            // Get chat display name
            var chatDisplayName = row.chatDisplayName
            if chatDisplayName == nil || chatDisplayName?.isEmpty == true {
                // Generate from participants
                let participants = try await getChatParticipants(chatId: msgChatId)
                chatDisplayName = generateDisplayName(participants: participants)
            }

            let oldestDt = AppleTime.toDate(row.oldestUnreadDate)

            breakdown.append([
                "chat_id": "chat\(msgChatId)",
                "chat_name": chatDisplayName ?? "",
                "unread_count": unreadCount,
                "oldest_unread": TimeUtils.formatCompactRelative(oldestDt) ?? ""
            ])
        }

        return [
            "summary": [
                "total_unread": totalUnread,
                "chats_with_unread": breakdown.count,
                "breakdown": breakdown
            ]
        ]
    }

    private func getUnreadCounts(
        chatId: Int64?,
        sinceApple: Int64?
    ) throws -> (totalUnread: Int, chatsWithUnread: Int) {
        var queryBuilder = QueryBuilder()
            .select(
                "COUNT(DISTINCT m.ROWID) as total_unread",
                "COUNT(DISTINCT cmj.chat_id) as chats_with_unread"
            )
            .from("message m")
            .join("chat_message_join cmj ON m.ROWID = cmj.message_id")
            .where("m.is_read = 0")
            .where("m.is_from_me = 0")
            .where("m.associated_message_type = 0")

        if let sinceApple = sinceApple {
            queryBuilder = queryBuilder.where("m.date >= ?", sinceApple)
        }

        if let chatId = chatId {
            queryBuilder = queryBuilder.where("cmj.chat_id = ?", chatId)
        }

        let (sql, params) = queryBuilder.build()

        let rows: [(Int, Int)] = try database.query(sql, params: params) { row in
            (Int(row.int(0)), Int(row.int(1)))
        }

        guard let first = rows.first else {
            return (0, 0)
        }

        return first
    }

    private func getChatParticipants(chatId: Int64) async throws -> [ParticipantInfo] {
        let rows: [(Int64, String, String?)] = try database.query("""
            SELECT h.ROWID, h.id as handle, h.service
            FROM chat_handle_join chj
            JOIN handle h ON chj.handle_id = h.ROWID
            WHERE chj.chat_id = ?
        """, params: [chatId]) { row in
            (row.int(0), row.string(1) ?? "", row.string(2))
        }

        var participants: [ParticipantInfo] = []
        for (_, handle, service) in rows {
            let name = await contactResolver.resolve(handle)
            participants.append(ParticipantInfo(
                handle: handle,
                name: name,
                service: service
            ))
        }

        return participants
    }

    private func generateDisplayName(participants: [ParticipantInfo], maxNames: Int = 3) -> String {
        if participants.isEmpty {
            return "(empty chat)"
        }

        var names: [String] = []
        for participant in participants.prefix(maxNames) {
            if let name = participant.name {
                // Use first name
                let firstName = name.split(separator: " ").first.map(String.init) ?? name
                names.append(firstName)
            } else {
                names.append(PhoneUtils.formatDisplay(participant.handle))
            }
        }

        if participants.count > maxNames {
            let remaining = participants.count - maxNames
            return "\(names.joined(separator: ", ")) and \(remaining) others"
        }

        if names.count == 2 {
            return "\(names[0]) & \(names[1])"
        }

        return names.joined(separator: ", ")
    }

    /// Extract text from message, handling attributedBody fallback
    private func getMessageText(text: String?, attributedBody: Data?) -> String? {
        var result: String?

        if let text = text, !text.isEmpty {
            result = text
        } else if let blob = attributedBody {
            result = extractTextFromAttributedBody(blob)
        }

        // Replace object replacement character with readable placeholder
        if var text = result, text.contains("\u{FFFC}") {
            text = text.replacingOccurrences(of: "\u{FFFC}", with: "[Photo]")
            result = text
        }

        return result
    }

    /// Extract plain text from attributedBody blob (typedstream format)
    private func extractTextFromAttributedBody(_ blob: Data) -> String? {
        // Look for NSString or NSMutableString marker
        guard let nsStringRange = blob.range(of: Data("NSString".utf8)) ??
              blob.range(of: Data("NSMutableString".utf8)) else {
            return nil
        }

        var idx = nsStringRange.upperBound + 5

        guard idx < blob.count else { return nil }

        let lengthByte = blob[idx]
        let length: Int
        let dataStart: Int

        if lengthByte == 0x81 {
            guard idx + 3 <= blob.count else { return nil }
            length = Int(blob[idx + 1]) | (Int(blob[idx + 2]) << 8)
            dataStart = idx + 3
        } else if lengthByte == 0x82 {
            guard idx + 4 <= blob.count else { return nil }
            length = Int(blob[idx + 1]) | (Int(blob[idx + 2]) << 8) | (Int(blob[idx + 3]) << 16)
            dataStart = idx + 4
        } else {
            length = Int(lengthByte)
            dataStart = idx + 1
        }

        guard length > 0 && dataStart + length <= blob.count else { return nil }

        let textData = blob[dataStart..<(dataStart + length)]
        return String(data: textData, encoding: .utf8)
    }
}

// MARK: - Helper Types

private struct UnreadMessageRow {
    let id: Int64
    let guid: String?
    let text: String?
    let attributedBody: Data?
    let date: Int64?
    let isFromMe: Bool
    let handleId: Int64?
    let senderHandle: String?
    let chatId: Int64
    let chatDisplayName: String?
    let chatGuid: String?
}

private struct SummaryRow {
    let chatId: Int64
    let chatDisplayName: String?
    let unreadCount: Int
    let oldestUnreadDate: Int64?
}

private struct ParticipantInfo {
    let handle: String
    let name: String?
    let service: String?
}
