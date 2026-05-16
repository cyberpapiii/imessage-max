// Sources/iMessageMax/Tools/GetMessages.swift
import Foundation
import MCP

// MARK: - Constants

private let defaultLimit = 50
private let maxLimit = 200
private let defaultUnansweredHours = 24
private let sessionGapHours = 4
let sessionGapNanoseconds: Int64 = Int64(sessionGapHours) * 60 * 60 * 1_000_000_000
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
    let db: Database
    let resolver: ContactResolver

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
                Messages are grouped into sessions (4+ hour gaps start new sessions). Best used after you already know which conversation you want to review more closely.
                Use chat.id/chat_id for follow-up tool calls only. When explaining results to the user, refer to chats by name using chat.name and participant names, not by the chat id.

                Examples:
                - get_messages(chat_id: "chat123") - get recent messages from chat
                - get_messages(chat_id: "chat123", since: "2d") - review one chat after a broad recent overview
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
            outputSchema: OutputSchema.object,
            annotations: .init(
                title: "Get Messages",
                readOnlyHint: true,
                destructiveHint: false,
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
            return [.plainText(try FormatUtils.encodeJSON(response))]
        } catch let error as GetMessagesToolError {
            throw ToolError(content: [.plainText(try FormatUtils.encodeJSON(error.errorResponse))])
        } catch {
            let errorResponse = GetMessagesErrorResponse(
                error: "internal_error",
                message: error.localizedDescription,
                candidates: nil,
                suggestion: nil
            )
            throw ToolError(content: [.plainText(try FormatUtils.encodeJSON(errorResponse))])
        }
    }

    private func executeImpl(args: [String: Value]?) async throws -> GetMessagesResponse {
        let args = args ?? [:]

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

        guard chatId != nil || (participants != nil && !participants!.isEmpty) else {
            throw GetMessagesToolError(errorResponse: GetMessagesErrorResponse(
                error: "validation_error",
                message: "Either chat_id or participants must be provided",
                candidates: nil,
                suggestion: nil
            ))
        }

        try await resolver.initialize()

        if chatId == nil, let participants = participants {
            chatId = try await resolveParticipantsToChat(participants: participants)
        }

        guard let numericChatId = parseChatId(chatId) else {
            throw GetMessagesToolError(errorResponse: GetMessagesErrorResponse(
                error: "chat_not_found",
                message: "Chat not found: \(chatId ?? "nil")",
                candidates: nil,
                suggestion: nil
            ))
        }

        let chatInfo = try getChatInfo(chatId: numericChatId)
        let (people, handleToKey) = try await buildPeopleMap(chatId: numericChatId)

        let sinceApple = since.flatMap { AppleTime.parse($0) }
        let beforeApple = before.flatMap { AppleTime.parse($0) }
        let (fromHandle, fromMeOnly) = await resolveFromPerson(
            fromPerson: fromPerson,
            unanswered: unanswered
        )

        let fetchLimit = unanswered ? limit * 3 : limit
        var messageRows = try queryMessages(
            chatId: numericChatId,
            sinceApple: sinceApple,
            beforeApple: beforeApple,
            cursor: cursor.flatMap(Self.decodeCursor),
            limit: fetchLimit,
            fromHandle: fromHandle,
            fromMeOnly: fromMeOnly,
            contains: contains,
            has: has
        )

        if unanswered {
            messageRows = try filterUnanswered(
                messageRows: messageRows,
                chatId: numericChatId,
                hours: unansweredHours,
                limit: limit
            )
        }

        let reactionsMap: [String: [(type: Int, fromHandle: String?)]]
        if includeReactions && !messageRows.isEmpty {
            reactionsMap = try getReactionsMap(messageGuids: messageRows.map { $0.guid })
        } else {
            reactionsMap = [:]
        }

        let attachmentsMap = try getAttachmentsMap(messageIds: messageRows.map { $0.id })

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

            var media: [GetMessagesResponse.MediaInfo]? = nil
            var attachments: [GetMessagesResponse.AttachmentSummary]? = nil

            if let rowAttachments = attachmentsMap[row.id] {
                for att in rowAttachments {
                    let attType = getAttachmentType(mimeType: att.mimeType, uti: att.uti)

                    if attType == "image" && mediaCount < maxMedia,
                       let path = att.filename {
                        let expandedPath = (path as NSString).expandingTildeInPath
                        let processor = ImageProcessor()
                        if let metadata = processor.getMetadata(at: expandedPath) {
                            if media == nil { media = [] }
                            media?.append(GetMessagesResponse.MediaInfo(
                                type: "image",
                                id: "att\(att.id)",
                                filename: metadata.filename,
                                sizeBytes: metadata.sizeBytes,
                                sizeHuman: FormatUtils.fileSize(metadata.sizeBytes),
                                dimensions: .init(width: metadata.width, height: metadata.height)
                            ))
                            mediaCount += 1
                            continue
                        }
                    }

                    if attachments == nil { attachments = [] }
                    attachments?.append(GetMessagesResponse.AttachmentSummary(
                        type: attType,
                        filename: att.filename?.components(separatedBy: "/").last,
                        size: att.totalBytes
                    ))
                }
            }

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

        let (messagesWithSessions, sessions) = assignSessions(
            messages: messages,
            messageRows: messageRows
        )

        var finalMessages = messagesWithSessions
        var finalSessions = sessions
        if let sessionFilter = sessionFilter {
            finalMessages = finalMessages.filter { $0.sessionId == sessionFilter }
            finalSessions = finalSessions.filter { $0.sessionId == sessionFilter }
        }

        let rawDisplayName = chatInfo.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (rawDisplayName?.isEmpty == false) ? rawDisplayName! : DisplayNameGenerator.fromNames(
            people.filter { $0.key != "me" }.map { $0.value }
        )

        let mediaTruncated = mediaCount > maxMedia

        return GetMessagesResponse(
            chat: .init(id: "chat\(numericChatId)", name: displayName),
            people: people,
            messages: finalMessages,
            sessions: finalSessions,
            more: messages.count == limit,
            cursor: Self.nextCursor(from: messageRows, limit: limit),
            mediaTruncated: mediaTruncated ? true : nil,
            mediaTotal: mediaTruncated ? mediaCount : nil,
            mediaIncluded: mediaTruncated ? maxMedia : nil,
            suggestions: messages.isEmpty ? ["Try different filters or time range"] : nil
        )
    }
}
