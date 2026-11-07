import Foundation

/// The install that versions before 2.0 made: an agent plist rendered into
/// ~/Library/LaunchAgents and, on a fresh Mac, a copy of the helper in
/// Application Support. Only the migration reads these paths.
public struct LegacyInstall: Sendable {
  public static let label = "local.imessage-max"
  public let plist: URL
  public let helper: URL

  public init(home: URL) {
    plist = home.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
    helper = home.appendingPathComponent(
      "Library/Application Support/iMessage Max/bin/imessage-max")
  }

  public func isPresent(jobLoaded: Bool) -> Bool {
    let fm = FileManager.default
    return jobLoaded || fm.fileExists(atPath: plist.path) || fm.fileExists(atPath: helper.path)
  }

  /// Removes the plist and the copied helper, then the helper's folders if
  /// nothing else is in them. A developer's plist may name a build in a
  /// checkout; that binary is not ours to delete and stays.
  public func removeFiles() throws {
    let fm = FileManager.default
    for file in [plist, helper] where fm.fileExists(atPath: file.path) {
      try fm.removeItem(at: file)
    }
    var folder = helper.deletingLastPathComponent()
    for _ in 0..<2 {
      guard (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true else { return }
      try fm.removeItem(at: folder)
      folder = folder.deletingLastPathComponent()
    }
  }
}
