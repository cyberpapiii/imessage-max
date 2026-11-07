import Foundation
import Testing

@testable import MaxCore

private let access = ClientAccess(
  endpoint: URL(string: "http://127.0.0.1:47821/")!, token: "tok-123_ABC")

private typealias Run = (String, [String], [String: String], Data?)

private final class Recorder: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [Run] = []
  private var opened: [(URL, URL?)] = []

  var runs: [Run] { lock.withLock { items } }
  var opens: [(URL, URL?)] { lock.withLock { opened } }
  func run(_ entry: Run) { lock.withLock { items.append(entry) } }
  func open(_ entry: (URL, URL?)) { lock.withLock { opened.append(entry) } }
}

private func context(
  _ home: URL, apps: [String: URL] = [:], recorder: Recorder = Recorder(),
  run: (@Sendable (String, [String], [String: String], Data?) async throws -> ProcessResult)? = nil
) -> ClientContext {
  ClientContext(
    home: home, commandFolders: [home.appendingPathComponent("bin")],
    application: { apps[$0] },
    open: { recorder.open(($0, $1)) },
    run: run ?? { executable, arguments, environment, input in
      recorder.run((executable, arguments, environment, input))
      return ProcessResult(exitCode: 0, output: "")
    },
    scratch: home.appendingPathComponent("scratch"))
}

private func write(_ text: String, to url: URL, mode: Int = 0o600) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data(text.utf8).write(to: url)
  try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

private func mode(_ url: URL) throws -> Int {
  (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
}

private let codexBlock = """
  [mcp_servers.imessage]
  url = "http://127.0.0.1:47821/"
  http_headers = { Authorization = "Bearer tok-123_ABC" }

  """

@Test func codexWriterCreatesAMissingFilePrivately() async throws {
  let home = try temporaryHome()
  try FileManager.default.createDirectory(
    at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
  let context = context(home)
  #expect(Client.codex.detect(context))
  #expect(await Client.codex.link(context, access) == .notConnected)

  let result = try await Client.codex.connect(context, access)
  let file = home.appendingPathComponent(".codex/config.toml")
  #expect(try read(file) == codexBlock)
  #expect(try mode(file) == 0o600)
  #expect(result.summary.hasPrefix("Created ~/.codex/config.toml"))
  #expect(await Client.codex.link(context, access) == .connected)
}

@Test func codexWriterLeavesEveryOtherTableByteIdentical() async throws {
  let home = try temporaryHome()
  let file = home.appendingPathComponent(".codex/config.toml")
  let before = """
    model = "gpt-5"  # a comment with [brackets]

    [mcp_servers.plug]
    command = "plug"
    args = [
      "connect",
      "--quiet", # trailing
    ]

    [mcp_servers.node_repl]
    command = "node"
    note = \"\"\"
    [mcp_servers.imessage]
    not a table\"\"\"

    [mcp_servers.node_repl.env]
    A = "1"
    """
  try write(before, to: file, mode: 0o640)
  let context = context(home)

  let result = try await Client.codex.connect(context, access)
  #expect(try read(file) == before + "\n\n" + codexBlock)
  #expect(try mode(file) == 0o640, "the file keeps its mode")
  #expect(try read(ConfigFile.backup(of: file)) == before)
  #expect(try mode(ConfigFile.backup(of: file)) == 0o640)
  #expect(result.summary.contains("config.toml.imessage-max-backup"))
  #expect(await Client.codex.link(context, access) == .connected)
}

@Test func codexWriterRewritesAnOldEntryInPlace() async throws {
  let home = try temporaryHome()
  let file = home.appendingPathComponent(".codex/config.toml")
  try write(
    """
    [mcp_servers.alpha]
    url = "http://example.com"

    [mcp_servers.imessage]
    command = "/opt/homebrew/bin/imessage-max"
    args = [
      "--stdio",
    ]
    tool_timeout_sec = 120 # keep me

    [mcp_servers.imessage.env]
    IMESSAGE_MAX_CONTACTS_POLICY = "skip"

    [mcp_servers.zulu]
    url = "http://example.org"

    """, to: file)
  let context = context(home)
  #expect(await Client.codex.link(context, access) == .outdated)

  _ = try await Client.codex.connect(context, access)
  #expect(
    try read(file) == """
      [mcp_servers.alpha]
      url = "http://example.com"

      [mcp_servers.imessage]
      tool_timeout_sec = 120 # keep me
      url = "http://127.0.0.1:47821/"
      http_headers = { Authorization = "Bearer tok-123_ABC" }


      [mcp_servers.zulu]
      url = "http://example.org"

      """)
  #expect(await Client.codex.link(context, access) == .connected)
}

@Test func connectingTwiceWritesOneEntryAndNoSecondBackup() async throws {
  let home = try temporaryHome()
  let file = home.appendingPathComponent(".codex/config.toml")
  try write("[mcp_servers.alpha]\nurl = \"x\"\n", to: file)
  let context = context(home)
  _ = try await Client.codex.connect(context, access)
  let once = try read(file)
  let backup = try read(ConfigFile.backup(of: file))

  let again = try await Client.codex.connect(context, access)
  #expect(try read(file) == once)
  #expect(try read(ConfigFile.backup(of: file)) == backup)
  #expect(once.components(separatedBy: "[mcp_servers.imessage]").count == 2)
  #expect(again.summary == "Codex already has iMessage Max in ~/.codex/config.toml.")
}

@Test func aReadOnlyConfigFailsCleanlyAndStaysUnchanged() async throws {
  let home = try temporaryHome()
  let file = home.appendingPathComponent(".codex/config.toml")
  let before = "[mcp_servers.alpha]\nurl = \"x\"\n"
  try write(before, to: file, mode: 0o444)
  defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

  await #expect(throws: ConfigFileError.readOnly("~/.codex/config.toml")) {
    try await Client.codex.connect(context(home), access)
  }
  #expect(try read(file) == before)
  #expect(try mode(file) == 0o444)
  #expect(!FileManager.default.fileExists(atPath: ConfigFile.backup(of: file).path))
}

