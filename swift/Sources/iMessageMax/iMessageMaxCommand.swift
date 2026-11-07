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

    @Flag(name: .customLong(ServerOption.allowExternalBind.rawValue), help: "Allow binding the HTTP transport to a non-loopback host (this exposes iMessage data to the network, and the server provides no authentication)")
    var allowExternalBind = false

    @Option(name: .customLong(ServerOption.contactsPolicy.rawValue), help: "What to do when Contacts authorization is not yet determined: auto (prompt only if stdin is a terminal), request, or skip. With auto, the server honours IMESSAGE_MAX_CONTACTS_POLICY=request|skip.")
    var contactsPolicy: ContactsAccessPolicy.Override = .auto

    @Option(name: .customLong(ServerOption.logFile.rawValue), help: "Append diagnostics to this file instead of stderr. A leading ~/ means the home directory, because launchd does not expand it.")
    var logFile: String?

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
        if let logFile { Log.redirectStandardError(to: logFile) }

        if requestMessagesAccess {
            let (_, status) = await AutomationPermission.requestAccess()
            print("Messages automation: \(status)")
            return
        }

        if requestContactsAccess {
            guard ContactResolver.usageDescriptionEmbedded else {
                throw ValidationError("This executable has no embedded Info.plist, so macOS cannot grant it Contacts access. Rebuild with `make build` (not a bare `swift build`).")
            }
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

        guard http else {
            try await ServerStartup.runStdio(contactsPolicy: contactsPolicy)
            return
        }

        if !HostBindingPolicy.isLoopback(host) {
            Log.warning("Binding to '\(host)' exposes iMessage data to the network. Use 127.0.0.1 for local-only access.")
        }

        try await ServerStartup.runHTTP(host: host, port: port, contactsPolicy: contactsPolicy)
    }
}

extension ContactsPolicyOption: @retroactive ExpressibleByArgument {}
