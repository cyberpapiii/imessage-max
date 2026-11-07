import Foundation

/// Moves the app into Applications so the helper is registered from a path
/// that lasts. Gatekeeper runs a quarantined download from a random read-only
/// path, and macOS keeps whatever path a helper was registered from.
public enum AppMover {
  public enum Failure: Error, LocalizedError, Equatable {
    /// Applications holds another app under this name.
    case otherApp(name: String)
    case copyStillRunning

    public var errorDescription: String? {
      switch self {
      case .otherApp(let name):
        "Applications already has a different app named \(name). Move it out of Applications, then try again."
      case .copyStillRunning:
        "The iMessage Max in Applications is still open. Quit it, then try again."
      }
    }
  }

  /// /Applications when this user can write there, else ~/Applications.
  public static func destination(home: URL) -> URL {
    FileManager.default.isWritableFile(atPath: "/Applications")
      ? URL(fileURLWithPath: "/Applications", isDirectory: true)
      : home.appendingPathComponent("Applications", isDirectory: true)
  }

  /// Copies `bundle` into `directory` and returns the copy. A copy already
  /// there is replaced only when it is this app, after `beforeReplacing`
  /// has quit it. The new copy is staged next to the target, on the same
  /// volume, and swapped in with one replace, so a failure leaves the old
  /// copy in place. Its file is never written over: writing over a running
  /// helper's file makes macOS kill it.
  public static func install(
    _ bundle: URL, into directory: URL, beforeReplacing: (URL) throws -> Void = { _ in }
  ) throws -> URL {
    let fm = FileManager.default
    let target = directory.appendingPathComponent(bundle.lastPathComponent)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    sweepStaging(for: target)
    let replacing = fm.fileExists(atPath: target.path)
    if replacing {
      guard let identifier = bundleIdentifier(of: bundle), bundleIdentifier(of: target) == identifier
      else { throw Failure.otherApp(name: target.lastPathComponent) }
    }
    let staging = directory.appendingPathComponent(
      stagingPrefix(for: target) + UUID().uuidString)
    do {
      try fm.copyItem(at: bundle, to: staging)
      if replacing {
        try beforeReplacing(target)
        _ = try fm.replaceItemAt(target, withItemAt: staging)
      } else {
        try fm.moveItem(at: staging, to: target)
      }
    } catch {
      try? fm.removeItem(at: staging)
      throw error
    }
    return target
  }

  /// Hidden, and without the .app extension, so Finder and LaunchServices
  /// never treat a staged copy as an app.
  static func stagingPrefix(for target: URL) -> String {
    ".\(target.lastPathComponent).staging-"
  }

  /// Removes staged copies an earlier move left behind when it crashed.
  private static func sweepStaging(for target: URL) {
    let fm = FileManager.default
    let directory = target.deletingLastPathComponent()
    let prefix = stagingPrefix(for: target)
    for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
    where name.hasPrefix(prefix) {
      try? fm.removeItem(at: directory.appendingPathComponent(name))
    }
  }

  private static func bundleIdentifier(of bundle: URL) -> String? {
    let info = bundle.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: info),
      let values = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { return nil }
    return values["CFBundleIdentifier"] as? String
  }
}
