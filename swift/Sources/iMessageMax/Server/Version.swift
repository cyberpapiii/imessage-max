import Foundation
import IMessageMaxContract
import MCP

enum Version {
    static let current = "2.1.0"
    static let name = "iMessage Max"
    static let title = name
    static let display = "\(name) \(current)"
    static let instructions = """
        iMessage Max reads the local iMessage database and sends messages through Messages.app. Use chat ids only as targets for follow-up tool calls. When you explain results to the user, refer to chats by chat.name, group names, or participant names. Sending changes state. Confirm the destination with the user before sending anything consequential.
        """

    static var serverCapabilities: Server.Capabilities {
        .init(tools: .init(listChanged: false))
    }

    static var serverInfo: Server.Info {
        .init(name: name, version: current, title: title)
    }

    static func makeServer(catalog: ToolCatalog) async -> Server {
        let server = Server(
            name: name,
            version: current,
            title: title,
            instructions: instructions,
            capabilities: serverCapabilities
        )
        await server.registerToolHandlers(catalog)
        return server
    }

    nonisolated(unsafe) static let serverInfoJSON: [String: Any] = JSONRPC.jsonValue(encoding: serverInfo) as? [String: Any] ?? [:]
    nonisolated(unsafe) static let capabilitiesJSON: [String: Any] = JSONRPC.jsonValue(encoding: serverCapabilities) as? [String: Any] ?? [:]
}

enum LegacyProtocol {
    static let supported = MCP.Version.supported
    static let latest = MCP.Version.latest

    static let headerRequiredSince = "2025-06-18"

    static let serverIconsSince = "2025-11-25"

    /// Revisions are dates, so string order is release order, and a revision
    /// a later SDK adds keeps the rule without an edit here.
    static func requiresHeaderAfterInitialize(_ version: String) -> Bool {
        version >= headerRequiredSince
    }

    static func definesServerIcons(_ version: String) -> Bool {
        version >= serverIconsSince
    }

    /// The revision the SDK answers an `initialize` with: the requested one
    /// when supported, otherwise the latest. Mirrors the SDK's
    /// `Version.negotiate(clientRequestedVersion:)`, which is internal there.
    static func negotiate(_ requested: String?) -> String {
        guard let requested, supported.contains(requested) else { return latest }
        return requested
    }
}

enum ModernProtocol {
    static let version = ModernMCP.protocolVersion
    static let supported = [version]
}
