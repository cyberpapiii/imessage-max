import Foundation

/// How the service is installed and reached. The agent plist
/// (macos/Resources/LaunchAgents), swift/Makefile and script/assemble_app.sh
/// repeat some of these; ServiceFilesContractTests in swift/Tests keeps them
/// in step.
public enum ServiceDefaults {
  public static let host = "127.0.0.1"
  public static let port = 47821
  public static let executableName = "imessage-max"
  /// The label of the agent the app registers with SMAppService. A test build
  /// may bundle a plist with another label; the companion reads the label from
  /// its bundled plist, never from here.
  public static let launchdLabel = "com.cyberpapiii.imessage-max.helper"
  /// The helper's path inside the app bundle, the plist's BundleProgram.
  public static let helperBundlePath = "Contents/MacOS/\(executableName)"
  /// Where the agent plist lives inside the app bundle, as SMAppService requires.
  public static let agentPlistDirectory = "Contents/Library/LaunchAgents"
  /// The helper's log, relative to the home directory. The plist passes it to
  /// `--log-file` with a leading `~/`, because launchd does not expand `~`.
  public static let logPath = "Library/Logs/iMessage Max/imessage-max.log"
  /// The bearer token every HTTP request must send. The helper creates it,
  /// mode 0600, on first start.
  public static let tokenPath = "Library/Application Support/iMessage Max/token"
  /// The Keep running setting, off while this file exists. It sits beside
  /// the token file, so a helper with `--token-file` reads it from that
  /// file's folder. The helper reads it as it stops: without it a SIGTERM
  /// exits non-zero and launchd starts the helper again.
  public static let stayStoppedFileName = "stay-stopped"
  /// The SHA-256, in hex, of the agent plist the companion last registered,
  /// beside the token file like `stayStoppedFileName`. SMAppService keeps a
  /// registered job on the plist it first loaded, so the companion compares
  /// this with the bundled plist to know when an update must register again.
  public static let registeredAgentFileName = "registered-agent.sha256"
  /// The last definite answer macOS gave about the helper's Automation access
  /// to Messages: one PermissionStatus word (`authorized`, `denied` or
  /// `not_determined`). macOS can only answer while Messages runs, so
  /// diagnose reports this word while Messages is closed. It sits beside the
  /// token file, like `stayStoppedFileName`.
  public static let automationAnswerFileName = "automation-answer"
  /// The Unix socket stdio bridges connect to. The helper creates it, mode
  /// 0600, in its 0700 app-support folder.
  public static let socketPath = "Library/Application Support/iMessage Max/mcp.sock"
  /// Used in the per-user temp folder (confstr _CS_DARWIN_USER_TEMP_DIR)
  /// when the home path is too long for socketPath to fit in sockaddr_un.
  public static let fallbackSocketName = "imessage-max.sock"
  /// The companion app's bundle identifier, also its log subsystem.
  public static let companionBundleID = "com.cyberpapiii.imessage-max.menubar"
  /// The clientInfo name on the companion's diagnose requests. The helper
  /// leaves those out of `DiagnoseResult.assistantCalls`.
  public static let companionClientName = "iMessage Max Menu"
  /// Hosts that keep the listener local. Binding anywhere else needs
  /// `--allow-external-bind`, and the setup route is never offered there.
  public static let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]
}

/// Server command-line options that the companion reads back out of the
/// bundled agent plist's ProgramArguments.
public enum ServerOption: String, CaseIterable, Sendable {
  case http
  case host
  case port
  case contactsPolicy = "contacts-policy"
  case allowExternalBind = "allow-external-bind"
  case logFile = "log-file"
  case socketPath = "socket-path"
  case tokenFile = "token-file"

  public var flag: String { "--\(rawValue)" }

  public var takesValue: Bool {
    switch self {
    case .host, .port, .contactsPolicy, .logFile, .socketPath, .tokenFile: true
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

/// Names from MCP 2026-07-28, the stateless "modern" era, that the
/// companion's diagnose request uses.
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
