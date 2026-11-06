import Foundation

extension ChatIdentifier {
    static func resolve(_ raw: String, db: Database) throws -> Int64 {
        try resolveChat(raw, db: db).id
    }

    static func resolveChat(_ raw: String, db: Database) throws -> ResolvedChat {
        do {
            return try ChatLookup.find(raw, db: db)
        } catch let notFound as ChatLookup.NotFound {
            throw ToolFailure.chatNotFound(notFound.chatId)
        }
    }
}
