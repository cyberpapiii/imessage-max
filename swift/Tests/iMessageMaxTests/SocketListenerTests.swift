import Darwin
import Foundation
import Synchronization
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

    private func start(
        peerPolicy: @escaping SocketListener.PeerPolicy = SocketListener.sameUser, serve: SocketListener.Serve? = nil
    ) async throws(SocketSetupError) -> SocketListener {
        let listener = try await SocketListener.start(at: socket, peerPolicy: peerPolicy, serve: serve ?? echo)
        listeners.append(listener)
        return listener
    }

    private func startFailure() async -> SocketSetupError? {
        do {
            _ = try await start()
            return nil
        } catch {
            return error
        }
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

    func testSocketFileIsAPrivateSocket() async throws {
        _ = try await start()
        var info = stat()
        XCTAssertEqual(lstat(socket.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    func testStaleSocketLeftByACrashIsReclaimed() async throws {
        let stale = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertEqual(socket.withAddress { Darwin.bind(stale, $0, $1) }, 0)
        close(stale)
        var info = stat()
        XCTAssertEqual(lstat(socket.path, &info), 0, "the stale socket file is still there")

        _ = try await start()
        try assertEchoes(try client(), #"{"after":"reclaim"}"#)
    }

    func testRegularFileAtThePathIsLeftAlone() async throws {
        try "keep me".write(toFile: socket.path, atomically: false, encoding: .utf8)

        let failure = await startFailure()
        XCTAssertEqual(failure, .notASocket(path: socket.path))
        XCTAssertEqual(try String(contentsOfFile: socket.path, encoding: .utf8), "keep me")
    }

    func testLiveListenerAtThePathGivesInUse() async throws {
        _ = try await start()

        let failure = await startFailure()
        XCTAssertEqual(failure, .inUse(path: socket.path))
        try assertEchoes(try client(), #"{"first":"still serves"}"#)
    }

    func testTwoClientsAreServedIndependently() async throws {
        _ = try await start()
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
        _ = try await start(peerPolicy: { _ in false }) { _ in served.fulfill() }

        let reader = try client()
        writeLine(reader.fd, "hello")
        XCTAssertNil(try reader.nextLine(), "the rejected client reads EOF")
        await fulfillment(of: [served], timeout: 0.3)
    }

    func testStopUnlinksTheSocketEndsSessionsAndIsIdempotent() async throws {
        let listener = try await start()
        let reader = try client()
        try assertEchoes(reader, "ping")

        await listener.stop()

        var info = stat()
        XCTAssertEqual(lstat(socket.path, &info), -1)
        XCTAssertEqual(errno, ENOENT)
        XCTAssertNil(try reader.nextLine(), "a live client reads EOF")
        await listener.stop()
    }

    func testFolderOthersCanWriteIsRefusedForTheSocketButNotTheToken() async throws {
        for mode: mode_t in [0o770, 0o707] {
            XCTAssertEqual(chmod(folder, mode), 0)
            let failure = await startFailure()
            XCTAssertEqual(failure, .unsafeFolder(path: folder), "mode \(String(mode, radix: 8))")
            switch StdioBridge.connect(socket, grace: .zero) {
            case .failure(let reason): XCTAssertEqual(reason, .unsafeFolder(path: folder), "the bridge refuses it too")
            case .success: XCTFail("the bridge connected through mode \(String(mode, radix: 8))")
            }
            XCTAssertNoThrow(try PrivateFolder.requireOwned(folder), "the token folder rule is unchanged")
        }
        XCTAssertEqual(chmod(folder, 0o700), 0)
        _ = try await start()
        try assertEchoes(try client(), "private again")
    }

    func testTwoListenersStartingAtOnceLeaveExactlyOneServing() async throws {
        let socket = self.socket!
        let echo = self.echo
        for round in 0..<20 {
            if round.isMultiple(of: 2) {
                let stale = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                XCTAssertEqual(socket.withAddress { Darwin.bind(stale, $0, $1) }, 0)
                close(stale)
            }
            func attempt() async -> Result<SocketListener, SocketSetupError> {
                do {
                    return .success(try await SocketListener.start(at: socket, serve: echo))
                } catch {
                    return .failure(error)
                }
            }
            async let first = attempt()
            async let second = attempt()
            let all = await [first, second]
            let winners = all.compactMap { try? $0.get() }
            XCTAssertEqual(winners.count, 1, "round \(round): \(all)")
            for case .failure(let error) in all {
                XCTAssertEqual(error, .inUse(path: socket.path), "round \(round)")
            }
            listeners += winners
            var info = stat()
            XCTAssertEqual(lstat(socket.path, &info), 0, "round \(round): the socket vanished")
            try assertEchoes(try client(), "round \(round)")
            for winner in winners {
                await winner.stop()
            }
        }
    }

    func testOversizedLineDisconnectsThePeerAndEndsTheSession() async throws {
        let ended = expectation(description: "session ended")
        let log = Log.Capture()
        _ = try await start(serve: { transport in
            await Log.$capture.withValue(log) {
                try? await ServerStartup.serveStdio(base: transport, catalog: makeTestCatalog())
            }
            ended.fulfill()
        })
        let reader = try client()
        let fd = reader.fd
        Thread.detachNewThread {
            _ = writeUntilError(fd, Array(repeating: 0x61, count: LineFramer.maxMessageBytes + 1))
        }

        XCTAssertNil(try reader.nextLine(), "the peer reads EOF")
        await fulfillment(of: [ended], timeout: 10)
    }

    func testPeerThatNeverReadsIsDisconnectedAndOthersStillServed() async throws {
        let ended = expectation(description: "a session ended")
        ended.assertForOverFulfill = false
        _ = try await start(serve: { [echo] transport in
            await echo(transport)
            ended.fulfill()
        })
        let flooder = try client()
        let flooded = expectation(description: "flooder's write failed")
        let line = Array(repeating: UInt8(0x61), count: 64 * 1024 - 1) + [0x0A]
        let limit = 4 * SocketTransport.maxUnsentBytes
        let written = Mutex(0)
        let fd = flooder.fd
        Thread.detachNewThread {
            while written.withLock({ $0 }) < limit {
                guard writeUntilError(fd, line) == 0 else { return flooded.fulfill() }
                written.withLock { $0 += line.count }
            }
        }

        await fulfillment(of: [flooded, ended], timeout: 20)
        XCTAssertLessThan(written.withLock { $0 }, limit, "the helper kept buffering for a peer that never reads")
        try assertEchoes(try client(), "still serving")
    }

    func testStalledSessionStopsReadingSoThePeersWritesBackUp() async throws {
        let (park, parked) = AsyncStream<Void>.makeStream()
        defer { parked.finish() }
        _ = try await start(serve: { transport in
            try? await transport.connect()
            for await _ in park {}
        })
        let fd = try connectClient(socket)
        clients.append(fd)
        XCTAssertEqual(fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK), 0)
        let line = Array(repeating: UInt8(0x61), count: 1023) + [0x0A]
        let limit = 4 * 1024 * 1024
        var accepted = 0
        while accepted < limit {
            let count = line.withUnsafeBytes { write(fd, $0.baseAddress!, line.count) }
            if count > 0 {
                accepted += count
                continue
            }
            XCTAssertEqual(errno, EAGAIN)
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            if poll(&descriptor, 1, 300) == 0 { break }
        }
        XCTAssertLessThan(accepted, 1024 * 1024, "a session reading nothing must not let the helper buffer without bound")
    }

    func testStopLeavesASocketSomeoneElseBoundAtThePath() async throws {
        let listener = try await start()
        XCTAssertEqual(unlink(socket.path), 0)
        let other = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(other) }
        XCTAssertEqual(socket.withAddress { Darwin.bind(other, $0, $1) }, 0)

        await listener.stop()

        var info = stat()
        XCTAssertEqual(lstat(socket.path, &info), 0, "stop must not unlink a socket it did not bind")
    }

    func testSetupWaitingOnTheLockLeavesTheCooperativePoolFree() async throws {
        let lockFD = open(socket.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        defer { close(lockFD) }
        XCTAssertEqual(flock(lockFD, LOCK_EX), 0)
        let socket = self.socket!
        let attempts = ProcessInfo.processInfo.activeProcessorCount * 2
        let starts = Task {
            await withTaskGroup(of: SocketSetupError?.self) { group in
                for _ in 0..<attempts {
                    group.addTask {
                        do throws(SocketSetupError) {
                            await (try await SocketListener.start(at: socket) { _ in }).stop()
                            return nil
                        } catch {
                            return error
                        }
                    }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
        }
        usleep(200_000)

        let began = ContinuousClock.now
        await Task.detached {}.value
        XCTAssertLessThan(began.duration(to: .now), .milliseconds(500), "a cooperative thread was free while setups waited")
        let failures: [SocketSetupError?] = await starts.value
        XCTAssertEqual(failures, Array(repeating: SocketSetupError.inUse(path: socket.path), count: attempts))
    }

    func testAcceptFailureAfterStopDoesNotTrap() async throws {
        let listener = try await start()
        await listener.stop()

        listener.pauseAccepting(after: EMFILE)
    }

    func testAcceptPausedByAnyFailureResumesAndStopEndsThePause() async throws {
        let listener = try await start()
        listener.pauseAccepting(after: ENOBUFS)
        listener.pauseAccepting(after: EMFILE)

        try assertEchoes(try client(), "after the pause")
        listener.pauseAccepting(after: ENOMEM)
        await listener.stop()
    }

    func testConnectionsPastTheCapAreClosedAndASlotFreesOnDisconnect() async throws {
        _ = try await start()
        var live: [LineReader] = []
        for index in 0..<SocketListener.maxConnections {
            let reader = try client()
            try assertEchoes(reader, "client \(index)")
            live.append(reader)
        }

        let overflow = try client()
        writeLine(overflow.fd, "one too many")
        XCTAssertNil(try overflow.nextLine(), "the connection past the cap reads EOF")
        try assertEchoes(live[1], "the others are still served")

        shutdown(live[0].fd, SHUT_RDWR)
        let deadline = Date().addingTimeInterval(10)
        while true {
            let reader = try client()
            writeLine(reader.fd, "a freed slot")
            if try reader.nextLine() == "a freed slot" { break }
            guard Date() < deadline else { return XCTFail("the closed connection never freed its slot") }
            usleep(50_000)
        }
    }

    func testDisconnectFlushesQueuedWritesToAReadingPeer() async throws {
        let payload = String(repeating: "a", count: 512 * 1024)
        _ = try await start(serve: { transport in
            try? await transport.connect()
            try? await transport.send(Data(payload.utf8))
            await transport.disconnect()
        })
        let reader = try client()

        XCTAssertEqual(try reader.nextLine()?.count, payload.count, "every queued byte arrives")
        XCTAssertNil(try reader.nextLine(), "then EOF")
    }

    func testDisconnectClosesWithinTheFlushDeadlineWhenThePeerNeverReads() async throws {
        let disconnected = Mutex<ContinuousClock.Instant?>(nil)
        _ = try await start(serve: { transport in
            try? await transport.connect()
            try? await transport.send(Data(repeating: 0x61, count: 512 * 1024))
            await transport.disconnect()
            disconnected.withLock { $0 = .now }
        })
        let fd = try connectClient(socket)
        clients.append(fd)

        let deadline = ContinuousClock.now + .seconds(10)
        var probe: UInt8 = 0x0A
        while write(fd, &probe, 1) == 1 {
            guard ContinuousClock.now < deadline else { return XCTFail("the helper kept the fd of a peer that never reads") }
            usleep(50_000)
        }
        XCTAssertEqual(errno, EPIPE)
        let closedAfter = try XCTUnwrap(disconnected.withLock { $0 }).duration(to: .now)
        XCTAssertLessThan(closedAfter, .seconds(3.5), "closed within the 2 s flush deadline")
    }
}

final class LogThrottleTests: XCTestCase {
    func testOneLinePerIntervalCountingTheLinesHeldBack() {
        var throttle = LogThrottle(interval: .seconds(10))
        let start = ContinuousClock.now
        XCTAssertEqual(throttle.admit(at: start), 0)
        XCTAssertNil(throttle.admit(at: start + .seconds(1)))
        XCTAssertNil(throttle.admit(at: start + .seconds(9)))
        XCTAssertEqual(throttle.admit(at: start + .seconds(10)), 2)
        XCTAssertNil(throttle.admit(at: start + .seconds(19)))
        XCTAssertEqual(throttle.admit(at: start + .seconds(30)), 1)
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
        XCTAssertEqual(resolved.folderRule, .requirePrivate)
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
        XCTAssertEqual(resolved.folderRule, .requirePrivate)
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
