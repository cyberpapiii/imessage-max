import Foundation

/// How the service is installed and reached. The launchd plist template
/// (swift/launchd), swift/Makefile and script/build_and_run.sh repeat some of
/// these; ServiceFilesContractTests in swift/Tests keeps them in step.
public enum ServiceDefaults {
  public static let host = "127.0.0.1"
  public static let port = 8080
  public static let executableName = "imessage-max"
  public static let launchdLabel = "local.imessage-max"
  /// Home-relative paths.
  public static let launchAgentPath = "Library/LaunchAgents/\(launchdLabel).plist"
  public static let stdoutLogPath = "Library/Logs/imessage-max.stdout.log"
  public static let stderrLogPath = "Library/Logs/imessage-max.stderr.log"
  /// Hosts that keep the listener local. Binding anywhere else needs
  /// `--allow-external-bind`, and the setup route is never offered there.
  public static let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]
}

/// Server command-line options that the companion reads back out of the
/// installed plist's ProgramArguments.
public enum ServerOption: String, CaseIterable, Sendable {
  case http
  case host
  case port
  case contactsPolicy = "contacts-policy"
  case allowExternalBind = "allow-external-bind"

  public var flag: String { "--\(rawValue)" }

  public var takesValue: Bool {
    switch self {
    case .host, .port, .contactsPolicy: true
    case .http, .allowExternalBind: false
    }
  }

  public init?(flag: String) {
    guard flag.hasPrefix("--"), let option = Self(rawValue: String(flag.dropFirst(2))) else {
      return nil
    }
    self = option
  }
}

/// Values of `--contacts-policy`. `auto` prompts only when stdin is a terminal.
public enum ContactsPolicyOption: String, CaseIterable, Sendable {
  case auto, request, skip
}

/// MCP 2026-07-28 (the stateless "modern" era) names the companion's
/// diagnose request uses.
public enum ModernMCP {
  public static let protocolVersion = "2026-07-28"
}

public enum MCPHeader {
  public static let protocolVersion = "MCP-Protocol-Version"
  public static let sessionID = "Mcp-Session-Id"
  /// 2026-07-28 request-metadata header.
  public static let method = "Mcp-Method"
  /// 2026-07-28 request-metadata header.
  public static let name = "Mcp-Name"
}

/// Reserved `_meta` keys defined by MCP 2026-07-28.
public enum ModernMetaKey {
  public static let protocolVersion = "io.modelcontextprotocol/protocolVersion"
  public static let clientInfo = "io.modelcontextprotocol/clientInfo"
  public static let clientCapabilities = "io.modelcontextprotocol/clientCapabilities"
  public static let serverInfo = "io.modelcontextprotocol/serverInfo"
}
