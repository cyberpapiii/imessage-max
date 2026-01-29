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

    @Option(name: .long, help: "Port for HTTP transport (default: 8080)")
    var port: Int = 8080

    mutating func run() async throws {
        let server = MCPServerWrapper()

        let transport: any Transport
        if http {
            transport = HTTPTransport(port: port)
        } else {
            transport = StdioTransport()
        }

        try await server.start(transport: transport)
    }
}
