import Foundation
import Synchronization

/// stderr diagnostics. stdout is the MCP stdio channel and must stay clean.
enum Log {
    enum Level: String { case info = "INFO", warning = "WARN", error = "ERROR" }

    /// Each line leads with a UTC timestamp: launchd writes stderr straight to
    /// a file, so nothing else records when a line was written.
    static func format(_ level: Level, _ message: String, at date: Date = Date()) -> String {
        "\(date.formatted(timestampStyle)) [imessage-max] \(level.rawValue) \(message)\n"
    }

    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Where a task tree's lines go instead of stderr while bound, so a test
    /// can read the lines its own calls wrote.
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

    static func info(_ message: @autoclosure () -> String) { write(.info, message()) }
    static func warning(_ message: @autoclosure () -> String) { write(.warning, message()) }
    static func error(_ message: @autoclosure () -> String) { write(.error, message()) }

    /// Client-supplied strings are untrusted: strip control characters (an
    /// embedded newline would forge a whole log line) and clamp the length.
    static func sanitizedField(_ value: String, maxLength: Int = 64) -> String {
        String(value.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .prefix(maxLength)
            .map(Character.init))
    }
}
