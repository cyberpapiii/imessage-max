import Darwin
import Foundation
import XCTest
@testable import iMessageMax

final class SocketListenerTests: XCTestCase {
    private var folder: String!
    private var socket: SocketPath!
    private var listeners: [SocketListener] = []
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
        for listener in listeners {
            await listener.stop()
        }
        try? FileManager.default.removeItem(atPath: folder)
    }

    private func start(peerPolicy: @escaping SocketListener.PeerPolicy = SocketListener.sameUser, serve: SocketListener.Serve? = nil) throws -> SocketListener {
        let listener = try SocketListener.start(at: socket, peerPolicy: peerPolicy, serve: serve ?? echo)
        listeners.append(listener)
        return listener
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

    func testSocketFileIsAPrivateSocket() throws {
        _ = try start()
        var info = stat()
        XCTAssertEqual(lstat(socket.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    func testStaleSocketLeftByACrashIsReclaimed() throws {
        let stale = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertEqual(socket.withAddress { Darwin.bind(stale, $0, $1) }, 0)
        close(stale)
        var info = stat()
        XCTAssertEqual(lstat(socket.path, &info), 0, "the stale socket file is still there")

        _ = try start()
        try assertEchoes(try client(), #"{"after":"reclaim"}"#)
    }

    func testRegularFileAtThePathIsLeftAlone() throws {
        try "keep me".write(toFile: socket.path, atomically: false, encoding: .utf8)

        XCTAssertThrowsError(try start()) { error in
            XCTAssertEqual(error as? SocketSetupError, .notASocket(path: socket.path))
        }
        XCTAssertEqual(try String(contentsOfFile: socket.path, encoding: .utf8), "keep me")
    }

    func testLiveListenerAtThePathGivesInUse() throws {
        _ = try start()

        XCTAssertThrowsError(try start()) { error in
            XCTAssertEqual(error as? SocketSetupError, .inUse(path: socket.path))
        }
        try assertEchoes(try client(), #"{"first":"still serves"}"#)
    }

    func testTwoClientsAreServedIndependently() throws {
        _ = try start()
        let first = try client()
        let second = try client()

        writeLine(first.fd, "a1")
        writeLine(second.fd, "b1")
        writeLine(first.fd, "a2")
        writeLine(second.fd, "b2")

        XCTAssertEqual(try first.nextLine(), "a1")
        XCTAssertEqual(try first.nextLine(), "a2")
        XCTAssertEqual(try second.nextLine(), "b1")
        XCTAssertEqual(try second.nextLine(), "b2")
    }

    func testPeerOfAnotherUserIsClosedBeforeServe() async throws {
        let served = expectation(description: "serve was called")
        served.isInverted = true
        _ = try start(peerPolicy: { _ in false }) { _ in served.fulfill() }

        let reader = try client()
        writeLine(reader.fd, "hello")
        XCTAssertNil(try reader.nextLine(), "the rejected client reads EOF")
        await fulfillment(of: [served], timeout: 0.3)
    }

    func testStopUnlinksTheSocketEndsSessionsAndIsIdempotent() async throws {
        let listener = try start()
        let reader = try client()
        try assertEchoes(reader, "ping")

        await listener.stop()

        var info = stat()
        XCTAssertEqual(lstat(socket.path, &info), -1)
        XCTAssertEqual(errno, ENOENT)
        XCTAssertNil(try reader.nextLine(), "a live client reads EOF")
        await listener.stop()
    }

    func testStopLeavesASocketSomeoneElseBoundAtThePath() async throws {
        let listener = try start()
        XCTAssertEqual(unlink(socket.path), 0)
        let other = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(other) }
        XCTAssertEqual(socket.withAddress { Darwin.bind(other, $0, $1) }, 0)

        await listener.stop()

        var info = stat()
        XCTAssertEqual(lstat(socket.path, &info), 0, "stop must not unlink a socket it did not bind")
    }
}

final class SocketPathTests: XCTestCase {
    func testStandardPathFitsUnderTheHome() throws {
        let resolved = try SocketPath.resolve(override: nil, home: "/Users/rob", userTempDir: "/var/folders/ab/cd/T/")
        XCTAssertEqual(resolved.path, "/Users/rob/Library/Application Support/iMessage Max/mcp.sock")
        XCTAssertEqual(resolved.folderRule, .ensurePrivate)
    }

    func testLongHomeFallsBackToTheUserTempFolder() throws {
        let home = "/Volumes/External/Users/" + String(repeating: "h", count: 40)
        let resolved = try SocketPath.resolve(override: nil, home: home, userTempDir: "/var/folders/ab/cd/T/")
        XCTAssertEqual(resolved.path, "/var/folders/ab/cd/T/imessage-max.sock")
        XCTAssertEqual(resolved.folderRule, .requireOwned)
    }

    func testNeitherLocationFittingIsPathTooLong() {
        let home = "/" + String(repeating: "h", count: 80)
        XCTAssertThrowsError(try SocketPath.resolve(override: nil, home: home, userTempDir: nil)) { error in
            guard case .pathTooLong = error as? SocketSetupError else { return XCTFail("\(error)") }
        }
    }

    func testOverrideTooLongThrows() {
        let long = "/tmp/" + String(repeating: "x", count: SocketPath.maxBytes)
        XCTAssertThrowsError(try SocketPath.resolve(override: long)) { error in
            XCTAssertEqual(error as? SocketSetupError, .pathTooLong(path: long, bytes: long.utf8.count))
        }
    }

    func testRelativeOverrideThrows() {
        XCTAssertThrowsError(try SocketPath.resolve(override: "relative/mcp.sock")) { error in
            XCTAssertEqual(error as? SocketSetupError, .relativePath("relative/mcp.sock"))
        }
    }

    func testOverrideRequiresAnOwnedFolder() throws {
        let resolved = try SocketPath.resolve(override: "/tmp/imax/mcp.sock")
        XCTAssertEqual(resolved.path, "/tmp/imax/mcp.sock")
        XCTAssertEqual(resolved.folderRule, .requireOwned)
    }
}

final class LineFramerTests: XCTestCase {
    func testMessageSplitAcrossChunksIsJoined() throws {
        var framer = LineFramer()
        XCTAssertEqual(try framer.append(Array(#"{"a":"#.utf8)), [])
        XCTAssertEqual(try framer.append(Array("1}\n".utf8)), [Data(#"{"a":1}"#.utf8)])
    }

    func testSeveralMessagesInOneChunkKeepTheirOrder() throws {
        var framer = LineFramer()
        XCTAssertEqual(try framer.append(Array("one\ntwo\nthr".utf8)), [Data("one".utf8), Data("two".utf8)])
        XCTAssertEqual(try framer.append(Array("ee\n".utf8)), [Data("three".utf8)])
    }

    func testEmptyLinesAreDropped() throws {
        var framer = LineFramer()
        XCTAssertEqual(try framer.append(Array("\n\none\n\n".utf8)), [Data("one".utf8)])
    }

    func testUnterminatedTailOverTheCapThrows() {
        var framer = LineFramer()
        let oversized = [UInt8](repeating: 0x61, count: LineFramer.maxMessageBytes + 1)
        XCTAssertThrowsError(try framer.append(oversized))
    }

    func testMessageAtTheCapIsAccepted() throws {
        var framer = LineFramer()
        let atCap = [UInt8](repeating: 0x61, count: LineFramer.maxMessageBytes)
        XCTAssertEqual(try framer.append(atCap), [])
        XCTAssertEqual(try framer.append([0x0A]).first?.count, LineFramer.maxMessageBytes)
    }
}
