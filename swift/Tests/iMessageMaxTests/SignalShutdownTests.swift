import Darwin
import Foundation
import IMessageMaxContract
import XCTest
@testable import iMessageMax

/// launchd, logout and SMAppService stop the HTTP service with SIGTERM. A
/// clean stop must end in a plain exit, never an abort, which leaves a crash
/// report (#27). The exit code carries the Keep running setting: 0 while the
/// stay-stopped file sits beside the token, so launchd leaves the helper
/// down, and `KeepRunning.relaunchExitCode` otherwise, so launchd starts it
/// again. SIGUSR1 drains the same way and always exits 0, so the cask's
/// uninstall leaves the helper down.
///
/// The abort only showed in optimized builds, so CI and `make release-check`
/// also run this class with IMESSAGE_MAX_BINARY set to the release binary.
final class SignalShutdownTests: XCTestCase {
    /// launchd sends SIGKILL once a job outlives the agent plist's 20 s
    /// ExitTimeOut. Without that key launchd allows only 5 s.
    private static let launchdExitTimeout: TimeInterval = 20

    func testIdleServerExitsZeroOnSIGTERM() throws {
        let server = try SpawnedServer()
        try server.terminate(within: 5)
    }

    func testWithoutTheStayStoppedFileSIGTERMExitsWithTheRelaunchCode() throws {
        let server = try SpawnedServer(stayStopped: false)
        try server.terminate(within: 5, expecting: KeepRunning.relaunchExitCode)
        XCTAssertTrue(server.stderr.contains("Stopped exit=\(KeepRunning.relaunchExitCode)"), server.stderr)
    }

    /// `brew uninstall --cask` sends SIGUSR1, and the helper must stay down
    /// even with Keep running on, or launchd relaunches it from the deleted
    /// app (088 #5).
    func testSIGUSR1ExitsZeroEvenWithKeepRunningOn() throws {
        let server = try SpawnedServer(stayStopped: false)
        try server.terminate(within: 5, expecting: 0, signal: GracefulStop.signal)
        XCTAssertTrue(server.stderr.contains("Received SIGUSR1"), server.stderr)
        XCTAssertTrue(server.stderr.contains("Stopped exit=0"), server.stderr)
    }

    func testSIGUSR1DrainsAnOpenSSEStreamAndRemovesTheSocket() throws {
        let server = try SpawnedServer(stayStopped: false)
        XCTAssertTrue(server.waitForStderr(containing: "Socket listening path="), server.stderr)
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

        try server.terminate(within: 5, expecting: 0, signal: GracefulStop.signal)
        var info = stat()
        XCTAssertEqual(lstat(server.socketPath, &info), -1, "the socket outlived a SIGUSR1 stop")
    }

