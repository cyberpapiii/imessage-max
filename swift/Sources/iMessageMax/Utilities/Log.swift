import Foundation
import Synchronization

/// stderr diagnostics. stdout is the MCP stdio channel and must stay clean.
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
