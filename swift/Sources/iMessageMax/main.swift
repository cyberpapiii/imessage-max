import Foundation
import ArgumentParser
import MCP

@main
struct iMessageMax: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "imessage-max",
        abstract: "MCP server for iMessage",
        version: Version.current
    )

    @Flag(name: .long, help: "Run with HTTP transport instead of stdio")
    var http = false

    @Option(name: .long, help: "Host for HTTP transport (default: 127.0.0.1 for security)")
    var host: String = "127.0.0.1"

    @Option(name: .long, help: "Port for HTTP transport (default: 8080)")
    var port: Int = 8080

    mutating func run() async throws {
        if http {
            // HTTP mode: HTTPTransport manages per-session Server instances
            // This enables clean reconnection without "already initialized" errors
            let database = Database()
            let resolver = ContactResolver()

            // Perform startup checks
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

            // Warn if binding to a non-localhost address
            if host != "127.0.0.1" && host != "::1" && host != "localhost" {
                FileHandle.standardError.write(
                    "[WARNING] Binding to '\(host)' exposes iMessage data to the network. Use 127.0.0.1 for local-only access.\n"
                        .data(using: .utf8)!)
            }

            let transport = HTTPTransport(
                host: host,
                port: port,
                database: database,
                resolver: resolver
            )

            try await transport.connect()
            try await transport.runService()
        } else {
            // Stdio mode: Single Server instance managed by MCPServerWrapper
            let server = MCPServerWrapper()
            let transport = StdioTransport()
            try await server.start(transport: transport)
        }
    }
}
