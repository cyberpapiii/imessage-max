import Foundation
import MCP

actor MCPServerWrapper {
    private let server: Server
    private let database: Database
    private let resolver: ContactResolver

    init() {
        self.server = Server(
            name: Version.name,
            version: Version.current
        )
        self.database = Database()
        self.resolver = ContactResolver()
    }

    func start(transport: any Transport) async throws {
        // Register tools and start server FIRST so MCP handshake can complete
        ToolRegistry.registerAll(on: server, db: database, resolver: resolver)

        // Start server in background, then do startup checks
        // This allows MCP initialization to complete while contacts load
        async let serverTask: () = server.start(transport: transport)

        // Perform startup checks after server starts (non-blocking for MCP)
        Task {
            await performStartupChecks()
        }

        try await serverTask
        await server.waitUntilCompleted()
    }

    private func performStartupChecks() async {
        // Check database access
        let (dbOk, dbStatus) = Database.checkAccess()
        if !dbOk {
            FileHandle.standardError.write(
                "[iMessage Max] Database: \(dbStatus)\n".data(using: .utf8)!
            )
        }

        // Initialize contacts (this may show permission dialog)
        let (contactsOk, contactsStatus) = ContactResolver.authorizationStatus()
        if !contactsOk && contactsStatus == "not_determined" {
            _ = try? await resolver.requestAccess()
        }
        try? await resolver.initialize()
    }
}
