// Sources/iMessageMax/Server/ToolRegistry.swift
import Foundation
import MCP

enum ToolRegistry {
    static func registerAll(on server: Server, db: Database, resolver: ContactResolver) async {
        await server.registerToolHandlers()

        FindChatTool.register(on: server, database: db, resolver: resolver)
        GetChatDetailsTool.register(on: server, db: db, resolver: resolver)
        ListChatsTool.register(on: server, db: db, resolver: resolver)
        GetActiveConversations.register(on: server, db: db, resolver: resolver)
        GetMessagesTool.register(on: server, db: db, resolver: resolver)
        GetContext.register(on: server, db: db, resolver: resolver)
        SearchTool.register(on: server, db: db, resolver: resolver)
        GetUnread.register(on: server, db: db, resolver: resolver)
        ListAttachments.register(on: server, db: db, resolver: resolver)
        GetAttachment.register(on: server, db: db)
        SendTool.register(on: server, resolver: resolver)
        DiagnoseTool.register(on: server, resolver: resolver)
    }
}