@Test func anEntryWrittenAsAnInlineTableIsLeftAlone() async throws {
  let home = try temporaryHome()
  let file = home.appendingPathComponent(".codex/config.toml")
  let before = "[mcp_servers]\nimessage = { url = \"http://127.0.0.1:8080\" }\n"
  try write(before, to: file)
  await #expect(throws: ConfigFileError.unsupportedLayout("~/.codex/config.toml")) {
    try await Client.codex.connect(context(home), access)
  }
  #expect(try read(file) == before)
}

@Test func aSymlinkedConfigIsEditedWhereItLives() async throws {
  let home = try temporaryHome()
  let real = home.appendingPathComponent("dotfiles/codex.toml")
  try write("[mcp_servers.alpha]\nurl = \"x\"\n", to: real)
  try FileManager.default.createDirectory(
    at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
  let link = home.appendingPathComponent(".codex/config.toml")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

  _ = try await Client.codex.connect(context(home), access)
  #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
  #expect(try read(real).contains("[mcp_servers.imessage]"))
}

@Test func plugWriterUpdatesTheOldEntryAndKeepsItsTuning() async throws {
  let home = try temporaryHome()
  let file = home.appendingPathComponent("Library/Application Support/plug/config.toml")
  try write(
    """
    [servers.exa]
    transport = "http"
    auth_token = "keep-this"

    [servers.imessage]
    args = []
    enabled = true
    transport = "http"
    protocol = "legacy"
    url = "http://127.0.0.1:8080"
    auth = "oauth"
    max_concurrent = 1

    [servers.imessage.env]

    [servers.imessage.tool_renames]

    """, to: file)
  let context = context(home)
  #expect(Client.plug.detect(context))
  #expect(await Client.plug.link(context, access) == .outdated)

  _ = try await Client.plug.connect(context, access)
  #expect(
    try read(file) == """
      [servers.exa]
      transport = "http"
      auth_token = "keep-this"

      [servers.imessage]
      args = []
      enabled = true
      transport = "http"
      protocol = "legacy"
      url = "http://127.0.0.1:47821/"
      max_concurrent = 1
      auth_token = "tok-123_ABC"

      [servers.imessage.env]

      [servers.imessage.tool_renames]

      """)
  #expect(await Client.plug.link(context, access) == .connected)
}

private let plugConfigPath = "Library/Application Support/plug/config.toml"

/// Rob's entry, as `plug secret set` and `plug server edit` left it.
private let plugKeychainEntry = """
  [servers.imessage]
  args = []
  enabled = true
  transport = "http"
  protocol = "legacy"
  url = "http://127.0.0.1:47821"
  auth_token = "keychain:imessage-max-token"

  """

