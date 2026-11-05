import Foundation
import IMessageMaxContract
import MCP

/// Server identity. `current` is the version source of truth: keep the
/// `static let current = "..."` line as is, `scripts/check-version.sh` reads it.
enum Version {
    static let current = "1.8.0"
    static let name = "iMessage Max"
    static let title = name
    /// What `imessage-max --version` prints. The Homebrew Formula's `test do`
    /// matches the product name in this string; `make verify` strips the
    /// trailing number back out with `grep -o '[0-9.]*$'`.
    static let display = "\(name) \(current)"
    static let instructions = """
        iMessage Max reads the local iMessage database and sends messages through Messages.app. Use chat ids only as follow-up tool-call targets; when explaining results to the user, refer to chats by chat.name, group names, or participant names. Sending changes state. Confirm the destination with the user before sending anything consequential.
        """

    static var serverCapabilities: Server.Capabilities {
        .init(tools: .init(listChanged: false))
    }

    static var serverInfo: Server.Info {
        .init(name: name, version: current, title: title)
    }

    /// The SDK Server for one legacy-lane connection (the stdio process, or
    /// one HTTP session), with the tool handlers registered.
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

    /// `serverInfo` and `capabilities` for the modern lane, which builds its
    /// own JSON. Constant, so encoded once.
    nonisolated(unsafe) static let serverInfoJSON: [String: Any] = JSONRPC.jsonValue(encoding: serverInfo) as? [String: Any] ?? [:]
    nonisolated(unsafe) static let capabilitiesJSON: [String: Any] = JSONRPC.jsonValue(encoding: serverCapabilities) as? [String: Any] ?? [:]
}

/// Legacy-era (dated, session-based) revisions: the ones the pinned SDK
/// negotiates on `initialize`.
enum LegacyProtocol {
    static let supported = MCP.Version.supported
    static let latest = MCP.Version.latest

    /// Revisions whose HTTP sessions must send `MCP-Protocol-Version` on
    /// every request after `initialize`.
    static let requiresHeaderAfterInitialize: Set<String> = [latest, "2025-06-18"]

    /// The revision the SDK answers an `initialize` with: the requested one
    /// when supported, otherwise the latest.
    static func negotiate(_ requested: String?) -> String {
        guard let requested, supported.contains(requested) else { return latest }
        return requested
    }
}

/// Modern-era (MCP 2026-07-28, stateless) revisions.
enum ModernProtocol {
    static let version = ModernMCP.protocolVersion
    static let supported = [version]
}
