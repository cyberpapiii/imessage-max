// Sources/iMessageMax/Server/ToolRegistry.swift
import Foundation
import MCP

enum ToolRegistry {
    static func registerAll(on server: Server, db: Database, resolver: ContactResolver) {
        // Register the MCP method handlers for tools
        server.registerToolHandlers()

        // Register individual tools
        FindChatTool.register(on: server, database: db, resolver: resolver)
        SearchTool.register(on: server, db: db, resolver: resolver)
    }
}
