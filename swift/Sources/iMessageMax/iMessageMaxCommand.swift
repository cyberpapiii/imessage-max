import Foundation
import ArgumentParser
import IMessageMaxContract
import MCP

@main
struct iMessageMax: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: ServiceDefaults.executableName,
        abstract: "MCP server for iMessage",
        version: Version.display
    )

    @Flag(name: .customLong(ServerOption.http.rawValue), help: "Run with HTTP transport instead of stdio")
    var http = false

    @Option(name: .customLong(ServerOption.host.rawValue), help: "Host for HTTP transport")
    var host: String = ServiceDefaults.host

    @Option(name: .customLong(ServerOption.port.rawValue), help: "Port for HTTP transport")
    var port: Int = ServiceDefaults.port

    @Flag(name: .customLong(ServerOption.allowExternalBind.rawValue), help: "Allow binding the HTTP transport to a non-loopback host (this exposes iMessage data and the access token to the network over unencrypted HTTP)")
    var allowExternalBind = false

    @Option(name: .customLong(ServerOption.tokenFile.rawValue), help: "File holding the bearer token HTTP clients must send. Created with mode 0600 if absent; its folder must already exist and belong to you. An existing file that holds anything but a token is left alone and the server exits. Defaults to ~/\(ServiceDefaults.tokenPath).")
    var tokenFile: String?

    @Option(name: .customLong(ServerOption.socketPath.rawValue), help: "Unix socket the helper listens on (with --http) or the stdio bridge connects to (without). Its folder must already exist and belong to you. Defaults to ~/\(ServiceDefaults.socketPath).")
    var socketPath: String?

    @Flag(name: .long, help: "Serve stdio in this process instead of bridging to the running iMessage Max helper. For development and tests: this process then needs Full Disk Access itself.")
    var direct = false

    @Option(name: .customLong(ServerOption.contactsPolicy.rawValue), help: "What to do when Contacts authorization is not yet determined: auto (prompt only if stdin is a terminal), request, or skip. With auto, the server honours IMESSAGE_MAX_CONTACTS_POLICY=request|skip.")
    var contactsPolicy: ContactsAccessPolicy.Override = .auto

    @Option(name: .customLong(ServerOption.logFile.rawValue), help: "Append diagnostics to this file instead of stderr. A leading ~/ means the home directory, because launchd does not expand it.")
    var logFile: String?

    func validate() throws {
        if http, let message = HostBindingPolicy.validationError(host: host, allowExternalBind: allowExternalBind) {
            throw ValidationError(message)
        }
        if http && direct {
            throw ValidationError("--direct serves stdio; it cannot be combined with --http.")
        }
        if direct && socketPath != nil {
            throw ValidationError("--socket-path has no effect with --direct.")
        }
    }

    mutating func run() async throws {
        if let logFile { Log.redirectStandardError(to: logFile) }

        guard http else {
            if direct {
                try await ServerStartup.runStdio(contactsPolicy: contactsPolicy)
                return
            }
            let socket = try resolvedSocketPath()
            // A departed client must surface as EPIPE, and a parent that
            // ignores SIGTERM must not make the bridge unkillable.
            signal(SIGPIPE, SIG_IGN)
            signal(SIGTERM, SIG_DFL)
            let outcome = await StdioBridge.run(socket: socket)
            if outcome.exitCode != 0 { throw ExitCode(outcome.exitCode) }
            return
        }

        if !HostBindingPolicy.isLoopback(host) {
            Log.warning("Binding to '\(host)' exposes iMessage data to the network. Use 127.0.0.1 for local-only access.")
        }

        let location = tokenFile.map { AccessToken.Location.custom(URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)) }
            ?? .standard
        let accessToken: AccessToken
        do {
            accessToken = try AccessToken.loadOrCreate(location)
        } catch {
            // The companion reads this line to say why the helper keeps
            // stopping, instead of showing it as stopped (088 #15).
            Log.error("\(StartupFailure.marker)\(error)")
            throw error
        }
        // The token's folder also holds the helper's settings and state, so
        // a test helper with --token-file never touches the installed one's.
        let supportFolder = location.file.deletingLastPathComponent()
        // A log write to a stderr pipe nobody reads must fail with EPIPE,
        // which Log drops, not kill the helper.
        signal(SIGPIPE, SIG_IGN)
        let stop = GracefulStop()
        let update = UpdateWatcher.forThisProcess()
        try await ServerStartup.runHTTP(
            host: host, port: port, accessToken: accessToken, contactsPolicy: contactsPolicy,
            socketOverride: socketPath, supportFolder: supportFolder, stop: stop, update: update
        )
        let code = KeepRunning.exitCode(
            folder: supportFolder, stopRequested: stop.wasRequested,
            updateInstalled: update?.requestedRestart == true)
        Log.info("Stopped exit=\(code)")
        if code != 0 { throw ExitCode(code) }
    }

    private func resolvedSocketPath() throws -> SocketPath {
        do {
            return try SocketPath.resolve(override: socketPath)
        } catch {
            throw ValidationError(error.description)
        }
    }
}

extension ContactsPolicyOption: @retroactive ExpressibleByArgument {}
