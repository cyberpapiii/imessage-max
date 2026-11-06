import Foundation

extension ChatPage.Chat {
    /// Each chat in `rows` once, in first-appearance order, named as its first row names it.
    static func distinct<Row>(
        _ rows: [Row],
        id: (Row) -> Int64,
        explicitName: (Row) -> String?
    ) -> [ChatPage.Chat] {
        var seen: Set<Int64> = []
        return rows.compactMap { row in
            seen.insert(id(row)).inserted ? ChatPage.Chat(id: id(row), explicitName: explicitName(row)) : nil
        }
    }
}

extension Array where Element == MessageInChat {
    var chats: [ChatPage.Chat] {
        ChatPage.Chat.distinct(self, id: \.chatId, explicitName: \.chatName)
    }
}

/// The `{id, name}` each message-level result shows for its chat.
struct ChatReferences {
    private let byId: [Int64: ChatReference]

    subscript(chatId: Int64) -> ChatReference {
        byId[chatId] ?? ChatReference(id: ChatIdentifier.format(chatId), name: DisplayNameGenerator.fromNames([]))
    }

    /// Names a whole page of chats in one participants query.
    init(_ chats: [ChatPage.Chat], db: Database, resolver: ContactResolver) async throws {
        let identities = try await ChatPage.identities(chats, db: db, resolver: resolver)
        byId = identities.mapValues { ChatReference(id: $0.mcpId, name: $0.displayName) }
    }
}
