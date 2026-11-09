import Darwin
import Foundation
import XCTest
@testable import iMessageMax

/// The helper's socket must come back by itself: a cleanup script or a user
/// that deletes the file, or another helper that held the path at launch,
/// otherwise leaves stdio bridges unable to connect until a restart (088 #32).
final class SocketSupervisorTests: XCTestCase {
    private var folder: String!
    private var socket: SocketPath!
    private var supervisors: [SocketSupervisor] = []
    private var clients: [Int32] = []

    private let echo: SocketListener.Serve = { transport in
        do {
            try await transport.connect()
            for try await message in await transport.receive() {
                try await transport.send(message)
            }
        } catch {}
        await transport.disconnect()
    }

    override func setUpWithError() throws {
        folder = try makeShortTempFolder()
        socket = try testSocketPath(in: folder)
    }

    override func tearDown() async throws {
        clients.forEach { close($0) }
        for supervisor in supervisors {
            await supervisor.stop()
        }
        try? FileManager.default.removeItem(atPath: folder)
    }

    private func supervise(interval: Duration = .milliseconds(100)) async -> SocketSupervisor {
        let supervisor = await SocketSupervisor.start(at: socket, interval: interval, serve: echo)
        supervisors.append(supervisor)
        return supervisor
    }

    private func client() throws -> LineReader {
        let fd = try connectClient(socket)
        clients.append(fd)
        return LineReader(fd)
    }

    private func assertEchoes(_ reader: LineReader, _ line: String, file: StaticString = #filePath, line number: UInt = #line) throws {
        writeLine(reader.fd, line)
        XCTAssertEqual(try reader.nextLine(), line, file: file, line: number)
    }

    private func waitForSocketFile(within seconds: Double = 5) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        var info = stat()
        while ContinuousClock.now < deadline {
            if lstat(socket.path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK { return true }
            await AsyncTimeout.sleep(.milliseconds(20))
        }
        return false
    }

    func testTheTimerRecreatesADeletedSocketFile() async throws {
        _ = await supervise()
        try assertEchoes(try client(), #"{"before":"delete"}"#)

        XCTAssertEqual(unlink(socket.path), 0)
        let recreated = await waitForSocketFile()
        XCTAssertTrue(recreated, "the supervisor never listened again")
        try assertEchoes(try client(), #"{"after":"delete"}"#)
    }

    /// Checks run by hand here, so the log capture, a task local, sees them.
    func testACheckAfterTheFileVanishedListensAgainAndKeepsOpenSessions() async throws {
        let capture = Log.Capture()
        try await Log.$capture.withValue(capture) {
            let supervisor = await supervise(interval: .seconds(3600))
            let open = try client()
            try assertEchoes(open, #"{"before":"delete"}"#)
            await supervisor.check()
            XCTAssertTrue(capture.lines.isEmpty, "a check with the file in place does nothing: \(capture.lines)")

            XCTAssertEqual(unlink(socket.path), 0)
            await supervisor.check()

            try assertEchoes(try client(), #"{"after":"delete"}"#)
            try assertEchoes(open, #"{"open":"session"}"#)
        }
        XCTAssertTrue(capture.lines.contains { $0.contains("disappeared; listening on it again") }, "\(capture.lines)")
    }

    func testAPathHeldByAnotherHelperIsTakenOnceItLeaves() async throws {
        let other = try await SocketListener.start(at: socket, serve: echo)
        let supervisor = await supervise()
        XCTAssertFalse(supervisor.isListening, "a live helper's socket must not be taken")

        await other.stop()
        let deadline = ContinuousClock.now + .seconds(5)
        while !supervisor.isListening, ContinuousClock.now < deadline {
            await AsyncTimeout.sleep(.milliseconds(20))
        }
        XCTAssertTrue(supervisor.isListening)
        try assertEchoes(try client(), #"{"took":"over"}"#)
    }

    func testARepeatedFailureIsLoggedOnce() async throws {
        try "keep me".write(toFile: socket.path, atomically: false, encoding: .utf8)
        let capture = Log.Capture()
        await Log.$capture.withValue(capture) {
            let supervisor = await supervise(interval: .seconds(3600))
            await supervisor.check()
            await supervisor.check()
            XCTAssertFalse(supervisor.isListening)
        }
        XCTAssertEqual(capture.lines.filter { $0.contains("stdio bridges cannot connect") }.count, 1, "\(capture.lines)")
        XCTAssertEqual(try String(contentsOfFile: socket.path, encoding: .utf8), "keep me")
    }

    func testStopRemovesTheSocketAndEndsChecking() async throws {
        let supervisor = await supervise(interval: .milliseconds(20))
        await supervisor.stop()
        var info = stat()
        XCTAssertEqual(lstat(socket.path, &info), -1, "stop leaves no socket file")
        await AsyncTimeout.sleep(.milliseconds(100))
        XCTAssertEqual(lstat(socket.path, &info), -1, "a check after stop listened again")
    }
}
