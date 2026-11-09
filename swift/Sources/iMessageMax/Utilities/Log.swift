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
        writeLine(format(level, message()), to: STDERR_FILENO)
    }

    /// Writes `line` to `fd` and never fails. `FileHandle.write(_: Data)`
    /// raises an Objective-C exception on any write error, which aborts the
    /// helper, and launchd then relaunches it into the same full disk or
    /// closed stderr every 10 s. A line that cannot be written is dropped.
    static func writeLine(_ line: String, to fd: Int32) {
        var line = line
        line.withUTF8 { bytes in
            guard var next = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let written = Darwin.write(fd, next, remaining)
                if written > 0 {
                    next += written
                    remaining -= written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    /// The size above which the log moves to `<path>.1`.
    static let rotationThreshold = 10 * 1024 * 1024

    /// Points stderr at `path`, appending, so launchd needs no StandardErrorPath.
    /// A leading `~` expands here because launchd passes arguments verbatim.
    /// A file that cannot be opened leaves stderr where it was and says why
    /// there: the helper runs under KeepAlive, and exiting would only loop.
    static func redirectStandardError(to path: String, rotateAbove threshold: Int = rotationThreshold) {
        do {
            try reopen(path, rotateAbove: threshold)
        } catch {
            warning("Could not open the log file \(expanded(path)), so logging stays on stderr: \(error.localizedDescription)")
        }
    }

    /// Moves a log over `threshold` to `<path>.1`, then opens `path` and puts
    /// it on stderr with dup2, which swaps the descriptor in one step. A line
    /// being written at that moment lands whole in one file or the other, so
    /// `writeLine` needs no lock.
    private static func reopen(_ path: String, rotateAbove threshold: Int) throws {
        let url = URL(fileURLWithPath: expanded(path))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var info = stat()
        if stat(url.path, &info) == 0, Int(info.st_size) > threshold {
            // rename(2) replaces an older .1 in one step.
            guard rename(url.path, url.path + ".1") == 0 else { throw posixError() }
        }
        let file = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw posixError() }
        defer { close(file) }
        guard fchmod(file, 0o600) == 0, dup2(file, STDERR_FILENO) >= 0 else { throw posixError() }
    }

    private static func expanded(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    private static let rotationTimer = Mutex<DispatchSourceTimer?>(nil)
    private static let rotationFailing = Mutex(false)

    /// Checks the log's size every `interval` and rotates it past
    /// `threshold` (088 #31: the log rotated only at startup, so a helper
    /// that ran for months grew it without bound). A Dispatch timer, because
    /// sleeping Swift tasks abort inside the launchd-run service.
    static func rotatePeriodically(
        _ path: String,
        above threshold: Int = rotationThreshold,
        every interval: DispatchTimeInterval = .seconds(60)
    ) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.cyberpapiii.imessage-max.log-rotation", qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { rotateIfNeeded(path, above: threshold) }
        rotationTimer.withLock { current in
            current?.cancel()
            current = timer
        }
        timer.resume()
    }

    static func stopRotating() {
        rotationTimer.withLock { current in
            current?.cancel()
            current = nil
        }
    }

    /// Rotates when stderr has grown past `threshold`. It measures stderr
    /// itself, and reopens `path` when stderr is no longer the file there,
    /// so a log someone deleted or moved is put back on the next check. A
    /// failure is logged once, not on every check.
    static func rotateIfNeeded(_ path: String, above threshold: Int) {
        var current = stat()
        guard fstat(STDERR_FILENO, &current) == 0, (current.st_mode & S_IFMT) == S_IFREG else { return }
        var named = stat()
        let replaced = stat(expanded(path), &named) != 0
            || named.st_ino != current.st_ino || named.st_dev != current.st_dev
        guard Int(current.st_size) > threshold || replaced else { return }
        do {
            try reopen(path, rotateAbove: threshold)
            rotationFailing.withLock { $0 = false }
        } catch {
            let first = rotationFailing.withLock { failing in
                defer { failing = true }
                return !failing
            }
            if first {
                warning("Could not rotate the log file \(expanded(path)), so it keeps growing: \(error.localizedDescription)")
            }
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
