import Foundation

/// What a config write did. A write that changes nothing touches nothing.
public enum ConfigWrite: Sendable, Equatable {
  case unchanged
  case created
  /// The file as it was before this write is at `backup`.
  case updated(backup: URL)
}

public enum ConfigFileError: Error, Sendable, Equatable, LocalizedError {
  case readOnly(String)
  case unreadable(String)
  /// The file defines the iMessage entry in a form this app does not edit,
  /// such as an inline table or dotted keys under the parent table.
  case unsupportedLayout(String)
  case writeFailed(String)

  public var errorDescription: String? {
    switch self {
    case .readOnly(let path): "\(path) is read-only, so nothing was changed."
    case .unreadable(let path): "\(path) could not be read as text, so nothing was changed."
    case .unsupportedLayout(let path):
      "\(path) sets up iMessage in a form this app does not edit. Nothing was changed."
    case .writeFailed(let path): "\(path) could not be saved. It was left as it was."
    }
  }
}

/// Edits one config file in place. The backup sits next to the file, the
/// file keeps its mode, and the new bytes replace the old in one rename, so a
/// crash leaves either the old file or the new one.
public enum ConfigFile {
  public static let backupSuffix = ".imessage-max-backup"

  public static func backup(of file: URL) -> URL {
    file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + backupSuffix)
  }

  /// `edit` gets the file's text, or nil when there is no file, and returns
  /// the text to save. `display` names the file in errors.
  public static func apply(
    _ file: URL, display: String, edit: (String?) throws -> String
  ) throws -> ConfigWrite {
    let target = file.resolvingSymlinksInPath()
    let manager = FileManager.default
    var original: Data?
    var mode: mode_t = 0o600
    if manager.fileExists(atPath: target.path) {
      guard let data = manager.contents(atPath: target.path), String(data: data, encoding: .utf8) != nil
      else { throw ConfigFileError.unreadable(display) }
      original = data
      if let bits = (try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber {
        mode = mode_t(bits.uint16Value & 0o7777)
      }
    }
    let text = original.map { String(decoding: $0, as: UTF8.self) }
    let updated = try edit(text)
    if updated == text { return .unchanged }
    let folder = target.deletingLastPathComponent()
    if original == nil, !manager.fileExists(atPath: folder.path) {
      do {
        try manager.createDirectory(
          at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      } catch { throw ConfigFileError.writeFailed(display) }
    }
    guard access(folder.path, W_OK) == 0, original == nil || access(target.path, W_OK) == 0 else {
      throw ConfigFileError.readOnly(display)
    }
    guard let original else {
      try write(Data(updated.utf8), to: target, mode: mode, display: display)
      return .created
    }
    let backup = backup(of: target)
    try write(original, to: backup, mode: mode, display: display)
    try write(Data(updated.utf8), to: target, mode: mode, display: display)
    return .updated(backup: backup)
  }

  /// Copies `file` to its backup with the same mode. Used before another
  /// program, such as a client's own CLI, edits the file.
  public static func saveBackup(of file: URL, display: String) throws -> URL? {
    let target = file.resolvingSymlinksInPath()
    guard let data = FileManager.default.contents(atPath: target.path) else { return nil }
    let bits = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions]
    let mode = (bits as? NSNumber).map { mode_t($0.uint16Value & 0o7777) } ?? 0o600
    let backup = backup(of: target)
    try write(data, to: backup, mode: mode, display: display)
    return backup
  }

  /// The file never exists with a wider mode than `mode`, even for a moment.
  private static func write(_ data: Data, to file: URL, mode: mode_t, display: String) throws {
    let temporary = file.deletingLastPathComponent()
      .appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).tmp")
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
    guard descriptor >= 0 else { throw ConfigFileError.writeFailed(display) }
    let written = data.withUnsafeBytes { buffer -> Bool in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
        if count <= 0 { return false }
        offset += count
      }
      return true
    }
    let settled = written && fchmod(descriptor, mode) == 0 && fsync(descriptor) == 0
    close(descriptor)
    guard settled, rename(temporary.path, file.path) == 0 else {
      unlink(temporary.path)
      throw ConfigFileError.writeFailed(display)
    }
  }
}
