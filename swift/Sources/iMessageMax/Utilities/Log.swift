import Foundation
import Synchronization

/// Writes diagnostics to stderr. stdout is the MCP stdio channel and must stay clean.
enum Log {
    enum Level: String { case info = "INFO", warning = "WARN", error = "ERROR" }

    static func format(_ level: Level, _ message: String, at date: Date = Date()) -> String {
        "\(date.formatted(timestampStyle)) [imessage-max] \(level.rawValue) \(message)\n"
    }

    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    @TaskLocal static var capture: Capture?

    final class Capture: Sendable {
        private let storage = Mutex<[String]>([])

        var lines: [String] { storage.withLock { $0 } }

        fileprivate func append(_ line: String) {
            storage.withLock { $0.append(line) }
        }
    }

    static func write(_ level: Level, _ message: @autoclosure () -> String) {
        if let capture {
            capture.append(message())
            return
        }
        FileHandle.standardError.write(Data(format(level, message()).utf8))
    }

    /// The size above which the log moves to `<path>.1` when the helper starts.
    static let rotationThreshold = 10 * 1024 * 1024

    /// Points stderr at `path`, appending, so launchd needs no StandardErrorPath.
    /// A leading `~` expands here because launchd passes arguments verbatim.
    /// A file that cannot be opened leaves stderr where it was and says why
    /// there: the helper runs under KeepAlive, and exiting would only loop.
    static func redirectStandardError(to path: String, rotateAbove threshold: Int = rotationThreshold) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > threshold {
                // rename(2) replaces an older .1 in one step.
                guard rename(url.path, url.path + ".1") == 0 else { throw posixError() }
            }
            let file = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
            guard file >= 0 else { throw posixError() }
            defer { close(file) }
            guard fchmod(file, 0o600) == 0, dup2(file, STDERR_FILENO) >= 0 else { throw posixError() }
        } catch {
            warning("Could not open the log file \(url.path), so logging stays on stderr: \(error.localizedDescription)")
        }
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    static func info(_ message: @autoclosure () -> String) { write(.info, message()) }
    static func warning(_ message: @autoclosure () -> String) { write(.warning, message()) }
    static func error(_ message: @autoclosure () -> String) { write(.error, message()) }

    static func sanitizedField(_ value: String, maxLength: Int = 64) -> String {
        String(value.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .prefix(maxLength)
            .map(Character.init))
    }
}
