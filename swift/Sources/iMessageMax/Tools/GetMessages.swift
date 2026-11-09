import Foundation
import MCP

private let sessionGapHours = 4
let sessionGapNanoseconds: Int64 = Int64(sessionGapHours) * 60 * 60 * 1_000_000_000
private let maxMedia = 10

struct GetMessagesResponse: Encodable {
    let chat: ChatReference
    let people: [String: String]
    let messages: [MessageInfo]
    let sessions: [SessionInfo]
    let more: Bool
    let cursor: String?
    let mediaTruncated: Bool?
    let mediaTotal: Int?
    let mediaIncluded: Int?
    let suggestions: [String]?

    struct MessageInfo: Encodable {
        let id: String
        let ts: String?
        let text: String?
        let from: String
        let reactions: [String]?
        let media: [MediaInfo]?
        let attachments: [MessageAttachmentSummary]?
        let links: [String]?
        var sessionId: String?
        var sessionStart: Bool?
        var sessionGapHours: Double?
        let event: GroupEvent?
        let replyTo: String?
        let replyCount: Int?
        let edited: Bool?
        let unsent: Bool?

        init(_ message: RenderedMessage, media: [MediaInfo]?, attachments: [MessageAttachmentSummary]?) {
            id = message.id
            ts = message.ts
            text = message.text
            from = message.from
            reactions = message.reactions
            self.media = media
            self.attachments = attachments
            links = message.links
            event = message.event
            replyTo = message.replyTo
            replyCount = message.replyCount
            edited = message.edited
            unsent = message.unsent
        }

        private enum CodingKeys: String, CodingKey {
            case id, ts, text, from, reactions, media, attachments, links
            case sessionId = "session_id"
            case sessionStart = "session_start"
            case sessionGapHours = "session_gap_hours"
            case event
            case replyTo = "reply_to"
            case replyCount = "reply_count"
            case edited, unsent
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

struct GetMessagesErrorResponse: Encodable, Sendable {
    let error: String
    let message: String
    let candidates: [Candidate]?
    let suggestion: String?

