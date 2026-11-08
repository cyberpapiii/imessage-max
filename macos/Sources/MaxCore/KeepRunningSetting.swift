import Darwin
import Foundation
import IMessageMaxContract

/// Settings → General → Keep running. On, the default, means launchd starts
/// the helper again after it quits. Off is a stay-stopped file beside the
/// helper's token, which the helper reads as it stops, so a change applies
/// to the running helper. Stop unloads the job either way.
public struct KeepRunningSetting: Sendable, Equatable {
  public let marker: URL

  public init(marker: URL) { self.marker = marker }

  /// The file beside the token file the bundled plist names, so a test
  /// variant reads and writes only its own.
  public init(configuration: ServiceConfiguration) {
    self.init(
      marker: configuration.tokenFile.deletingLastPathComponent()
        .appendingPathComponent(ServiceDefaults.stayStoppedFileName))
  }

  public var isOn: Bool {
    var info = stat()
    return lstat(marker.path, &info) != 0
  }

  public func set(_ on: Bool) throws {
    if on {
      guard unlink(marker.path) == 0 || errno == ENOENT else { throw Self.failure(errno) }
      return
    }
    guard isOn else { return }
    let folder = marker.deletingLastPathComponent()
    do {
      // The helper makes this folder 0700 on first start; match it.
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch {
      throw CoreError.commandFailed("Could not change Keep running. \(error.localizedDescription)")
    }
    let fd = open(marker.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw Self.failure(errno) }
    close(fd)
  }

  private static func failure(_ code: Int32) -> CoreError {
    .commandFailed("Could not change Keep running. \(String(cString: strerror(code))).")
  }
}
