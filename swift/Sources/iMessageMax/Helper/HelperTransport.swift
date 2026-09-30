import Foundation

/// Abstraction over the byte round-trip to the injected helper. Production uses
/// UnixSocketTransport; tests inject a stub. Mirrors how ScriptRunning abstracts
/// osascript.
protocol HelperTransport: Sendable {
    /// Writes one framed request line and returns exactly one response line
    /// (trailing newline stripped). Throws HelperError.notConnected/.timeout.
    func roundTrip(_ request: Data, timeout: TimeInterval) async throws -> Data
    func isConnected() async -> Bool
}