@Test func aKeychainReferenceInPlugsFileCountsAsConnected() async throws {
  let home = try temporaryHome()
  let file = home.appendingPathComponent(plugConfigPath)
  try write(plugKeychainEntry, to: file)
  let recorder = Recorder()
  let context = context(home, recorder: recorder)
  #expect(await Client.plug.link(context, access) == .connected)

  let result = try await Client.plug.connect(context, access)
  #expect(result.summary == "Plug already has iMessage Max.")
  #expect(try read(file) == plugKeychainEntry, "the reference is never replaced by the token")
  #expect(recorder.runs.isEmpty)

  try write(plugKeychainEntry.replacingOccurrences(of: "47821", with: "8080"), to: file)
  #expect(await Client.plug.link(context, access) == .outdated)
}

/// Plug's CLI as the connector sees it: a running service that lists
/// `servers`, and `secret set`, `server add` and `server edit` that change
/// what it lists.
private final class FakePlug: @unchecked Sendable {
  private let lock = NSLock()
  private var calls: [Run] = []
  var running = true
  var server: (url: String, health: String)?
  var secretExit: Int32 = 0

  init(server: (url: String, health: String)? = nil) { self.server = server }

  var runs: [Run] { lock.withLock { calls } }

  func run(_ executable: String, _ arguments: [String], _ environment: [String: String], _ input: Data?)
    -> ProcessResult
  {
    lock.withLock {
      calls.append((executable, arguments, environment, input))
      let command = Array(arguments.drop { $0 != "servers" && $0 != "secret" && $0 != "server" })
      switch command.first {
      case "servers":
        guard running else {
          return ProcessResult(exitCode: 0, output: #"{"runtime_available":false,"servers":{}}"#)
        }
        let listed = server.map {
          #"[{"server_id":"imessage","health":"\#($0.health)","source":{"url":"\#($0.url)"}}]"#
        }
        return ProcessResult(
          exitCode: 0, output: #"{"runtime_available":true,"servers":\#(listed ?? "[]")}"#)
      case "secret":
        return ProcessResult(exitCode: secretExit, output: secretExit == 0 ? "" : "Keychain locked")
      default:
        if let url = command.firstIndex(of: "--url").map({ command[$0 + 1] }) {
          server = (url, "Healthy")
        }
        return ProcessResult(exitCode: 0, output: "")
      }
    }
  }
}

private func plugContext(_ home: URL, _ plug: FakePlug) throws -> ClientContext {
  try write("#!/bin/sh\n", to: home.appendingPathComponent("bin/plug"), mode: 0o755)
  return context(home) { plug.run($0, $1, $2, $3) }
}

@Test func plugsServiceDecidesWhenItRuns() async throws {
  let home = try temporaryHome()
  try write(plugKeychainEntry, to: home.appendingPathComponent(plugConfigPath))
  let plug = FakePlug(server: ("http://127.0.0.1:47821", "Healthy"))
  let context = try plugContext(home, plug)
  #expect(await Client.plug.link(context, access) == .connected)
  let (executable, arguments, environment, input) = try #require(plug.runs.first)
  #expect(executable == home.appendingPathComponent("bin/plug").path)
  #expect(
    arguments == [
      "--config", home.appendingPathComponent(plugConfigPath).path, "servers", "--output", "json",
    ])
  #expect(environment["HOME"] == home.path && input == nil)

  plug.server = ("http://127.0.0.1:47821", "Failed")
  #expect(await Client.plug.link(context, access) == .outdated, "a token Plug cannot use")
  plug.server = ("http://127.0.0.1:8080", "Healthy")
  #expect(await Client.plug.link(context, access) == .outdated)
  plug.server = nil
  #expect(await Client.plug.link(context, access) == .notConnected)
  plug.running = false
  #expect(await Client.plug.link(context, access) == .connected, "the file decides")
}

@Test func plugsCLIStoresTheTokenOnStdinAndNeverInArgv() async throws {
  let home = try temporaryHome()
  let file = home.appendingPathComponent(plugConfigPath)
  let before = "[servers.exa]\ntransport = \"http\"\n"
  try write(before, to: file)
  let plug = FakePlug()
  let context = try plugContext(home, plug)
  #expect(await Client.plug.link(context, access) == .notConnected)

  let result = try await Client.plug.connect(context, access)
  let config = ["--config", file.path]
  let changes = plug.runs.filter { !$0.1.contains("servers") }
  #expect(
    changes.map(\.1) == [
      config + ["secret", "set", "imessage-max-token"],
      config + [
        "server", "add", "imessage", "--transport", "http", "--url", "http://127.0.0.1:47821/",
        "--auth", "bearer", "--bearer-token", "keychain:imessage-max-token",
      ],
    ])
  #expect(changes.first?.3 == Data("tok-123_ABC".utf8))
  #expect(plug.runs.allSatisfy { run in !run.1.contains { $0.contains("tok-123_ABC") } })
  #expect(plug.runs.allSatisfy { !$0.2.values.contains { $0.contains("tok-123_ABC") } })
  #expect(try read(file) == before, "Plug's CLI writes the file, not the connector")
  #expect(try read(ConfigFile.backup(of: file)) == before)
  #expect(result.summary.contains("added iMessage Max in Plug"))
  #expect(await Client.plug.link(context, access) == .connected)
}