    struct Candidate: Encodable, Sendable {
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

actor GetMessagesTool {
    static let limit = IntArgument(name: "limit", defaultValue: 50, range: 1...200)

    let db: Database
    let resolver: ContactResolver
    private let allowedRoots: [String]

    init(db: Database, resolver: ContactResolver, allowedRoots: [String] = AttachmentPathPolicy.defaultRoots) {
        self.db = db
        self.resolver = resolver
        self.allowedRoots = allowedRoots
    }

    static func definition(db: Database, resolver: ContactResolver) -> ToolDefinition {
        let tool = GetMessagesTool(db: db, resolver: resolver)

        return ToolDefinition(
            name: "get_messages",
            description: """
                Get messages from one chat, filtered by time, sender, content type, or text. Provide either chat_id or participants.
                Returns messages with metadata. Attachments return metadata only; use get_attachment for an image, or for the text of a PDF or document.
                The response groups messages into sessions, and a gap of 4 or more hours starts a new session. Use this tool after you know which conversation you want to read closely.
                Use chat.id or chat_id only in follow-up tool calls. When you explain results to the user, refer to chats by name, using chat.name and participant names, not the chat id.

                Examples:
                - get_messages(chat_id: "chat123"): recent messages from a chat
                - get_messages(chat_id: "chat123", since: "2d"): review one chat after a broad recent overview
                - get_messages(chat_id: "chat123", since: "24h"): messages from the last 24 hours
                - get_messages(chat_id: "chat123", from_person: "me"): only my messages
                - get_messages(chat_id: "chat123", unanswered: true): my questions without replies
                """,
            inputSchema: InputSchema.object(
                properties: [
                    "chat_id": .string(description: "Chat identifier (e.g., 'chat123')"),
                    "participants": .array(
                        description: "Participant names or handles that identify the chat (alternative to chat_id)",
                        items: .string(description: "Participant name or handle")
                    ),
                    "since": .string(description: "Lower time bound: \(AppleTime.boundFormats)"),
                    "before": .string(description: "Upper time bound, in the same forms as since"),
                    "limit": .integer(description: "Maximum messages to return (\(Self.limit.defaultAndMax))"),
                    "from_person": .string(description: "Only messages from this person (or 'me')"),
                    "contains": .string(description: "Text to search for within messages"),
                    "has": .string(
                        description: "Filter by content type",
                        enumValues: ["links", "attachments", "images"]
                    ),
                    "include_reactions": .boolean(description: "Include reaction data (default true)"),
                    "cursor": .string(description: "Pagination cursor from a previous get_messages response"),
                    "unanswered": .boolean(description: "Only return my messages that didn't receive a reply"),
                    "unanswered_hours": .integer(description: "Window in hours to check for replies (default \(IntArgument.unansweredHours.defaultValue))"),
                    "session": .string(description: "Only messages in this session ID (e.g., 'session_1')")
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

    func execute(args: [String: Value]?) async throws -> [Tool.Content] {
        let response = try await executeImpl(args: args)
        return [.plainText(try FormatUtils.encodeJSON(response))]
    }

    private func executeImpl(args: [String: Value]?) async throws -> GetMessagesResponse {
        let args = args ?? [:]

        let chatId = args["chat_id"]?.stringValue
        let participants = args["participants"]?.arrayValue?.compactMap { $0.stringValue }
        let since = try AppleTime.checkedBound(args["since"]?.stringValue, name: "since")
        let before = try AppleTime.checkedBound(args["before"]?.stringValue, name: "before")
        let limit = Self.limit.read(args)
        let fromPerson = args["from_person"]?.stringValue
        let contains = args["contains"]?.stringValue
        let has = args["has"]?.stringValue
        let includeReactions = args["include_reactions"]?.boolValue ?? true
        let cursor = args["cursor"]?.stringValue
        let unanswered = args["unanswered"]?.boolValue ?? false
        let unansweredHours = IntArgument.unansweredHours.read(args)
        let sessionFilter = args["session"]?.stringValue

        let chatRef: String
        if let chatId {
            chatRef = chatId
        } else if let participants, !participants.isEmpty {
            chatRef = try await resolveParticipantsToChat(participants: participants)
        } else {
            throw ToolFailure("validation_error", "Provide either chat_id or participants")
        }
        let chat = try ChatIdentifier.resolveChat(chatRef, db: db)
        let numericChatId = Int(chat.id)

        let chatParticipants = try await ChatSummaryQueries.participants(db: db, chatId: Int64(numericChatId), resolver: resolver)
        var people = PeopleMap(rules: .participants)
        people.addMe()
        for (position, participant) in chatParticipants.enumerated() {
            people.add(handle: participant.handle, name: participant.name, position: position)
        }

        let sinceApple = since.flatMap { AppleTime.parse($0) }
        let beforeApple = before.flatMap { AppleTime.parse($0) }
        let sender = unanswered ? .me : await SenderFilter.resolve(fromPerson, resolver: resolver)

        let fetchLimit = unanswered ? limit * 3 : limit
        var messageRows = try queryMessages(
            chatId: numericChatId,
            sinceApple: sinceApple,
            beforeApple: beforeApple,
            cursor: cursor.flatMap(TimelineCursor.decode),
            limit: fetchLimit,
            sender: sender,
            contains: contains,
            has: has
        )

        let fetchedRows = messageRows
        if let contains {
            messageRows = messageRows.filter { $0.text?.localizedCaseInsensitiveContains(contains) == true }
        }

        if unanswered {
            messageRows = try UnansweredHeuristics.filterUnanswered(
                db: db,
                rows: messageRows,
                hours: unansweredHours,
                limit: limit,
                text: \.text,
                date: \.date,
                chatId: { _ in Int64(numericChatId) }
            )
        }

        let annotations = try MessageAnnotations.load(
            for: messageRows,
            include: includeReactions ? [.reactions, .replies, .attachments] : [.replies, .attachments],
            db: db
        )
        let processor = ImageProcessor()
        let renderer = MessageRenderer(
            annotations: annotations,
            labels: people.labels(noHandle: "unknown"),
            eventNames: await MessageRenderer.eventNames(for: messageRows, resolver: resolver)
        )

        var messages: [GetMessagesResponse.MessageInfo] = []
        var mediaCountsByMessageId: [String: (total: Int, included: Int)] = [:]
        var mediaIncludedGlobal = 0

        for row in messageRows {
            let rendered = renderer.render(row)
            var media: [GetMessagesResponse.MediaInfo] = []
            var attachments: [MessageAttachmentSummary] = []
            var messageMediaTotal = 0

            for att in annotations.attachments[row.id] ?? [] {
                if AttachmentType.from(mimeType: att.mimeType, uti: att.uti) == .image,
                   let path = att.filename,
                   let validatedPath = AttachmentPathPolicy.validatedPath(path, allowedRoots: allowedRoots),
                   let metadata = processor.getMetadata(at: validatedPath) {
                    messageMediaTotal += 1
                    if mediaIncludedGlobal < maxMedia {
                        media.append(GetMessagesResponse.MediaInfo(
                            type: "image",
                            id: AttachmentIdentifier.format(att.id),
                            filename: metadata.filename,
                            sizeBytes: metadata.sizeBytes,
                            sizeHuman: FormatUtils.fileSize(metadata.sizeBytes),
                            dimensions: .init(width: metadata.width, height: metadata.height)
                        ))
                        mediaIncludedGlobal += 1
                        continue
                    }
                }
                attachments.append(MessageAttachmentSummary(att))
            }
            if messageMediaTotal > 0 {
                mediaCountsByMessageId[rendered.id] = (total: messageMediaTotal, included: media.count)
            }

            messages.append(GetMessagesResponse.MessageInfo(
                rendered,
                media: media.isEmpty ? nil : media,
                attachments: attachments.isEmpty ? nil : attachments
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

        var mediaTotal = 0
        var mediaIncluded = 0
        for message in finalMessages {
            mediaIncluded += message.media?.count ?? 0
            mediaTotal += mediaCountsByMessageId[message.id]?.total ?? 0
        }

        let identity = ChatIdentity.from(
            chatId: Int64(numericChatId),
            guid: nil,
            explicitName: chat.displayName,
            rows: chatParticipants
        )

        let mediaTruncated = mediaTotal > maxMedia
        let nextCursor = TimelineCursor.next(
            kept: messageRows, limit: limit, fetched: fetchedRows, fetchLimit: fetchLimit
        )

        return GetMessagesResponse(
            chat: ChatReference(id: identity.mcpId, name: identity.displayName),
            people: Dictionary(uniqueKeysWithValues: people.people.map { person in
                (person.key, person.name ?? person.handle.map(PhoneUtils.formatDisplay) ?? "")
            }),
            messages: finalMessages,
            sessions: finalSessions,
            more: nextCursor != nil,
            cursor: nextCursor,
            mediaTruncated: mediaTruncated ? true : nil,
            mediaTotal: mediaTruncated ? mediaTotal : nil,
            mediaIncluded: mediaTruncated ? mediaIncluded : nil,
            suggestions: messages.isEmpty ? ["Try different filters or a different time range"] : nil
        )
    }
}
