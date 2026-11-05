import Foundation

/// The identity, summary and last message every chat-listing tool shows,
/// fetched for a whole page of chats in a fixed number of queries.
enum ChatPage {
    struct Chat {
        let id: Int64
        var guid: String? = nil
        let explicitName: String?
        /// The chat's newest message date under the same filters as
        /// `LastMessageOptions`, when the caller's own query already has it.
        var newestDate: Int64? = nil
    }

    struct LastMessageOptions {
        var sinceApple: Int64? = nil
        var previewMaxLength = 50
        var unknownSenderLabel = "unknown"
        var agoFallback: String? = "unknown"
        var onlyUnreadInbound = false
    }

    struct Entry {
        let identity: ChatIdentity
        let summary: ChatSummary
        let lastMessage: ChatSummaryQueries.LastMessage?
    }

    /// Names and participants only, for tools that show no summary.
    static func identities(
        _ chats: [Chat],
        db: Database,
        resolver: ContactResolver
    ) async throws -> [Int64: ChatIdentity] {
        let participantsByChat = try await ChatSummaryQueries.participantsByChat(
            db: db, chatIds: chats.map(\.id), resolver: resolver
        )
        var identities: [Int64: ChatIdentity] = [:]
        for chat in chats {
            identities[chat.id] = ChatIdentity.from(
                chatId: chat.id,
                guid: chat.guid,
                explicitName: chat.explicitName,
                rows: participantsByChat[chat.id] ?? []
            )
        }
        return identities
    }

    /// Pass `lastMessages: nil` when the tool shows no last message.
    static func build(
        _ chats: [Chat],
        lastMessages: LastMessageOptions?,
        db: Database,
        resolver: ContactResolver
    ) async throws -> [Int64: Entry] {
        let chatIds = chats.map(\.id)
        let identities = try await identities(chats, db: db, resolver: resolver)

        var lastByChat: [Int64: ChatSummaryQueries.LastMessage] = [:]
        if let options = lastMessages {
            var newestDates: [Int64: Int64] = [:]
            for chat in chats {
                if let date = chat.newestDate { newestDates[chat.id] = date }
            }
            lastByChat = try await ChatSummaryQueries.lastMessagesByChat(
                db: db,
                chatIds: chatIds,
                resolver: resolver,
                sinceApple: options.sinceApple,
                previewMaxLength: options.previewMaxLength,
                unknownSenderLabel: options.unknownSenderLabel,
                agoFallback: options.agoFallback,
                onlyUnreadInbound: options.onlyUnreadInbound,
                newestDates: newestDates
            )
        }

        let recentSendersByChat = try ChatSummaryQueries.recentSendersByChat(
            db: db,
            chatIds: chatIds.filter { identities[$0].map(ChatSummaryBuilder.needsRecentSenders) ?? false }
        )

        var entries: [Int64: Entry] = [:]
        for (chatId, identity) in identities {
            entries[chatId] = Entry(
                identity: identity,
                summary: ChatSummaryBuilder.summary(
                    identity: identity,
                    recentSenders: recentSendersByChat[chatId] ?? []
                ),
                lastMessage: lastByChat[chatId]
            )
        }
        return entries
    }
}

/// A chat's summary fields and a tool's own fields, encoded as one JSON object.
@dynamicMemberLookup
struct ChatListing<Details: Encodable>: Encodable {
    let chat: ChatSummary
    let details: Details

    subscript<T>(dynamicMember field: KeyPath<ChatSummary, T>) -> T { chat[keyPath: field] }
    subscript<T>(dynamicMember field: KeyPath<Details, T>) -> T { details[keyPath: field] }

    func encode(to encoder: Encoder) throws {
        try chat.encode(to: encoder)
        try details.encode(to: encoder)
    }
}
