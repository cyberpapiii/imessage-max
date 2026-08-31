// Sources/iMessageMax/Server/ToolRegistry.swift
import Foundation
import MCP

enum ToolRegistry {
    /// The database and resolver the catalog's handlers are bound to. The
    /// catalog itself is process-wide, so re-registering the same twelve tools
    /// for every new session only rebuilt identical schemas and bumped the
    /// registry's catalog version twelve times, which invalidated the modern
    /// lane's encoded-catalog cache on every `initialize`.
    private static let boundLock = NSLock()
    nonisolated(unsafe) private static var boundDatabase: Database?
    nonisolated(unsafe) private static var boundResolver: ContactResolver?

    /// Registers the per-server method handlers, and the process-wide tool
    /// catalog if it is not already bound to this database and resolver.
    ///
    /// Every `Server` instance needs its own ListTools/CallTool handlers, so
    /// that part always runs. The catalog is shared, and re-registering it
    /// with the same dependencies is a no-op that costs work, so it is
    /// skipped. A different database or resolver (tests build their own)
    /// rebinds it, which is what re-registering always did.
    /// Returns true when the catalog is already bound to these dependencies.
    /// Claiming the binding and reading it happen under one lock, so two
    /// sessions starting at once cannot both decide to register.
    private static func claimCatalogBinding(db: Database, resolver: ContactResolver) -> Bool {
        boundLock.lock()
        defer { boundLock.unlock() }
        if boundDatabase === db && boundResolver === resolver {
            return true
        }
        boundDatabase = db
        boundResolver = resolver
        return false
    }

    static func registerAll(on server: Server, db: Database, resolver: ContactResolver) async {
        await server.registerToolHandlers()

        guard !claimCatalogBinding(db: db, resolver: resolver) else { return }

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
