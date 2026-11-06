import Foundation

extension ChatIdentifier {
    /// The chat a tool's chat id argument names (see `ChatLookup`). Every
    /// tool that takes a chat id resolves it here, and one that names no
    /// chat is `chat_not_found`.
    static func resolve(_ raw: String, db: Database) throws -> Int64 {
        try resolveChat(raw, db: db).id
    }

    /// `resolve`, with the chat row it found.
    static func resolveChat(_ raw: String, db: Database) throws -> ResolvedChat {
        do {
            return try ChatLookup.find(raw, db: db)
        } catch let notFound as ChatLookup.NotFound {
            throw ToolFailure.chatNotFound(notFound.chatId)
        }
    }
}
