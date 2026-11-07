import AppKit
import IMessageMaxContract
import MaxCore

@MainActor
final class Milestones {
  enum Key: String {
    case introducedMenuBar = "hasIntroducedMenuBar"
    case welcomedConnection = "hasWelcomedConnection"
    case welcomedSetup = "hasWelcomedSetup"
  }

  private let defaults: UserDefaults?
  private var reachedInMemory: Set<Key> = []

  init(defaults: UserDefaults?) {
    self.defaults = defaults
  }

  func reached(_ key: Key) -> Bool {
    defaults?.bool(forKey: key.rawValue) ?? reachedInMemory.contains(key)
  }

  func mark(_ key: Key) {
    if let defaults {
      defaults.set(true, forKey: key.rawValue)
    } else {
      reachedInMemory.insert(key)
    }
  }
}

@MainActor
enum MessagesApp {
  static let bundleIdentifier = "com.apple.MobileSMS"

  private static var url: URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
  }

  static func open() {
    if let url { NSWorkspace.shared.open(url) }
  }

  /// macOS cannot check Automation access for an app that is not running, so
  /// the sending check opens Messages in the background first.
  static func ensureRunning() async throws {
    guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    else { return }
    guard let url else { throw CoreError.commandFailed("Messages is missing from this Mac.") }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
  }
}

extension ClientContext {
  /// The clients of the person using this Mac.
  static func live(home: URL) -> ClientContext {
    ClientContext(
      home: home,
      application: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
      open: { target, app in
        if let app {
          _ = try await NSWorkspace.shared.open(
            [target], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else if !NSWorkspace.shared.open(target) {
          throw CoreError.commandFailed("macOS could not open \(target.scheme ?? "the file").")
        }
      },
      run: ClientContext.runProcess,
      extensionFiles: Bundle.main.resourceURL?.appendingPathComponent("mcpb"),
      helper: Bundle.main.bundleURL.appendingPathComponent(ServiceDefaults.helperBundlePath),
      scratch: FileManager.default.temporaryDirectory.appendingPathComponent("iMessage Max"))
  }

  /// `--client-root`, which only a test build honors. Client configs live
  /// under `root`, apps are found only in `root/Applications`, commands only
  /// under `root`, and opening a file or link appends it to
  /// `root/open-requests.log` instead, so a live check never installs
  /// anything into a real client.
  static func sandbox(root: URL) -> ClientContext {
    var context = live(home: root)
    let names = [Client.claudeDesktopID: "Claude", Client.cursorID: "Cursor"]
    context.application = { id in
      names[id].map { root.appendingPathComponent("Applications/\($0).app") }
        .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }
    context.open = { target, app in
      let log = root.appendingPathComponent("open-requests.log")
      if !FileManager.default.fileExists(atPath: log.path) {
        FileManager.default.createFile(
          atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
      }
      let handle = try FileHandle(forWritingTo: log)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: Data("\(app?.path ?? "-") \(target.absoluteString)\n".utf8))
    }
    context.scratch = root.appendingPathComponent("scratch")
    // Only commands under `root`: Plug's CLI writes the real Keychain
    // whatever HOME it runs with.
    context.commandFolders = context.commandFolders.filter { $0.path.hasPrefix(root.path + "/") }
    return context
  }
}
