// Sources/iMessageMax/Server/ToolRegistry.swift
import Foundation
import MCP

enum ToolRegistry {
    static func registerAll(on server: Server, db: Database, resolver: ContactResolver) async {
        // Register the MCP method handlers for tools
        await server.registerToolHandlers()

        // Register all 11 tools

        // Chat discovery tools
        FindChatTool.register(on: server, database: db, resolver: resolver)
        ListChatsTool.register(on: server, db: db, resolver: resolver)
        GetActiveConversations.register(on: server, db: db, resolver: resolver)

        // Message retrieval tools
        GetMessagesTool.register(on: server, db: db, resolver: resolver)
        GetContext.register(on: server, db: db, resolver: resolver)
        SearchTool.register(on: server, db: db, resolver: resolver)
        GetUnread.register(on: server, db: db, resolver: resolver)

        // Attachment tools
        ListAttachments.register(on: server, db: db, resolver: resolver)
        GetAttachment.register(on: server, db: db)

        // Action tools
        SendTool.register(on: server, resolver: resolver)

        // Utility tools
        DiagnoseTool.register(on: server, resolver: resolver)
    }
}
