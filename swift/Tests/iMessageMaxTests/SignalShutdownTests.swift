import Darwin
import Foundation
import XCTest

/// launchd, logout and SMAppService stop the HTTP service with SIGTERM. A
/// clean stop must exit 0: launchd counts any other ending as a crash, and
/// an abort also leaves a crash report (#27).
///
/// The abort only showed in optimized builds, so CI and `make release-check`
/// also run this class with IMESSAGE_MAX_BINARY set to the release binary.
final class SignalShutdownTests: XCTestCase {
    /// launchd sends SIGKILL once a job outlives its 20 s default ExitTimeOut.
    private static let launchdExitTimeout: TimeInterval = 20

    func testIdleServerExitsZeroOnSIGTERM() throws {
        let server = try SpawnedServer()
        try server.terminate(within: 5)
    }

    func testServerWithAnOpenSSEStreamExitsZeroOnSIGTERM() throws {
        let server = try SpawnedServer()
        let session = try initializeSession(port: server.port, authorization: server.authorization)
        let stream = try connectLoopback(port: server.port)
        defer { close(stream) }
        setRecvTimeout(stream, seconds: 5)
        try writeAll(stream, """
            GET / HTTP/1.1\r\n\
            Host: 127.0.0.1\r\n\
            Authorization: \(server.authorization)\r\n\
            Accept: text/event-stream\r\n\
            Mcp-Session-Id: \(session)\r\n\
            \r\n
            """)
        let head = try readUntilDoubleCRLF(stream)
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200"), "SSE stream did not open: \(head)")

        try server.terminate(within: 5)
    }

    /// A request whose body never finishes holds the graceful drain open, so
    /// the server must end it with its own shutdown bound before launchd
    /// escalates to SIGKILL.
    func testServerHoldingAnUnfinishedRequestExitsZeroBeforeLaunchdTimesOut() throws {
        let server = try SpawnedServer()
        let request = try connectLoopback(port: server.port)
        defer { close(request) }
        try writeAll(request, """
            POST / HTTP/1.1\r\n\
            Host: 127.0.0.1\r\n\
            Authorization: \(server.authorization)\r\n\
            Content-Type: application/json\r\n\
            Accept: application/json, text/event-stream\r\n\
            Content-Length: 4096\r\n\
            \r\n\
            {"jsonrpc":
            """)
        // A connection whose head the server has not read yet is idle, and
        // the drain closes it at once.
        Thread.sleep(forTimeInterval: 0.5)

        let elapsed = try server.terminate(within: Self.launchdExitTimeout)
        XCTAssertGreaterThan(elapsed, 5, "the unfinished request never held the drain open")
    }
}

/// The helper's socket is best effort: it must never stop HTTP, and a clean
/// stop removes it.
final class HelperSocketTests: XCTestCase {
    func testRegularFileAtTheSocketPathLeavesHTTPServingWithAWarning() throws {
        let server = try SpawnedServer { socketPath in
            try "keep me".write(toFile: socketPath, atomically: false, encoding: .utf8)
        }
        _ = try initializeSession(port: server.port, authorization: server.authorization)
        XCTAssertTrue(
            server.waitForStderr(containing: "Serving HTTP only; stdio bridges cannot connect."),
            server.stderr)

        try server.terminate(within: 5)
        XCTAssertEqual(try String(contentsOfFile: server.socketPath, encoding: .utf8), "keep me")
    }

    func testSIGTERMRemovesTheSocket() throws {
        let server = try SpawnedServer()
        XCTAssertTrue(server.waitForStderr(containing: "Socket listening path="), server.stderr)
        var info = stat()
        XCTAssertEqual(lstat(server.socketPath, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)

        try server.terminate(within: 5)
        XCTAssertEqual(lstat(server.socketPath, &info), -1, "the socket outlived a clean stop")
    }
}

private final class SpawnedServer {
    let port: Int
    let authorization: String
    /// In a fresh mkdtemp folder, so a test never binds the user's real socket.
    let socketPath: String
    private let process = Process()
    private let exited = DispatchSemaphore(value: 0)
    private let folder: URL
    private let stderrURL: URL

    /// `prepare` runs before launch with the socket path.
    init(prepare: (String) throws -> Void = { _ in }) throws {
        // Short, so the socket path fits sun_path.
        folder = URL(fileURLWithPath: try makeShortTempFolder())
        socketPath = folder.appendingPathComponent("s.sock").path
        try prepare(socketPath)
        let tokenURL = folder.appendingPathComponent("token")
        stderrURL = folder.appendingPathComponent("stderr.log")
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        port = try freeLoopbackPort()
        process.executableURL = try Self.binary()
        process.arguments = [
            "--http", "--port", String(port),
            "--token-file", tokenURL.path,
            "--socket-path", socketPath,
            "--contacts-policy", "skip",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: stderrURL)
        process.terminationHandler = { [exited] _ in exited.signal() }
        try process.run()

        let deadline = Date().addingTimeInterval(10)
        while true {
            if let fd = try? connectLoopback(port: port) {
                close(fd)
                break
            }
            guard process.isRunning, Date() < deadline else {
                throw SpawnError("server never listened on \(port): \(Self.tail(stderrURL))")
            }
            _ = exited.wait(timeout: .now() + .milliseconds(20))
        }
        let token = try String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        authorization = "Bearer \(token)"
    }

    deinit {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    func terminate(within seconds: TimeInterval, file: StaticString = #filePath, line: UInt = #line) throws -> TimeInterval {
        let start = Date()
        kill(process.processIdentifier, SIGTERM)
        guard exited.wait(timeout: .now() + seconds) == .success else {
            throw SpawnError("server still running \(seconds) s after SIGTERM: \(Self.tail(stderrURL))")
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(process.terminationReason, .exit, "server died by signal \(process.terminationStatus) after \(elapsed) s: \(Self.tail(stderrURL))", file: file, line: line)
        XCTAssertEqual(process.terminationStatus, 0, "server exited \(process.terminationStatus) after \(elapsed) s: \(Self.tail(stderrURL))", file: file, line: line)
        return elapsed
    }

    var stderr: String { (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? "" }

    func waitForStderr(containing text: String, within seconds: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !stderr.contains(text) {
            guard Date() < deadline else { return false }
            _ = exited.wait(timeout: .now() + .milliseconds(20))
        }
        return true
    }

    private static func binary() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["IMESSAGE_MAX_BINARY"] {
            return URL(fileURLWithPath: path)
        }
        let besideTests = Bundle(for: SpawnedServer.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("imessage-max")
        guard FileManager.default.isExecutableFile(atPath: besideTests.path) else {
            throw SpawnError("no imessage-max binary at \(besideTests.path); set IMESSAGE_MAX_BINARY")
        }
        return besideTests
    }

    private static func tail(_ url: URL) -> String {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").suffix(5).joined(separator: "\n")
    }
}

private struct SpawnError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
