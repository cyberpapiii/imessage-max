import Foundation
import IMessageMaxContract
import MCP

enum ServerStartup {
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

    static func runStdio(contactsPolicy: ContactsAccessPolicy.Override) async throws {
        let resolver = ContactResolver()
        let catalog = ToolCatalog(database: Database(), resolver: resolver)
        announce(transport: "stdio", resolver: resolver, contactsPolicy: contactsPolicy)
        try await serveStdio(base: StdioTransport(), catalog: catalog)
    }

    static func serveStdio(base: any Transport, catalog: ToolCatalog) async throws {
        let server = await Version.makeServer(catalog: catalog)
        let stdio = DualEraStdio(base: base, catalog: catalog)
        try await stdio.start()
        try await server.start(transport: stdio.legacy)
        await server.waitUntilCompleted()
        await stdio.drain()
    }

    static func runHTTP(
        host: String, port: Int, accessToken: AccessToken, contactsPolicy: ContactsAccessPolicy.Override,
        socket: SocketPath? = nil
    ) async throws {
        let socket = try socket ?? SocketPath.resolve(override: nil)
        let resolver = ContactResolver()
        let (newRows, newRowsSink) = AsyncStream<Int64>.makeStream()
        let watcher = MessageWatcher(databasePath: Database.defaultPath) { newRowsSink.yield($0) }
        let catalog = ToolCatalog(database: Database(), resolver: resolver, liveInbox: { watcher.isLive })
        let transport = HTTPTransport(
            host: host,
            port: port,
            accessToken: accessToken,
            catalog: catalog,
            setupPermissions: SetupPermissionService(resolver: resolver)
        )

        try await transport.connect()
        // After the HTTP bind, so a second helper on the same port fails
        // there before it touches the socket.
        let listener = try startSocketListener(at: socket, catalog: catalog)
        announce(transport: "http addr=\(host):\(port)", resolver: resolver, contactsPolicy: contactsPolicy)

        Task {
            for await rowid in newRows {
                await transport.notifyNewMessages(maxRowid: rowid)
            }
        }
        watcher.start()
        defer { watcher.stop() }
        try await transport.waitForTermination()
        await listener?.stop()
    }

    /// Starts the socket every stdio bridge connects to. Each connection is
    /// its own dual-era session over the shared catalog.
    ///
    /// Returns nil, with a warning, when another live helper already answers
    /// on the path: that helper serves the bridges, and this one still
    /// serves HTTP. Every other setup error is fatal, like a bad token file.
    static func startSocketListener(at socket: SocketPath, catalog: ToolCatalog) throws -> SocketListener? {
        do {
            return try SocketListener.start(at: socket) { transport in
                do {
                    try await serveStdio(base: transport, catalog: catalog)
                } catch {
                    Log.warning("socket session ended: \(error)")
                }
            }
        } catch .inUse(let path) {
            Log.warning("Another iMessage Max answers on \(path); stdio bridges use it. Serving HTTP only.")
            return nil
        }
    }
}
