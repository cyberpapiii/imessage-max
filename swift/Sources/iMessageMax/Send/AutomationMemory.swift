import Darwin
import Foundation
import IMessageMaxContract
import Synchronization

/// The last definite answer macOS gave about Automation access to Messages.
/// macOS answers only while Messages runs, so diagnose reports this answer
/// while Messages is closed instead of starting Messages on every poll.
///
/// The file sits beside the token file, so a test helper with `--token-file`
/// never reads or writes the installed helper's answer. Without a folder
/// (stdio `--direct`) the answer lives in memory only.
final class AutomationMemory: Sendable {
    static let definite: Set<PermissionStatus> = [.authorized, .denied, .notDetermined]
    private static let maxFileBytes = 64

    let file: URL?
    private let current: Mutex<PermissionStatus?>

    init(folder: URL?) {
        file = folder?.appendingPathComponent(ServiceDefaults.automationAnswerFileName)
        current = Mutex(file.flatMap(Self.read))
    }

    var answer: PermissionStatus? { current.withLock { $0 } }

    /// Keeps a definite answer and ignores any other word. Writes the file
    /// only when the answer changes.
    func remember(_ status: PermissionStatus) {
        guard Self.definite.contains(status) else { return }
        let changed = current.withLock { stored in
            defer { stored = status }
            return stored != status
        }
        guard changed, let file else { return }
        do {
            try Data((status.rawValue + "\n").utf8).write(to: file, options: [.atomic])
            chmod(file.path, 0o600)
        } catch {
            Log.warning("Could not save the Automation answer: \(error.localizedDescription)")
        }
    }

    private static func read(_ file: URL) -> PermissionStatus? {
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_size <= maxFileBytes,
              let data = FileManager.default.contents(atPath: file.path)
        else { return nil }
        let word = PermissionStatus(
            rawValue: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        return definite.contains(word) ? word : nil
    }
}
