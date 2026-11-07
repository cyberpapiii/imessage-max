import Foundation

/// What a client needs to reach the helper: its address and its bearer token.
public struct ClientAccess: Sendable, Equatable {
  public let endpoint: URL
  public let token: String

  public init(endpoint: URL, token: String) {
    self.endpoint = endpoint
    self.token = token
  }

  public var url: String { endpoint.absoluteString }
  public var authorization: String { "Bearer \(token)" }

  /// Whether `url` names this endpoint, with or without the trailing slash.
  func isEndpoint(_ url: String) -> Bool {
    func trimmed(_ text: String) -> Substring {
      text.hasSuffix("/") ? text.dropLast() : Substring(text)
    }
    return trimmed(url) == trimmed(self.url)
  }
}

/// Everything on this Mac a connector reads or touches. The app passes the
/// real home and system; tests and the sandboxed live lanes pass a fixture
/// folder and stubs, so no real client config is ever read or written.
public struct ClientContext: Sendable {
  public var home: URL
  /// Folders searched for a client's command-line tool.
  public var commandFolders: [URL]
  /// An installed app by bundle identifier.
  public var application: @Sendable (String) -> URL?
  /// Opens a file or a URL, in a given app when one is named.
  public var open: @Sendable (URL, URL?) async throws -> Void
  /// Runs a command with an environment and, when given, bytes on its stdin.
  public var run: @Sendable (String, [String], [String: String], Data?) async throws -> ProcessResult
  /// The Claude Desktop extension's manifest and icons, and the helper it runs.
  public var extensionFiles: URL?
  public var helper: URL?
  /// Where the extension bundle is written before Claude Desktop opens it.
  public var scratch: URL

  public init(
    home: URL, commandFolders: [URL]? = nil, application: @escaping @Sendable (String) -> URL?,
    open: @escaping @Sendable (URL, URL?) async throws -> Void,
    run: @escaping @Sendable (String, [String], [String: String], Data?) async throws ->
      ProcessResult,
    extensionFiles: URL? = nil, helper: URL? = nil, scratch: URL
  ) {
    self.home = home
    self.commandFolders =
      commandFolders
      ?? [".local/bin", ".claude/local", ".npm-global/bin", ".bun/bin"].map {
        home.appendingPathComponent($0)
      } + ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(fileURLWithPath: $0) }
    self.application = application
    self.open = open
    self.run = run
    self.extensionFiles = extensionFiles
    self.helper = helper
    self.scratch = scratch
  }

  /// The real `run`. Passed explicitly: Swift 6.3 aborts when an async
  /// closure literal is a default argument here.
  @Sendable public static func runProcess(
    _ executable: String, _ arguments: [String], _ environment: [String: String], _ input: Data?
  ) async throws -> ProcessResult {
    try await ProcessRunner.run(
      executable, arguments: arguments, environment: environment, input: input, timeout: 30)
  }

  func file(_ path: String) -> URL { home.appendingPathComponent(path) }

  func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: file(path).path) }

  func command(_ name: String) -> URL? {
    commandFolders.map { $0.appendingPathComponent(name) }
      .first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  /// The whole environment a client's command runs with: this home folder,
  /// and a PATH that starts at the command's own folder.
  func environment(for command: URL) -> [String: String] {
    [
      "HOME": home.path,
      "PATH": ([command.deletingLastPathComponent().path]
        + ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"])
        .joined(separator: ":"),
    ]
  }

  /// `~/…` for a file under the home folder, for messages.
  func display(_ url: URL) -> String {
    let path = url.path
    let home = self.home.path
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
  }

  func json(_ path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: file(path).path) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }
}

public enum ClientID: String, Sendable, CaseIterable, Identifiable {
  case claudeDesktop, claudeCode, codex, plug, cursor
  public var id: String { rawValue }
}

