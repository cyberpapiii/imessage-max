// Sources/iMessageMax/Tools/ListChats.swift
import Foundation
import MCP

/// Sort order for list_chats
enum ListChatsSort: String {
    case recent = "recent"
    case alphabetical = "alphabetical"
    case mostActive = "most_active"
}

/// Response structure for list_chats tool
struct ListChatsResponse: Codable {
    let chats: [ChatInfo]
    let totalChats: Int
    let totalGroups: Int
    let totalDms: Int
    let more: Bool
    let cursor: String?
    let people: PeopleMap?

    enum CodingKeys: String, CodingKey {
        case chats
        case totalChats = "total_chats"
        case totalGroups = "total_groups"
        case totalDms = "total_dms"
        case more
        case cursor
        case people
    }
}

/// Individual chat info in response
struct ChatInfo: Codable {
    let id: String
    let name: String
    let participants: [ListChatsParticipantInfo]
    let participantCount: Int
    let group: Bool?
    let last: LastMessageInfo?
    let awaitingReply: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case participants
        case participantCount = "participant_count"
        case group
        case last
        case awaitingReply = "awaiting_reply"
    }
}

/// Participant info with name and handle for ListChats response
struct ListChatsParticipantInfo: Codable {
    let name: String
    let handle: String
}

/// Last message preview
struct LastMessageInfo: Codable {
    let from: String
    let text: String
    let ago: String
}

/// Error response
struct ListChatsError: Error, Codable {
    let error: String
    let message: String
}

/// Implementation of the list_chats tool
enum ListChatsTool {
    // MARK: - Tool Registration

