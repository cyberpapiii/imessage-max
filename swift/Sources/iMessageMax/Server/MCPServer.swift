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
            if dbStatus == .permissionDenied {
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
        announce(transport: "stdio", resolver: resolver, contactsPolicy: contactsPolicy)
        try await serveStdio(base: StdioTransport(), catalog: catalog)
    }

    /// Serves `base` until its input ends, then returns once every modern
    /// reply still in flight has been written. The SDK Server completes at
    /// end of input without waiting for the modern lane, so without the
    /// drain the process could exit before writing those replies.
    static func serveStdio(base: any Transport, catalog: ToolCatalog) async throws {
        let server = await Version.makeServer(catalog: catalog)
        let stdio = DualEraStdio(base: base, catalog: catalog)
        try await stdio.start()
        try await server.start(transport: stdio.legacy)
        await server.waitUntilCompleted()
        await stdio.drain()
    }

    /// The HTTP server, with the chat.db watcher feeding live-inbox
    /// notifications to every session. Returns when the server stops.
    static func runHTTP(host: String, port: Int, contactsPolicy: ContactsAccessPolicy.Override) async throws {
        let resolver = ContactResolver()
        let (newRows, newRowsSink) = AsyncStream<Int64>.makeStream()
        let watcher = MessageWatcher(databasePath: Database.defaultPath) { newRowsSink.yield($0) }
        let transport = HTTPTransport(
            host: host,
            port: port,
            catalog: ToolCatalog(database: Database(), resolver: resolver, liveInbox: { watcher.isLive }),
            setupPermissions: SetupPermissionService(resolver: resolver)
        )

        try await transport.connect()
        announce(transport: "http addr=\(host):\(port)", resolver: resolver, contactsPolicy: contactsPolicy)

        Task {
            for await rowid in newRows {
                await transport.notifyNewMessages(maxRowid: rowid)
            }
        }
        watcher.start()
        defer { watcher.stop() }
        try await transport.waitForTermination()
    }
}
