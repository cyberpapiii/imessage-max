import Foundation
import IMessageMaxContract
import MCP

/// Process startup for both transports.
enum ServerStartup {
    /// Logs `Started version=… pid=… transport=…` and the database state,
    /// then settles Contacts access in the background so the transport
    /// answers meanwhile.
    static func announce(
        transport: String,
        resolver: ContactResolver,
        contactsPolicy: ContactsAccessPolicy.Override
    ) {
        Log.info("Started version=\(Version.current) pid=\(getpid()) transport=\(transport)")

        let (dbOk, dbStatus) = Database.checkAccess()
        if !dbOk {
            Log.info("Database: \(dbStatus)")
            if dbStatus == DatabaseStatus.permissionDenied.rawValue {
                Log.info(DiagnoseTool.fullDiskAccessFix())
            }
        }

        let policy = ContactsAccessPolicy.resolve(
            flag: contactsPolicy,
            environment: ProcessInfo.processInfo.environment,
            isTTY: ContactsAccessPolicy.stdinIsTTY
        )
        Task {
            await resolver.requestAccessIfAllowed(policy: policy)
            let contacts = await resolver.status()
            Log.info("Contacts: authorization=\(contacts.authorization) handles=\(contacts.handleCount)")
        }
    }

    /// The stdio server: one SDK Server for the legacy lane, the modern lane
    /// answered beside it. Returns when stdin closes.
    static func runStdio(contactsPolicy: ContactsAccessPolicy.Override) async throws {
        let resolver = ContactResolver()
        let catalog = ToolCatalog(database: Database(), resolver: resolver)
        let server = await Version.makeServer(catalog: catalog)
        let stdio = DualEraStdio(base: StdioTransport(), catalog: catalog)

        announce(transport: "stdio", resolver: resolver, contactsPolicy: contactsPolicy)

        try await stdio.start()
        try await server.start(transport: stdio.legacy)
        await server.waitUntilCompleted()
    }
}