/// Whether a client's config already reaches this helper.
public enum ClientLink: Sendable, Equatable {
  case notConnected
  /// An iMessage entry exists but holds another address or token, as one
  /// written for an older iMessage Max does.
  case outdated
  case connected
}

/// What one Connect click did, in words for the panel.
public struct ConnectResult: Sendable, Equatable {
  public let summary: String
  /// The client shows its own confirmation, and is connected once the user
  /// accepts it there.
  public let finishInClient: Bool

  public init(summary: String, finishInClient: Bool = false) {
    self.summary = summary
    self.finishInClient = finishInClient
  }
}

/// One row of the client table: how to find the client on this Mac, how to
/// tell whether it reaches the helper, and how to connect it.
public struct Client: Sendable, Identifiable {
  public let id: ClientID
  public let name: String
  public let detect: @Sendable (ClientContext) -> Bool
  public let link: @Sendable (ClientContext, ClientAccess) async -> ClientLink
  public let connect: @Sendable (ClientContext, ClientAccess) async throws -> ConnectResult

  public static let all: [Client] = [.claudeDesktop, .claudeCode, .codex, .plug, .cursor]

  public static func client(_ id: ClientID) -> Client { all.first { $0.id == id }! }

  /// The server name every client gets.
  static let entry = "imessage"
}

extension Client {
  public static let claudeDesktopID = "com.anthropic.claudefordesktop"
  public static let cursorID = "com.todesktop.230313mzl4w4u92"
  static let claudeExtensions = "Library/Application Support/Claude/extensions-installations.json"
  static let claudeCodeConfig = ".claude.json"
  static let codexConfig = ".codex/config.toml"
  static let plugConfig = "Library/Application Support/plug/config.toml"
  static let cursorConfig = ".cursor/mcp.json"

  /// Claude Desktop installs the bundled extension from the `.mcpb` it is
  /// handed, after the user clicks Install. The extension runs the stdio
  /// bridge, so it needs neither the address nor the token. Claude records an
  /// install under `local.mcpb.<author>.<name>` (or `local.dxt.` for older
  /// packages) in extensions-installations.json.
  static let claudeDesktop = Client(
    id: .claudeDesktop, name: "Claude",
    detect: { $0.application(claudeDesktopID) != nil },
    link: { context, _ in
      let installed = (context.json(claudeExtensions)?["extensions"] as? [String: Any])?.keys
      return installed?.contains { $0.hasPrefix("local.") && $0.hasSuffix(".imessage-max") } == true
        ? .connected : .notConnected
    },
    connect: { context, _ in
      let bundle = try await ExtensionBundle.write(context)
      try await context.open(bundle, context.application(claudeDesktopID))
      return ConnectResult(
        summary: "Claude opened the iMessage Max extension. Click Install there to finish.",
        finishInClient: true)
    })

  /// `claude mcp add` at user scope, so every project sees it. The CLI owns
  /// ~/.claude.json, which running sessions also write, so this app never
  /// edits that file itself.
  static let claudeCode = Client(
    id: .claudeCode, name: "Claude Code",
    detect: { $0.command("claude") != nil },
    link: { jsonLink($0, claudeCodeConfig, $1) },
    connect: { context, access in
      let before = jsonLink(context, claudeCodeConfig, access)
      if before == .connected {
        return ConnectResult(summary: "Claude Code already has iMessage Max.")
      }
      guard let claude = context.command("claude") else {
        throw CoreError.commandFailed("Claude Code’s claude command is no longer installed.")
      }
      let file = context.file(claudeCodeConfig)
      let backup = try ConfigFile.saveBackup(of: file, display: context.display(file))
      let environment = context.environment(for: claude)
      if before == .outdated {
        _ = try await context.run(
          claude.path, ["mcp", "remove", "--scope", "user", entry], environment, nil)
      }
      let added = try await context.run(
        claude.path,
        [
          "mcp", "add", "--scope", "user", "--transport", "http", entry, access.url,
          "--header", "Authorization: \(access.authorization)",
        ], environment, nil)
      guard added.exitCode == 0 else {
        throw CoreError.commandFailed("Claude Code did not add iMessage Max. \(added.lastLine)")
      }
      return ConnectResult(
        summary: "Added iMessage Max to Claude Code for every project"
          + (backup.map { ". The old \(context.display(file)) is saved as \($0.lastPathComponent)" }
            ?? "") + ". Start a new Claude Code session to use it.")
    })

