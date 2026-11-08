import Foundation
import IMessageMaxContract

/// Which agent plist launchd holds for the helper. `SMAppService.register()`
/// on an agent that is already registered keeps the definition launchd
/// loaded first, so a plist an update changed takes effect only after an
/// unregister and a register. The companion writes the bundled plist's
/// SHA-256 beside the helper's token each time it registers, and compares.
public struct RegisteredAgent: Sendable, Equatable {
  public let file: URL
  /// The bundled plist's SHA-256, in hex.
  public let bundledDigest: String

  public init(file: URL, bundledDigest: String) {
    self.file = file
    self.bundledDigest = bundledDigest
  }

  /// The file beside the token file the bundled plist names, so a test
  /// variant reads and writes only its own.
  public init(configuration: ServiceConfiguration) {
    self.init(
      file: configuration.tokenFile.deletingLastPathComponent()
        .appendingPathComponent(ServiceDefaults.registeredAgentFileName),
      bundledDigest: configuration.plistDigest)
  }

  /// Whether this app last registered the plist it bundles now. No record
  /// means a build from before the record registered the helper, so
  /// launchd may hold any earlier plist (2.0.0's differs), and counts as
  /// out of date.
  public var isCurrent: Bool {
    guard let data = try? Data(contentsOf: file) else { return false }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      == bundledDigest
  }

  public func save() throws {
    let folder = file.deletingLastPathComponent()
    // The helper makes this folder 0700 on first start; match it.
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try Data("\(bundledDigest)\n".utf8).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }

  public func remove() {
    try? FileManager.default.removeItem(at: file)
  }
}
