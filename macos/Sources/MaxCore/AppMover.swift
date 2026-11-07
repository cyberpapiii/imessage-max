import Foundation

/// Moves the app into Applications so the helper is registered from a path
/// that lasts. Gatekeeper runs a quarantined download from a random read-only
/// path, and macOS keeps whatever path a helper was registered from.
public enum AppMover {
  /// /Applications when this user can write there, else ~/Applications.
  public static func destination(home: URL) -> URL {
    FileManager.default.isWritableFile(atPath: "/Applications")
      ? URL(fileURLWithPath: "/Applications", isDirectory: true)
      : home.appendingPathComponent("Applications", isDirectory: true)
  }

  /// Copies `bundle` into `directory` and returns the copy. An older copy is
  /// removed, never written over: writing over a running helper's file makes
  /// macOS kill it. The copy lands under a temporary name, then moves into
  /// place, so a failure leaves either the old copy or none.
  public static func install(_ bundle: URL, into directory: URL) throws -> URL {
    let fm = FileManager.default
    let target = directory.appendingPathComponent(bundle.lastPathComponent)
    let staging = directory.appendingPathComponent(".\(UUID().uuidString).app")
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    try fm.copyItem(at: bundle, to: staging)
    do {
      if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
      try fm.moveItem(at: staging, to: target)
    } catch {
      try? fm.removeItem(at: staging)
      throw error
    }
    return target
  }
}
