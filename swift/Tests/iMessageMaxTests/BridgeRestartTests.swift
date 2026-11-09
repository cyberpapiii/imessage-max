import Darwin
import Foundation
import XCTest
@testable import iMessageMax

/// 088 #9 end to end: a real bridge process against a scratch helper
/// process (its own port, token file and socket) that is killed and started
/// again mid-session. The client never sends a second initialize.
///
/// Set IMESSAGE_MAX_BINARY to run it against the release binary.
final class BridgeRestartTests: XCTestCase {
    func testBridgeSessionSurvivesAHelperKillAndRestart() throws {
        signal(SIGPIPE, SIG_IGN)
        let folder = try makeShortTempFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let socketPath = "\(folder)/s.sock"

        let first = try ScratchProcess.helper(in: folder, socketPath: socketPath, log: "helper1.log")
        defer { first.kill() }
        let bridge = try ScratchProcess(
            arguments: ["--socket-path", socketPath], stderrFile: "\(folder)/bridge.log", pipesStdio: true)
        defer { bridge.kill() }

        bridge.send(initializeBody(id: 1, protocolVersion: "2025-11-25"))
        let initialized = try bridge.nextJSON()
        XCTAssertEqual(initialized["id"] as? Int, 1)
        XCTAssertNotNil(initialized["result"], "\(initialized)")
        bridge.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        bridge.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#)
        XCTAssertEqual(try toolCount(bridge.nextJSON(), id: 2), 13)

        first.kill()
        XCTAssertTrue(bridge.waitForStderr(containing: "reconnecting for up to 15 s"), bridge.stderr)
        // Sent while no helper is up, so it waits for the next one.
        bridge.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}"#)

        let second = try ScratchProcess.helper(in: folder, socketPath: socketPath, log: "helper2.log")
        defer { second.kill() }
        XCTAssertEqual(try toolCount(bridge.nextJSON(timeout: 20), id: 3), 13)
        XCTAssertTrue(second.stderr.contains("method=initialize"), second.stderr)
        XCTAssertTrue(second.stderr.contains("method=notifications/initialized"), second.stderr)
        XCTAssertTrue(bridge.stderr.contains("Reconnected to iMessage Max; replayed initialize"), bridge.stderr)

        bridge.send(#"{"jsonrpc":"2.0","id":4,"method":"tools/list","params":{}}"#)
        XCTAssertEqual(try toolCount(bridge.nextJSON(), id: 4), 13)
        bridge.closeInput()
        XCTAssertEqual(bridge.waitForExit(within: 10), 0, bridge.stderr)
    }

    private func toolCount(_ reply: [String: Any], id: Int, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        XCTAssertEqual(reply["id"] as? Int, id, "\(reply)", file: file, line: line)
        let tools = try XCTUnwrap((reply["result"] as? [String: Any])?["tools"] as? [Any], "\(reply)", file: file, line: line)
        return tools.count
    }
}

/// A spawned imessage-max: a scratch helper, or a bridge whose stdio the
/// test drives.
private final class ScratchProcess {
    private let process = Process()
    private let exited = DispatchSemaphore(value: 0)
    private let stderrURL: URL
    private var input: FileHandle?
    private var output: LineReader?

    static func helper(in folder: String, socketPath: String, log: String) throws -> ScratchProcess {
        let helper = try ScratchProcess(
            arguments: [
                "--http", "--port", String(try freeLoopbackPort()),
                "--token-file", "\(folder)/token",
                "--socket-path", socketPath,
                "--contacts-policy", "skip",
            ],
            stderrFile: "\(folder)/\(log)", pipesStdio: false)
        guard helper.waitForStderr(containing: "Socket listening path=", within: 10) else {
            throw SocketTestTimeout()
        }
        return helper
    }

    init(arguments: [String], stderrFile: String, pipesStdio: Bool) throws {
        stderrURL = URL(fileURLWithPath: stderrFile)
        FileManager.default.createFile(atPath: stderrFile, contents: nil)
        process.executableURL = try Self.binary()
        process.arguments = arguments
        process.standardError = try FileHandle(forWritingTo: stderrURL)
        if pipesStdio {
            let stdin = Pipe()
            let stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            input = stdin.fileHandleForWriting
            output = LineReader(stdout.fileHandleForReading.fileDescriptor)
        } else {
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
        }
        process.terminationHandler = { [exited] _ in exited.signal() }
        try process.run()
    }

    var stderr: String { (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? "" }

    func send(_ line: String) {
        guard let input else { return }
        writeLine(input.fileDescriptor, line)
    }

    func nextJSON(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        try XCTUnwrap(output, file: file, line: line).nextJSON(timeout: timeout, file: file, line: line)
    }

    func closeInput() {
        try? input?.close()
        input = nil
    }

    func waitForStderr(containing text: String, within seconds: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !stderr.contains(text) {
            guard Date() < deadline else { return false }
            _ = exited.wait(timeout: .now() + .milliseconds(20))
        }
        return true
    }

    /// The exit status, or nil while it still runs after `seconds`.
    func waitForExit(within seconds: TimeInterval) -> Int32? {
        guard exited.wait(timeout: .now() + seconds) == .success else { return nil }
        exited.signal()
        return process.terminationStatus
    }

    /// SIGKILL, the way a crash ends the helper. Waits for the exit.
    func kill() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
        _ = waitForExit(within: 10)
    }

    private static func binary() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["IMESSAGE_MAX_BINARY"] {
            return URL(fileURLWithPath: path)
        }
        let besideTests = Bundle(for: ScratchProcess.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("imessage-max")
        guard FileManager.default.isExecutableFile(atPath: besideTests.path) else {
            throw POSIXError(.ENOENT)
        }
        return besideTests
    }
}