@Test func plugsCLIEditsAnEntryThatIsThere() async throws {
  let home = try temporaryHome()
  let file = home.appendingPathComponent(plugConfigPath)
  try write(plugKeychainEntry, to: file)
  let plug = FakePlug(server: ("http://127.0.0.1:47821", "Failed"))
  let context = try plugContext(home, plug)
  #expect(await Client.plug.link(context, access) == .outdated)

  _ = try await Client.plug.connect(context, access)
  #expect(plug.runs.contains { $0.1.contains("edit") && $0.1.contains("imessage") })
  #expect(!plug.runs.contains { $0.1.contains("add") })
  #expect(await Client.plug.link(context, access) == .connected)
}

@Test func plugsCLIStopsWhenTheKeychainRefusesTheToken() async throws {
  let home = try temporaryHome()
  try write("[servers.exa]\n", to: home.appendingPathComponent(plugConfigPath))
  let plug = FakePlug()
  plug.secretExit = 1
  await #expect(throws: CoreError.commandFailed("Plug did not store the token. Keychain locked")) {
    try await Client.plug.connect(plugContext(home, plug), access)
  }
  #expect(!plug.runs.contains { $0.1.contains("server") })
}

@Test func claudeCodeAddsAUserScopedServerThroughItsCLI() async throws {
  let home = try temporaryHome()
  let claude = home.appendingPathComponent("bin/claude")
  try write("#!/bin/sh\n", to: claude, mode: 0o755)
  let config = home.appendingPathComponent(".claude.json")
  let before = #"{"mcpServers":{"imessage":{"type":"http","url":"http://127.0.0.1:8080"}},"x":1}"#
  try write(before, to: config)
  let recorder = Recorder()
  let context = context(home, recorder: recorder)
  #expect(Client.claudeCode.detect(context))
  #expect(await Client.claudeCode.link(context, access) == .outdated)

  _ = try await Client.claudeCode.connect(context, access)
  let runs = recorder.runs
  #expect(runs.map(\.1) == [
    ["mcp", "remove", "--scope", "user", "imessage"],
    [
      "mcp", "add", "--scope", "user", "--transport", "http", "imessage",
      "http://127.0.0.1:47821/", "--header", "Authorization: Bearer tok-123_ABC",
    ],
  ])
  #expect(runs.allSatisfy { $0.0 == claude.path && $0.2["HOME"] == home.path })
  #expect(try read(ConfigFile.backup(of: config)) == before)

  try write(
    #"{"mcpServers":{"imessage":{"type":"http","url":"http://127.0.0.1:47821/","headers":{"Authorization":"Bearer tok-123_ABC"}}}}"#,
    to: config)
  #expect(await Client.claudeCode.link(context, access) == .connected)
  let again = try await Client.claudeCode.connect(context, access)
  #expect(recorder.runs.count == 2, "a connected client runs no command")
  #expect(again.summary == "Claude Code already has iMessage Max.")
}

