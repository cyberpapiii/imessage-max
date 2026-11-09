import Foundation
import IMessageMaxContract
import MCP

enum ServerStartup {
    static func announce(
        transport: String,
        resolver: ContactResolver,
        contactsPolicy: ContactsAccessPolicy.Override
    ) {
        Log.info("\(StartupFailure.startedMarker)\(Version.current) pid=\(getpid()) transport=\(transport)")

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
        // --direct is for development: its Automation answer stays in memory,
        // so it never touches the installed helper's.
        let access = MessagesAccess(memory: AutomationMemory(folder: nil))
        let catalog = ToolCatalog(database: Database(), resolver: resolver, access: access)
        announce(transport: "stdio", resolver: resolver, contactsPolicy: contactsPolicy)
        try await serveStdio(base: StdioTransport(), catalog: catalog)
    }

    static func serveStdio(base: any Transport, catalog: ToolCatalog) async throws {
        let server = await Version.makeServer(catalog: catalog)
        let stdio = DualEraStdio(base: base, catalog: catalog)
        do {
            try await stdio.start()
            try await server.start(transport: stdio.legacy)
        } catch {
            // Releases the base transport, which on the socket lane holds
            // the connection's fd.
            await stdio.stop()
            throw error
        }
        await server.waitUntilCompleted()
        await stdio.drain()
    }

    static func runHTTP(
        host: String, port: Int, accessToken: AccessToken, contactsPolicy: ContactsAccessPolicy.Override,
        socketOverride: String?, supportFolder: URL, stop: GracefulStop
    ) async throws {
        let resolver = ContactResolver()
        let access = MessagesAccess(memory: AutomationMemory(folder: supportFolder))
        let (newRows, newRowsSink) = AsyncStream<Int64>.makeStream()
        let watcher = MessageWatcher(databasePath: Database.defaultPath) { newRowsSink.yield($0) }
        let listenerState = HTTPListenerState()
        let catalog = ToolCatalog(
            database: Database(), resolver: resolver, access: access, liveInbox: { watcher.isLive },
            http: { listenerState.diagnosis(port: port) }
        )
        let transport = HTTPTransport(
            host: host,
            port: port,
            accessToken: accessToken,
            catalog: catalog,
            setupPermissions: SetupPermissionService(resolver: resolver, access: access),
            listenerState: listenerState
        )

        // Returns once the port listens, or once it is known to be taken. A
        // taken port keeps the helper up: it serves the socket and retries
        // the bind, instead of exiting into a launchd relaunch loop (088 #10).
        let bind: BindOutcome
        do {
            bind = try await transport.connect()
        } catch {
            Log.error("\(StartupFailure.marker)cannot listen on \(host):\(port): \(error)")
            throw error
        }
        stop.onStop { Task { await transport.beginStop() } }
        let listener = await startSocketSupervisor(override: socketOverride, catalog: catalog)
        let httpState = bind == .listening ? "" : " http=port_in_use"
        announce(transport: "http addr=\(host):\(port)\(httpState)", resolver: resolver, contactsPolicy: contactsPolicy)

        Task {
            for await rowid in newRows {
                await transport.notifyNewMessages(maxRowid: rowid)
            }
        }
        watcher.start()
        defer { watcher.stop() }
        do {
            try await transport.waitForTermination()
        } catch {
            await listener?.stop()
            throw error
        }
        await listener?.stop()
    }

    /// Starts the socket every stdio bridge connects to, and keeps it
    /// listening (`SocketSupervisor`). Each connection is its own dual-era
    /// session over the shared catalog.
    ///
    /// Best effort: a socket problem logs one warning, and HTTP keeps
    /// serving. The helper runs under launchd KeepAlive, so a helper that
    /// exited over its socket would restart into the same problem in a loop
    /// and take HTTP down with it. nil only when the path itself is unusable.
    static func startSocketSupervisor(override: String?, catalog: ToolCatalog) async -> SocketSupervisor? {
        let socket: SocketPath
        do throws(SocketSetupError) {
            socket = try SocketPath.resolve(override: override)
        } catch {
            Log.warning("Serving HTTP only; stdio bridges cannot connect. \(error)")
            return nil
        }
        return await SocketSupervisor.start(at: socket) { transport in
            do {
                try await serveStdio(base: transport, catalog: catalog)
            } catch {
                Log.warning("socket session ended: \(error)")
            }
        }
    }
}