    /// The companion's toggle reaches a running helper, with no restart.
    func testTheSettingIsReadWhenTheServerStops() throws {
        let turnedOff = try SpawnedServer(stayStopped: false)
        try turnedOff.setStayStopped(true)
        try turnedOff.terminate(within: 5)

        let turnedOn = try SpawnedServer()
        try turnedOn.setStayStopped(false)
        try turnedOn.terminate(within: 5, expecting: KeepRunning.relaunchExitCode)
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

/// Another process on the helper's port, such as another user's helper,
/// must not put the helper into a launchd relaunch loop that takes the
/// stdio socket down too (088 #10). The helper logs the taken port once,
/// keeps the socket serving, and binds once the port frees.
final class PortInUseTests: XCTestCase {
    func testASecondHelperOnATakenPortServesItsSocketAndBindsOnceThePortFrees() throws {
        let first = try SpawnedServer()
        let second = try SpawnedServer(port: first.port, waitsForHTTP: false)
        let inUse = "HTTP port \(first.port) on 127.0.0.1 is in use by another process"
        XCTAssertTrue(second.waitForStderr(containing: inUse), second.stderr)
        XCTAssertTrue(second.waitForStderr(containing: "Socket listening path="), second.stderr)
        let log = second.stderr
        let started = try XCTUnwrap(log.range(of: StartupFailure.startedMarker), log)
        XCTAssertLessThan(try XCTUnwrap(log.range(of: inUse)).lowerBound, started.lowerBound,
                          "Started must follow the bind outcome: \(log)")
        XCTAssertTrue(log.contains("transport=http addr=127.0.0.1:\(first.port) http=port_in_use"), log)

        let waiting = try diagnoseOverSocket(second.socketPath)
        XCTAssertEqual(waiting["state"] as? String, "port_in_use", "\(waiting)")
        XCTAssertEqual(waiting["port"] as? Int, first.port)
        XCTAssertNotNil(waiting["fix"], "\(waiting)")

        // Past the first retries: still up, and the line was logged once.
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertTrue(second.isRunning, second.stderr)
        XCTAssertEqual(second.stderr.components(separatedBy: inUse).count - 1, 1, second.stderr)

        try first.terminate(within: 5)
        XCTAssertTrue(
            second.waitForStderr(containing: "HTTP listening addr=127.0.0.1:\(first.port); the port is free again", within: 40),
            second.stderr)
        _ = try initializeSession(port: second.port, authorization: second.authorization)
        XCTAssertEqual(try diagnoseOverSocket(second.socketPath)["state"] as? String, "listening")
        try second.terminate(within: 5)
    }

    func testSIGTERMWhileTheHelperWaitsForATakenPortExitsCleanly() throws {
        let holder = try HeldPort()
        defer { holder.release() }
        let server = try SpawnedServer(port: holder.port, waitsForHTTP: false)
        XCTAssertTrue(server.waitForStderr(containing: "HTTP port \(holder.port) on 127.0.0.1 is in use"), server.stderr)
        try server.terminate(within: 5)
        XCTAssertTrue(server.stderr.contains("Stopped exit=0"), server.stderr)
    }

    /// A helper that cannot start logs why in the line the companion reads,
    /// so it shows the reason instead of "Stopped" (088 #15).
    func testAStartupFailureLogsTheReasonTheCompanionReads() throws {
        let folder = "/private/tmp/imax-missing-\(UUID().uuidString)"
        let result = try SpawnedServer.runToExit([
            "--http", "--port", String(try freeLoopbackPort()),
            "--token-file", "\(folder)/token", "--contacts-policy", "skip",
        ])
        XCTAssertNotEqual(result.status, 0, result.stderr)
        let reason = try XCTUnwrap(StartupFailure.reason(inLog: result.stderr), result.stderr)
        XCTAssertTrue(reason.contains(folder), reason)
    }

    /// diagnose's `http` field, asked over the helper's socket on the
    /// stateless lane, as a stdio bridge would.
    private func diagnoseOverSocket(_ path: String) throws -> [String: Any] {
        let fd = try connectClient(SocketPath.resolve(override: path))
        defer { close(fd) }
        let reader = LineReader(fd)
        writeLine(fd, modernBody(method: "tools/call", params: #""name":"diagnose","arguments":{}"#))
        let reply = try reader.nextJSON(timeout: 30)
        let result = try XCTUnwrap(reply["result"] as? [String: Any], "\(reply)")
        let content = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String, "\(reply)")
        let diagnosis = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        return try XCTUnwrap(diagnosis["http"] as? [String: Any], "\(diagnosis)")
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

    /// `prepare` runs before launch with the socket path. `stayStopped`
    /// writes the Keep running opt-out beside the token, so SIGTERM exits 0.
    /// `port` nil picks a free one. With `waitsForHTTP` false, init returns
    /// once the server logs its start, whether or not it holds the port.
    init(
        stayStopped: Bool = true, port: Int? = nil, waitsForHTTP: Bool = true,
        prepare: (String) throws -> Void = { _ in }
    ) throws {
        // Short, so the socket path fits sun_path.
        folder = URL(fileURLWithPath: try makeShortTempFolder())
        socketPath = folder.appendingPathComponent("s.sock").path
        try prepare(socketPath)
        try Self.setStayStopped(stayStopped, in: folder)
        let tokenURL = folder.appendingPathComponent("token")
        stderrURL = folder.appendingPathComponent("stderr.log")
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        self.port = try port ?? freeLoopbackPort()
        process.executableURL = try Self.binary()
        process.arguments = [
            "--http", "--port", String(self.port),
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
            if waitsForHTTP, let fd = try? connectLoopback(port: self.port) {
                close(fd)
                break
            }
            if !waitsForHTTP, Self.tail(stderrURL, lines: .max).contains(StartupFailure.startedMarker) { break }
            guard process.isRunning, Date() < deadline else {
                throw SpawnError("server never started on \(self.port): \(Self.tail(stderrURL))")
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

    func setStayStopped(_ on: Bool) throws { try Self.setStayStopped(on, in: folder) }

    private static func setStayStopped(_ on: Bool, in folder: URL) throws {
        let marker = folder.appendingPathComponent(ServiceDefaults.stayStoppedFileName)
        if on {
            try Data().write(to: marker)
        } else if FileManager.default.fileExists(atPath: marker.path) {
            try FileManager.default.removeItem(at: marker)
        }
    }

    @discardableResult
    func terminate(
        within seconds: TimeInterval, expecting status: Int32 = 0, signal: Int32 = SIGTERM,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> TimeInterval {
        let start = Date()
        kill(process.processIdentifier, signal)
        guard exited.wait(timeout: .now() + seconds) == .success else {
            throw SpawnError("server still running \(seconds) s after signal \(signal): \(Self.tail(stderrURL))")
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(process.terminationReason, .exit, "server died by signal \(process.terminationStatus) after \(elapsed) s: \(Self.tail(stderrURL))", file: file, line: line)
        XCTAssertEqual(process.terminationStatus, status, "server exited \(process.terminationStatus) after \(elapsed) s: \(Self.tail(stderrURL))", file: file, line: line)
        return elapsed
    }

    var stderr: String { (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? "" }

    var isRunning: Bool { process.isRunning }

    func waitForStderr(containing text: String, within seconds: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !stderr.contains(text) {
            guard Date() < deadline else { return false }
            _ = exited.wait(timeout: .now() + .milliseconds(20))
        }
        return true
    }

    /// Runs the server binary with `arguments` until it exits by itself.
    static func runToExit(_ arguments: [String], within seconds: TimeInterval = 10) throws -> (status: Int32, stderr: String) {
        let process = Process()
        let exited = DispatchSemaphore(value: 0)
        let errors = Pipe()
        process.executableURL = try binary()
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        guard exited.wait(timeout: .now() + seconds) == .success else {
            kill(process.processIdentifier, SIGKILL)
            throw SpawnError("server still running after \(seconds) s")
        }
        let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, text)
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

    private static func tail(_ url: URL, lines: Int = 5) -> String {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }
}

private struct SpawnError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