  /// `[mcp_servers.imessage]` with `url` and `http_headers`. Codex rejects a
  /// `url` next to stdio keys, so those go.
  static let codex = Client(
    id: .codex, name: "Codex",
    detect: { $0.exists(".codex") },
    link: { context, access in
      tomlLink(
        context, codexConfig, TOMLTable("mcp_servers", entry),
        expect: { table, text in
          table.value("url", in: text).flatMap(TOMLTable.decodeString) == access.url
            && table.value("http_headers", in: text)?
              .contains(TOMLTable.string(access.authorization)) == true
        })
    },
    connect: { context, access in
      try writeTOML(
        context, codexConfig, TOMLTable("mcp_servers", entry), client: "Codex",
        values: [
          ("url", TOMLTable.string(access.url)),
          ("http_headers", "{ Authorization = \(TOMLTable.string(access.authorization)) }"),
        ],
        removing: ["command", "args", "env", "env_vars", "cwd", "bearer_token_env_var"],
        dropping: ["env", "http_headers"],
        next: "Restart Codex, or run /mcp, to load it.")
    })

  /// Plug's `[servers.imessage]`. With the `plug` command, Plug's own CLI
  /// does the work: the token goes to the Keychain on stdin, never in argv,
  /// and the entry refers to it. Without the command, the entry is written
  /// into the file with the token in `auth_token`.
  static let plug = Client(
    id: .plug, name: "Plug",
    detect: { $0.exists(plugConfig) },
    link: { await plugLink($0, $1) },
    connect: { context, access in
      if await plugLink(context, access) == .connected {
        return ConnectResult(summary: "Plug already has iMessage Max.")
      }
      guard let plug = context.command("plug") else {
        return try writeTOML(
          context, plugConfig, TOMLTable("servers", entry), client: "Plug",
          values: [
            ("transport", TOMLTable.string("http")),
            ("url", TOMLTable.string(access.url)),
            ("protocol", TOMLTable.string("legacy")),
            ("auth_token", TOMLTable.string(access.token)),
          ],
          removing: ["command", "auth", "oauth_client_id", "oauth_scopes"],
          next: "Plug picks up the change by itself.")
      }
      return try await connectPlug(context, plug, access)
    })

  /// The Keychain item, as `plug secret set` names it, that Plug's entry
  /// refers to for the token.
  static let plugSecret = "imessage-max-token"

  /// Plug's running service, when it answers, says whether the entry reaches
  /// this helper: a healthy connection to this address proves the token
  /// works, whether the file holds it or refers to the Keychain. Otherwise
  /// the file decides, and a `keychain:` reference counts, since only Plug
  /// can read it.
  static func plugLink(_ context: ClientContext, _ access: ClientAccess) async -> ClientLink {
    if let plug = context.command("plug"), let link = await plugService(context, plug, access) {
      return link
    }
    return tomlLink(
      context, plugConfig, TOMLTable("servers", entry),
      expect: { table, text in
        let token = table.value("auth_token", in: text).flatMap(TOMLTable.decodeString)
        return table.value("url", in: text).flatMap(TOMLTable.decodeString)
          .map(access.isEndpoint) == true
          && (token == access.token || token?.hasPrefix("keychain:") == true)
          && table.value("transport", in: text).flatMap(TOMLTable.decodeString) == "http"
      })
  }

