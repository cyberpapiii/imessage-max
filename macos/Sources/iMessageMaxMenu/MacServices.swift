import AppKit
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