@Test func claudeCodeReportsAFailedAdd() async throws {
  let home = try temporaryHome()
  try write("#!/bin/sh\n", to: home.appendingPathComponent("bin/claude"), mode: 0o755)
  let failing = context(home) { _, _, _, _ in ProcessResult(exitCode: 1, output: "boom\nlast line") }
  await #expect(throws: CoreError.commandFailed("Claude Code did not add iMessage Max. last line")) {
    try await Client.claudeCode.connect(failing, access)
  }
}

@Test func cursorGetsItsInstallLinkWithTheTokenHeader() async throws {
  let home = try temporaryHome()
  let app = URL(fileURLWithPath: "/Applications/Cursor.app")
  let recorder = Recorder()
  let context = context(home, apps: [Client.cursorID: app], recorder: recorder)
  #expect(Client.cursor.detect(context))

  let result = try await Client.cursor.connect(context, access)
  #expect(result.finishInClient)
  let (link, opener) = try #require(recorder.opens.first)
  #expect(opener == app)
  let parts = try #require(URLComponents(url: link, resolvingAgainstBaseURL: false))
  #expect(parts.scheme == "cursor" && parts.host == "anysphere.cursor-deeplink")
  #expect(parts.path == "/mcp/install")
  let items = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value) })
  #expect(items["name"] == "imessage")
  let encoded = try #require(items["config"] ?? nil)
  let json = try #require(Data(base64Encoded: encoded))
  let config = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
  #expect(config["url"] as? String == "http://127.0.0.1:47821/")
  #expect((config["headers"] as? [String: String])?["Authorization"] == "Bearer tok-123_ABC")

  try write(
    #"{"mcpServers":{"imessage":{"url":"http://127.0.0.1:47821/","headers":{"Authorization":"Bearer tok-123_ABC"}},"plug":{"url":"x"}}}"#,
    to: home.appendingPathComponent(".cursor/mcp.json"))
  #expect(await Client.cursor.link(context, access) == .connected)
}

@Test func claudeDesktopOpensAnExtensionPackedFromTheHelper() async throws {
  let home = try temporaryHome()
  let files = home.appendingPathComponent("mcpb")
  try write(#"{"name":"imessage-max"}"#, to: files.appendingPathComponent("manifest.json"))
  try write("png", to: files.appendingPathComponent("assets/icon-16.png"))
  let helper = home.appendingPathComponent("helper")
  try write("binary", to: helper, mode: 0o755)
  let app = URL(fileURLWithPath: "/Applications/Claude.app")
  let recorder = Recorder()
  var context = ClientContext(
    home: home, application: { $0 == Client.claudeDesktopID ? app : nil },
    open: { recorder.open(($0, $1)) }, run: ClientContext.runProcess,
    extensionFiles: files, helper: helper,
    scratch: home.appendingPathComponent("scratch"))
  context.commandFolders = []
  #expect(Client.claudeDesktop.detect(context))
  #expect(await Client.claudeDesktop.link(context, access) == .notConnected)

  let result = try await Client.claudeDesktop.connect(context, access)
  #expect(result.finishInClient)
  let (bundle, opener) = try #require(recorder.opens.first)
  #expect(opener == app && bundle.pathExtension == "mcpb")
  let listing = try await ProcessRunner.run("/usr/bin/zipinfo", arguments: ["-1", bundle.path])
  #expect(
    Set(listing.output.split(separator: "\n").map(String.init))
      .isSuperset(of: ["manifest.json", "assets/icon-16.png", "server/imessage-max"]))

  try write(
    #"{"extensions":{"local.mcpb.rob-dezendorf.imessage-max":{"version":"1.8.0"}}}"#,
    to: home.appendingPathComponent("Library/Application Support/Claude/extensions-installations.json"))
  #expect(await Client.claudeDesktop.link(context, access) == .connected)
}

@Test func onlyClientsPresentOnThisMacAreListed() throws {
  let home = try temporaryHome()
  try FileManager.default.createDirectory(
    at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
  #expect(Client.all.filter { $0.detect(context(home)) }.map(\.id) == [.codex])
  let empty = try temporaryHome()
  #expect(Client.all.filter { $0.detect(context(empty)) }.isEmpty)
}

@Test func tomlStringsRoundTrip() {
  for value in ["plain", "with \"quotes\" and \\ slash", "tab\there"] {
    #expect(TOMLTable.decodeString(TOMLTable.string(value)) == value)
  }
  #expect(TOMLTable.decodeString("'literal \\ text'") == "literal \\ text")
}
