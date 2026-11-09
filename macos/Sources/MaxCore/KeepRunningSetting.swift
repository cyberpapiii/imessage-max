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
    self.init(marker: SettingMarker.url(ServiceDefaults.stayStoppedFileName, configuration))
  }

  public var isOn: Bool { !SettingMarker.exists(marker) }

  public func set(_ on: Bool) throws {
    try SettingMarker.set(marker, present: !on, setting: "Keep running")
  }
}

/// Settings → General → Keep this Mac awake. Off by default. On is a
/// keep-awake file beside the helper's token. The running helper checks for
/// it every few seconds and, while it exists, holds a power assertion that
/// stops the Mac sleeping while idle, so a change needs no restart.
public struct KeepAwakeSetting: Sendable, Equatable {
  public let marker: URL

  public init(marker: URL) { self.marker = marker }

  public init(configuration: ServiceConfiguration) {
    self.init(marker: SettingMarker.url(ServiceDefaults.keepAwakeFileName, configuration))
  }

  public var isOn: Bool { SettingMarker.exists(marker) }

  public func set(_ on: Bool) throws {
    try SettingMarker.set(marker, present: on, setting: "Keep this Mac awake")
  }
}

/// A setting stored as an empty file beside the helper's token file.
enum SettingMarker {
  static func url(_ name: String, _ configuration: ServiceConfiguration) -> URL {
    configuration.tokenFile.deletingLastPathComponent().appendingPathComponent(name)
  }

  static func exists(_ marker: URL) -> Bool {
    var info = stat()
    return lstat(marker.path, &info) == 0
  }

  static func set(_ marker: URL, present: Bool, setting: String) throws {
    if !present {
      guard unlink(marker.path) == 0 || errno == ENOENT else { throw failure(setting, errno) }
      return
    }
    guard !exists(marker) else { return }
    let folder = marker.deletingLastPathComponent()
    do {
      // The helper makes this folder 0700 on first start; match it.
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch {
      throw CoreError.commandFailed("Could not change \(setting). \(error.localizedDescription)")
    }
    let fd = open(marker.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw failure(setting, errno) }
    close(fd)
  }

  private static func failure(_ setting: String, _ code: Int32) -> CoreError {
    .commandFailed("Could not change \(setting). \(String(cString: strerror(code))).")
  }
}
