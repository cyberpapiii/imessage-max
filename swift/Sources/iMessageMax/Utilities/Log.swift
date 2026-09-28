import Foundation

/// stderr diagnostics. stdout is the MCP stdio channel and must stay clean.
enum Log {
    enum Level: String { case info = "INFO", warning = "WARN", error = "ERROR" }

    /// Each line leads with a UTC timestamp: launchd writes stderr straight to
    /// a file, so nothing else records when a line was written.
    static func format(_ level: Level, _ message: String, at date: Date = Date()) -> String {
        "\(date.formatted(timestampStyle)) [imessage-max] \(level.rawValue) \(message)\n"
    }

    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func write(_ level: Level, _ message: @autoclosure () -> String) {
        FileHandle.standardError.write(Data(format(level, message()).utf8))
    }

    static func info(_ message: @autoclosure () -> String) { write(.info, message()) }
    static func warning(_ message: @autoclosure () -> String) { write(.warning, message()) }
    static func error(_ message: @autoclosure () -> String) { write(.error, message()) }
}
