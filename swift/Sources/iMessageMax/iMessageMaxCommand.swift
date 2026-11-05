import Foundation
import ArgumentParser
import MCP

@main
struct iMessageMax: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "imessage-max",
        abstract: "MCP server for iMessage",
        version: Version.display
    )

    @Flag(name: .long, help: "Run with HTTP transport instead of stdio")
    var http = false

    @Option(name: .long, help: "Host for HTTP transport (default: 127.0.0.1 for security)")
    var host: String = "127.0.0.1"

    @Option(name: .long, help: "Port for HTTP transport (default: 8080)")
    var port: Int = 8080

    @Flag(name: .long, help: "Allow binding the HTTP transport to a non-loopback host (exposes iMessage data to the network; no authentication is provided)")
    var allowExternalBind = false

    @Option(name: .long, help: "When Contacts authorization is not yet determined: auto (prompt only if stdin is a terminal), request, or skip. IMESSAGE_MAX_CONTACTS_POLICY=request|skip is honoured when auto.")
    var contactsPolicy: ContactsAccessPolicy.Override = .auto

    @Flag(name: .long, help: "Ask macOS for Contacts access once, print the resulting status, and exit. Run this from a terminal; the server never prompts when it has no terminal.")
    var requestContactsAccess = false

    @Flag(name: .long, help: "Ask macOS for Automation access to Messages once, without sending a message, print the resulting status, and exit.")
    var requestMessagesAccess = false

    func validate() throws {
        if http, let message = HostBindingPolicy.validationError(host: host, allowExternalBind: allowExternalBind) {
            throw ValidationError(message)
        }
    }

    mutating func run() async throws {
        if requestMessagesAccess {
            let (_, status) = await AutomationPermission.requestAccess()
            print("Messages automation: \(status)")
            return
        }

        if requestContactsAccess {
            guard ContactResolver.usageDescriptionEmbedded else {
                throw ValidationError("This executable has no embedded Info.plist, so macOS cannot grant it Contacts access. Rebuild with `make build` (not a bare `swift build`).")
            }
            // Re-run ourselves disclaimed so the prompt and the grant belong to
            // imessage-max rather than the terminal (see ResponsibilityDisclaim).
            let disclaimedKey = "IMESSAGE_MAX_CONTACTS_REQUEST_DISCLAIMED"
            if ProcessInfo.processInfo.environment[disclaimedKey] == nil {
                guard let executable = Bundle.main.executablePath else {
                    throw ValidationError("Cannot locate this executable to re-launch it.")
                }
                let child = try ResponsibilityDisclaim.spawn(
                    path: executable,
                    arguments: Array(CommandLine.arguments.dropFirst()),
                    disclaim: true,
                    extraEnvironment: [disclaimedKey: "1"]
                )
                let status = ResponsibilityDisclaim.wait(child)
                if status != 0 { throw ExitCode(status) }
                return
            }
            let resolver = ContactResolver()
            await resolver.requestAccessIfAllowed(policy: .requestIfNeeded)
            print("Contacts authorization: \(await resolver.authorization().status)")
            return
        }

        if http {
            // Per-session Server instances: clean reconnection without "already initialized"
            let database = Database()
            let resolver = ContactResolver()

            let (dbOk, dbStatus) = Database.checkAccess()
            if !dbOk {
                Log.info("Database: \(dbStatus)")
                if dbStatus == "permission_denied" {
                    Log.info(DiagnoseTool.fullDiskAccessFix())
                }
            }

            // Warn if binding to a non-loopback address (only reachable when --allow-external-bind is set)
            if !HostBindingPolicy.isLoopback(host) {
                Log.warning("Binding to '\(host)' exposes iMessage data to the network. Use 127.0.0.1 for local-only access.")
            }

            let transport = HTTPTransport(
                host: host,
                port: port,
                catalog: ToolCatalog(database: database, resolver: resolver),
                setupPermissions: SetupPermissionService(resolver: resolver)
            )

            try await transport.connect()
            Log.info("Started version=\(Version.current) pid=\(getpid()) transport=http addr=\(host):\(port)")
            let resolvedPolicy = ContactsAccessPolicy.resolve(
                flag: contactsPolicy,
                environment: ProcessInfo.processInfo.environment,
                isTTY: ContactsAccessPolicy.stdinIsTTY
            )
            Task {
                let policy = resolvedPolicy
                await resolver.requestAccessIfAllowed(policy: policy)
                let contacts = await resolver.status()
                Log.info("Contacts: authorization=\(contacts.authorization) handles=\(contacts.handleCount)")
            }
            let watcher = MessageWatcher(databasePath: Database.defaultPath) { rowid in
                Task { await transport.notifyNewMessages(maxRowid: rowid) }
            }
            watcher.start()
            defer { watcher.stop() }
            try await transport.waitForTermination()
        } else {
            let server = MCPServerWrapper(contactsPolicy: contactsPolicy)
            let transport = StdioTransport()
            try await server.start(transport: transport)
        }
    }
}

extension ContactsAccessPolicy.Override: ExpressibleByArgument {}