  /// What `plug servers` says of the entry, or nil when Plug's service is
  /// not running or the command fails. Plug routes calls to a server that is
  /// Healthy or Degraded, so both count.
  private static func plugService(_ context: ClientContext, _ plug: URL, _ access: ClientAccess)
    async -> ClientLink?
  {
    let arguments = ["--config", context.file(plugConfig).path, "servers", "--output", "json"]
    guard
      let result = try? await context.run(
        plug.path, arguments, context.environment(for: plug), nil),
      result.exitCode == 0,
      let json = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
      json["runtime_available"] as? Bool == true,
      let servers = json["servers"] as? [[String: Any]]
    else { return nil }
    guard let server = servers.first(where: { $0["server_id"] as? String == entry }) else {
      return .notConnected
    }
    let url = (server["source"] as? [String: Any])?["url"] as? String
    let routable = ["Healthy", "Degraded"].contains(server["health"] as? String ?? "")
    return routable && url.map(access.isEndpoint) == true ? .connected : .outdated
  }

  private static func connectPlug(_ context: ClientContext, _ plug: URL, _ access: ClientAccess)
    async throws -> ConnectResult
  {
    let file = context.file(plugConfig)
    let config = ["--config", file.path]
    let environment = context.environment(for: plug)
    let backup = try ConfigFile.saveBackup(of: file, display: context.display(file))
    let stored = try await context.run(
      plug.path, config + ["secret", "set", plugSecret], environment, Data(access.token.utf8))
    guard stored.exitCode == 0 else {
      throw CoreError.commandFailed("Plug did not store the token. \(stored.lastLine)")
    }
    let present = FileManager.default.contents(atPath: file.path).map {
      TOMLTable("servers", entry).exists(in: String(decoding: $0, as: UTF8.self))
    } ?? false
    let saved = try await context.run(
      plug.path,
      config + ["server", present ? "edit" : "add", entry]
        + [
          "--transport", "http", "--url", access.url, "--auth", "bearer",
          "--bearer-token", "keychain:\(plugSecret)",
        ], environment, nil)
    guard saved.exitCode == 0 else {
      throw CoreError.commandFailed("Plug did not save iMessage Max. \(saved.lastLine)")
    }
    await waitForPlug(context, plug, access)
    return ConnectResult(
      summary:
        "Stored the token in the Keychain and \(present ? "updated" : "added") iMessage Max in Plug"
        + (backup.map { ". The old \(context.display(file)) is saved as \($0.lastPathComponent)" }
          ?? "") + ". Plug picks up the change by itself.")
  }

  /// Plug's service reloads its config a moment after the file changes. Up
  /// to five seconds of waiting lets the row read Connected after the click.
  private static func waitForPlug(_ context: ClientContext, _ plug: URL, _ access: ClientAccess)
    async
  {
    for _ in 0..<10 {
      guard let link = await plugService(context, plug, access), link != .connected else { return }
      await withCheckedContinuation { continuation in
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { continuation.resume() }
      }
    }
  }

  /// Cursor installs from its `mcp/install` deeplink after the user accepts,
  /// and keeps global servers in ~/.cursor/mcp.json.
  static let cursor = Client(
    id: .cursor, name: "Cursor",
    detect: { $0.application(cursorID) != nil || $0.exists(".cursor") },
    link: { jsonLink($0, cursorConfig, $1) },
    connect: { context, access in
      try await context.open(cursorInstallLink(access), context.application(cursorID))
      return ConnectResult(
        summary: "Cursor opened its install screen for iMessage Max. Click Install there to finish.",
        finishInClient: true)
    })

