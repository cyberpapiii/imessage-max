import Foundation
import MCP

actor MCPServerWrapper {
    private let server: Server
    private let database: Database
    private let resolver: ContactResolver
    private let contactsPolicy: ContactsAccessPolicy.Override
    private let catalog: ToolCatalog

    init(contactsPolicy: ContactsAccessPolicy.Override = .auto) {
        self.server = Server(
            name: Version.name,
            version: Version.current,
            title: Version.title,
            instructions: Version.instructions,
            capabilities: Version.serverCapabilities
        )
        self.database = Database()
        self.resolver = ContactResolver()
        self.contactsPolicy = contactsPolicy
        self.catalog = ToolCatalog(database: database, resolver: resolver)
    }

    func start(transport: any Transport) async throws {
        await server.registerToolHandlers(catalog)
        // Dual-era stdio: modern 2026-07-28 messages are answered by
        // ModernDispatcher inside DualEraStdioTransport; legacy traffic
        // continues through the SDK Server (with icon injection on send).
        let transport = IconMetadataTransport(base: DualEraStdioTransport(base: transport, catalog: catalog))

        Log.info("Started version=\(Version.current) pid=\(getpid()) transport=stdio")

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
            Log.info("Database: \(dbStatus)")
        }

        let policy = ContactsAccessPolicy.resolve(
            flag: contactsPolicy,
            environment: ProcessInfo.processInfo.environment,
            isTTY: ContactsAccessPolicy.stdinIsTTY
        )
        await resolver.requestAccessIfAllowed(policy: policy)
        try? await resolver.refresh()
    }
}
