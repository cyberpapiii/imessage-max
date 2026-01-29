// Sources/iMessageMax/Server/ToolRegistry.swift
import Foundation
import MCP

enum ToolRegistry {
    static func registerAll(on server: Server, db: Database, resolver: ContactResolver) {
        // Register the MCP method handlers for tools
        server.registerToolHandlers()

        // Register all 12 tools

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
        UpdateTool.register(on: server)

        // Utility tools
        DiagnoseTool.register(on: server, resolver: resolver)
    }
}