  /// `cursor://anysphere.cursor-deeplink/mcp/install?name=…&config=…`, where
  /// config is the server's JSON in base64, percent-encoded so `+` survives.
  public static func cursorInstallLink(_ access: ClientAccess) -> URL {
    let config: [String: Any] = [
      "url": access.url, "headers": ["Authorization": access.authorization],
    ]
    let json = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])) ?? Data()
    let encoded =
      json.base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    return URL(
      string: "cursor://anysphere.cursor-deeplink/mcp/install?name=\(entry)&config=\(encoded)")!
  }

  /// Claude Code and Cursor share one shape: `mcpServers.imessage` with
  /// `url` and `headers.Authorization`.
  private static func jsonLink(_ context: ClientContext, _ path: String, _ access: ClientAccess)
    -> ClientLink
  {
    let servers = context.json(path)?["mcpServers"] as? [String: Any]
    guard let server = servers?[entry] as? [String: Any] else { return .notConnected }
    let headers = server["headers"] as? [String: Any]
    return server["url"] as? String == access.url
      && headers?["Authorization"] as? String == access.authorization ? .connected : .outdated
  }

  private static func tomlLink(
    _ context: ClientContext, _ path: String, _ table: TOMLTable,
    expect: (TOMLTable, String) -> Bool
  ) -> ClientLink {
    guard let data = FileManager.default.contents(atPath: context.file(path).path) else {
      return .notConnected
    }
    let text = String(decoding: data, as: UTF8.self)
    if expect(table, text) { return .connected }
    return table.value("url", in: text) != nil || table.value("command", in: text) != nil
      ? .outdated : .notConnected
  }

  private static func writeTOML(
    _ context: ClientContext, _ path: String, _ table: TOMLTable, client: String,
    values: [(key: String, value: String)], removing: Set<String>, dropping: Set<String> = [],
    next: String
  ) throws -> ConnectResult {
    let file = context.file(path)
    let display = context.display(file)
    let write = try ConfigFile.apply(file, display: display) { text in
      do {
        return try table.upsert(text, values: values, removing: removing, dropping: dropping)
      } catch { throw ConfigFileError.unsupportedLayout(display) }
    }
    let header = "[\(table.path.joined(separator: "."))]"
    return switch write {
    case .unchanged: ConnectResult(summary: "\(client) already has iMessage Max in \(display).")
    case .created: ConnectResult(summary: "Created \(display) with \(header). \(next)")
    case .updated(let backup):
      ConnectResult(
        summary:
          "Set \(header) in \(display). The old file is saved as \(backup.lastPathComponent). \(next)")
    }
  }
}

/// The Claude Desktop extension, packed from the app's own helper and the
/// manifest bundled beside it: a zip of manifest.json, assets/ and
/// server/imessage-max. Packing it here keeps a second copy of the helper out
/// of the app and keeps the extension at the app's version.
enum ExtensionBundle {
  static func write(_ context: ClientContext) async throws -> URL {
    guard let files = context.extensionFiles, let helper = context.helper else {
      throw ConfigFileError.writeFailed("The Claude extension")
    }
    let manager = FileManager.default
    let stage = context.scratch.appendingPathComponent("extension")
    let bundle = context.scratch.appendingPathComponent("iMessage Max.mcpb")
    try? manager.removeItem(at: stage)
    try? manager.removeItem(at: bundle)
    do {
      try manager.createDirectory(
        at: stage.appendingPathComponent("server"), withIntermediateDirectories: true)
      try manager.copyItem(
        at: files.appendingPathComponent("manifest.json"),
        to: stage.appendingPathComponent("manifest.json"))
      try manager.copyItem(
        at: files.appendingPathComponent("assets"), to: stage.appendingPathComponent("assets"))
      try manager.copyItem(at: helper, to: stage.appendingPathComponent("server/imessage-max"))
    } catch { throw ConfigFileError.writeFailed("The Claude extension") }
    let zipped = try await context.run(
      "/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", stage.path, bundle.path],
      ["HOME": context.home.path], nil)
    try? manager.removeItem(at: stage)
    guard zipped.exitCode == 0 else { throw ConfigFileError.writeFailed("The Claude extension") }
    return bundle
  }
}
