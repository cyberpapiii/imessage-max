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
        await performStartupChecks()
        ToolRegistry.registerAll(on: server, db: database, resolver: resolver)
        try await server.start(transport: transport)
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

        // Initialize contacts
        let (contactsOk, contactsStatus) = ContactResolver.authorizationStatus()
        if !contactsOk && contactsStatus == "not_determined" {
            _ = try? await resolver.requestAccess()
        }
        try? await resolver.initialize()
    }
}