    static func register(on server: Server, db: Database, resolver: ContactResolver) {
        let inputSchema: Value = .object([
            "type": "object",
            "properties": .object([
                "limit": .object([
                    "type": "integer",
                    "description": "Max chats to return (default 20, max 100)",
                ]),
                "since": .object([
                    "type": "string",
                    "description": "Only chats with activity since this time (ISO, relative, or natural)",
                ]),
                "is_group": .object([
                    "type": "boolean",
                    "description": "True for groups only, False for DMs only",
                ]),
                "min_participants": .object([
                    "type": "integer",
                    "description": "Filter to chats with at least N participants",
                ]),
                "max_participants": .object([
                    "type": "integer",
                    "description": "Filter to chats with at most N participants",
                ]),
                "sort": .object([
                    "type": "string",
                    "description": "Sort order",
                    "enum": ["recent", "alphabetical", "most_active"],
                ]),
            ]),
            "additionalProperties": false,
        ])

        server.registerTool(
            name: "list_chats",
            description: "List recent chats with previews. Returns chat names, participants, last message, and metadata.",
            inputSchema: inputSchema,
            annotations: Tool.Annotations(
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let limit = arguments?["limit"]?.intValue ?? 20
            let since = arguments?["since"]?.stringValue
            let isGroup = arguments?["is_group"]?.boolValue
            let minParticipants = arguments?["min_participants"]?.intValue
            let maxParticipants = arguments?["max_participants"]?.intValue
            let sort = arguments?["sort"]?.stringValue ?? "recent"

            let result = await execute(
                limit: limit,
                since: since,
                isGroup: isGroup,
                minParticipants: minParticipants,
                maxParticipants: maxParticipants,
                sort: sort,
                cursor: nil,
                db: db,
                resolver: resolver
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

    /// List recent chats with previews
    /// - Parameters:
    ///   - limit: Max chats to return (default 20, clamped to 1-100)
    ///   - since: Only chats with activity since this time
    ///   - isGroup: True for groups only, False for DMs only
    ///   - minParticipants: Filter to chats with at least N participants
    ///   - maxParticipants: Filter to chats with at most N participants
    ///   - sort: "recent" (default), "alphabetical", or "most_active"
    ///   - cursor: Pagination cursor (unused, for future use)
    ///   - db: Database instance
    ///   - resolver: ContactResolver for name lookups
    static func execute(
        limit: Int = 20,
        since: String? = nil,
        isGroup: Bool? = nil,
        minParticipants: Int? = nil,
        maxParticipants: Int? = nil,
        sort: String = "recent",
        cursor: String? = nil,
        db: Database = Database(),
        resolver: ContactResolver
    ) async -> Result<ListChatsResponse, ListChatsError> {
        // Clamp limit to 1-100
        let clampedLimit = max(1, min(limit, 100))

        // Validate sort
        let sortOrder = ListChatsSort(rawValue: sort) ?? .recent

        // Initialize resolver
        do {
            try await resolver.initialize()
        } catch {
            // Continue without contacts - not a fatal error
        }

        do {
            // Build base query
            let qb = QueryBuilder()
            qb.select(
                "c.ROWID as id",
                "c.guid",
                "c.display_name",
                "c.service_name",
                "COUNT(DISTINCT chj.handle_id) as participant_count",
                "MAX(m.date) as last_message_date"
            )
            .from("chat c")
            .leftJoin("chat_handle_join chj ON c.ROWID = chj.chat_id")
            .leftJoin("chat_message_join cmj ON c.ROWID = cmj.chat_id")
            .leftJoin("message m ON cmj.message_id = m.ROWID AND m.associated_message_type = 0")

            // Time filter
            if let since = since, let sinceApple = AppleTime.parse(since) {
                qb.where("m.date >= ?", sinceApple)
            }

            qb.groupBy("c.ROWID")

            // Participant count filters (HAVING clause)
            if let minP = minParticipants {
                qb.having("participant_count >= ?", minP)
            }
            if let maxP = maxParticipants {
                qb.having("participant_count <= ?", maxP)
            }
            if let isGroup = isGroup {
                if isGroup {
                    qb.having("participant_count > 1")
                } else {
                    qb.having("participant_count <= 1")
                }
            }

            // Sort
            switch sortOrder {
            case .recent, .mostActive:
                qb.orderBy("last_message_date DESC NULLS LAST")
            case .alphabetical:
                qb.orderBy("COALESCE(c.display_name, '') ASC")
            }

            qb.limit(clampedLimit)

            let (sql, params) = qb.build()
            let chatRows = try db.query(sql, params: params) { row in
                ChatRow(
                    id: row.int(0),
                    guid: row.string(1),
                    displayName: row.string(2),
                    serviceName: row.string(3),
                    participantCount: Int(row.int(4)),
                    lastMessageDate: row.optionalInt(5)
                )
            }

            // Build results
            var chats: [ChatInfo] = []
            var allPeople: PeopleMap = [:]

            for chatRow in chatRows {
                // Get participants
                let participantRows = try await getParticipants(
                    db: db,
                    chatId: chatRow.id,
                    resolver: resolver
                )

                var participants: [ListChatsParticipantInfo] = []
                for p in participantRows {
                    let displayName = p.name ?? PhoneUtils.formatDisplay(p.handle)
                    participants.append(ListChatsParticipantInfo(
                        name: displayName,
                        handle: p.handle
                    ))

                    // Add to people map
                    let shortKey = makeShortKey(p.handle)
                    allPeople[shortKey] = Participant(
                        handle: p.handle,
                        name: p.name,
                        service: p.service,
                        inContacts: p.name != nil
                    )
                }

                // Generate display name
                let displayName = chatRow.displayName ?? generateDisplayName(participants)
                let isGroupChat = chatRow.participantCount > 1

                // Get last message
                let lastMsg = try await getLastMessage(
                    db: db,
                    chatId: chatRow.id,
                    resolver: resolver
                )

                let chatInfo = ChatInfo(
                    id: "chat\(chatRow.id)",
                    name: displayName,
                    participants: participants,
                    participantCount: chatRow.participantCount,
                    group: isGroupChat ? true : nil,
                    last: lastMsg?.info,
                    awaitingReply: lastMsg?.awaitingReply
                )

                chats.append(chatInfo)
            }

            // Get totals
            let totals = try getTotals(db: db)

            return .success(ListChatsResponse(
                chats: chats,
                totalChats: totals.total,
                totalGroups: totals.groups,
                totalDms: totals.dms,
                more: chats.count == clampedLimit,
                cursor: nil,
                people: allPeople.isEmpty ? nil : allPeople
            ))

        } catch let error as DatabaseError {
            switch error {
            case .notFound(let path):
                return .failure(ListChatsError(
                    error: "database_not_found",
                    message: "Database not found at \(path)"
                ))
            case .permissionDenied(let path):
                return .failure(ListChatsError(
                    error: "permission_denied",
                    message: "Permission denied accessing \(path)"
                ))
            case .queryFailed(let msg):
                return .failure(ListChatsError(
                    error: "query_failed",
                    message: msg
                ))
            case .invalidData(let msg):
                return .failure(ListChatsError(
                    error: "invalid_data",
                    message: msg
                ))
            }
        } catch {
            return .failure(ListChatsError(
                error: "internal_error",
                message: error.localizedDescription
            ))
        }
    }

    // MARK: - Private Helpers

    private struct ChatRow {
        let id: Int64
        let guid: String?
        let displayName: String?
        let serviceName: String?
        let participantCount: Int
        let lastMessageDate: Int64?
    }

    private struct ParticipantRow {
        let handle: String
        let name: String?
        let service: String?
    }

    private struct LastMessageResult {
        let info: LastMessageInfo
        let awaitingReply: Bool
    }

    /// Get participants for a chat
    private static func getParticipants(
        db: Database,
        chatId: Int64,
        resolver: ContactResolver
    ) async throws -> [ParticipantRow] {
        let sql = """
            SELECT h.id as handle, h.service
            FROM chat_handle_join chj
            JOIN handle h ON chj.handle_id = h.ROWID
            WHERE chj.chat_id = ?
            """

        let rows = try db.query(sql, params: [chatId]) { row in
            (handle: row.string(0) ?? "", service: row.string(1))
        }

        var participants: [ParticipantRow] = []
        for row in rows {
            let name = await resolver.resolve(row.handle)
            participants.append(ParticipantRow(
                handle: row.handle,
                name: name,
                service: row.service
            ))
        }

        return participants
    }

    /// Get last message for a chat
    private static func getLastMessage(
        db: Database,
        chatId: Int64,
        resolver: ContactResolver
    ) async throws -> LastMessageResult? {
        let sql = """
            SELECT m.text, m.attributedBody, m.is_from_me, h.id as sender_handle, m.date
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE cmj.chat_id = ?
            AND m.associated_message_type = 0
            ORDER BY m.date DESC
            LIMIT 1
            """

        let rows = try db.query(sql, params: [chatId]) { row in
            (
                text: row.string(0),
                attributedBody: row.blob(1),
                isFromMe: row.int(2) == 1,
                senderHandle: row.string(3),
                date: row.optionalInt(4)
            )
        }

        guard let last = rows.first else { return nil }

        // Determine sender
        let sender: String
        if last.isFromMe {
            sender = "me"
        } else if let handle = last.senderHandle {
            let resolvedName = await resolver.resolve(handle)
            sender = resolvedName ?? PhoneUtils.formatDisplay(handle)
        } else {
            sender = "unknown"
        }

        // Get message text (try attributedBody first, fall back to text)
        let msgText = extractMessageText(text: last.text, attributedBody: last.attributedBody) ?? ""

        // Format time
        let date = AppleTime.toDate(last.date)
        let ago = TimeUtils.formatCompactRelative(date) ?? "unknown"

        return LastMessageResult(
            info: LastMessageInfo(
                from: sender,
                text: String(msgText.prefix(50)),
                ago: ago
            ),
            awaitingReply: !last.isFromMe
        )
    }

    /// Get total counts
    private static func getTotals(db: Database) throws -> (total: Int, groups: Int, dms: Int) {
        let sql = """
            SELECT
                COUNT(*) as total,
                SUM(CASE WHEN cnt > 1 THEN 1 ELSE 0 END) as groups,
                SUM(CASE WHEN cnt <= 1 THEN 1 ELSE 0 END) as dms
            FROM (
                SELECT c.ROWID, COUNT(chj.handle_id) as cnt
                FROM chat c
                LEFT JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
                GROUP BY c.ROWID
            )
            """

        let rows = try db.query(sql, params: []) { row in
            (
                total: Int(row.int(0)),
                groups: Int(row.int(1)),
                dms: Int(row.int(2))
            )
        }

        return rows.first ?? (0, 0, 0)
    }

    /// Extract text from message, trying attributedBody first
    private static func extractMessageText(text: String?, attributedBody: Data?) -> String? {
        // Try attributedBody first (contains styled text)
        if let data = attributedBody,
           let extracted = extractFromAttributedBody(data) {
            return extracted
        }
        return text
    }

    /// Extract plain text from attributedBody blob (Apple typedstream format)
    private static func extractFromAttributedBody(_ data: Data) -> String? {
        // Look for NSString or NSMutableString marker in the typedstream
        guard let nsStringRange = data.range(of: Data("NSString".utf8)) ??
              data.range(of: Data("NSMutableString".utf8)) else {
            return nil
        }

        // Skip past the class name marker to the length field
        var idx = nsStringRange.upperBound + 5

        guard idx < data.count else { return nil }

        let lengthByte = data[idx]
        let length: Int
        let dataStart: Int

        // Parse length based on prefix byte
        if lengthByte == 0x81 {
            // 2-byte length (little endian)
            guard idx + 3 <= data.count else { return nil }
            length = Int(data[idx + 1]) | (Int(data[idx + 2]) << 8)
            dataStart = idx + 3
        } else if lengthByte == 0x82 {
            // 3-byte length (little endian)
            guard idx + 4 <= data.count else { return nil }
            length = Int(data[idx + 1]) | (Int(data[idx + 2]) << 8) | (Int(data[idx + 3]) << 16)
            dataStart = idx + 4
        } else {
            // Single byte length
            length = Int(lengthByte)
            dataStart = idx + 1
        }

        guard length > 0 && dataStart + length <= data.count else { return nil }

        let textData = data[dataStart..<(dataStart + length)]
        return String(data: textData, encoding: .utf8)
    }

    /// Generate display name from participants (like Messages.app)
    private static func generateDisplayName(_ participants: [ListChatsParticipantInfo]) -> String {
        if participants.isEmpty {
            return "Unknown"
        }

        let names = participants.map { $0.name }

        if names.count <= 4 {
            return names.joined(separator: ", ")
        }

        // More than 4: first 3 + "and N others"
        let first3 = names.prefix(3).joined(separator: ", ")
        let remaining = names.count - 3
        return "\(first3) and \(remaining) others"
    }

    /// Create a short key for the people map
    private static func makeShortKey(_ handle: String) -> String {
        // For emails, use local part
        if let atIndex = handle.firstIndex(of: "@") {
            return String(handle[..<atIndex]).lowercased()
        }

        // For phones, use last 4 digits
        let digits = handle.filter { $0.isNumber }
        if digits.count >= 4 {
            return String(digits.suffix(4))
        }

        return handle
    }
}
