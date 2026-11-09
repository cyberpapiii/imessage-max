import Darwin
import Foundation
import Logging
import MCP
import Synchronization
import XCTest
@testable import iMessageMax

final class StdioBridgeTests: XCTestCase {
    private var folder: String!
    private var socket: SocketPath!
    private var listener: SocketListener?
    private var bridges: [BridgeHarness] = []

    override func setUpWithError() throws {
        // The bridge writes to pipes; a closed pipe must give EPIPE, as the
        // command arranges in production, not kill the test process.
        signal(SIGPIPE, SIG_IGN)
        folder = try makeShortTempFolder()
        socket = try testSocketPath(in: folder)
    }

    override func tearDown() async throws {
        for bridge in bridges {
            bridge.closeInput()
            _ = await bridge.outcome(timeout: 10)
            bridge.closeOutput()
        }
        await listener?.stop()
        try? FileManager.default.removeItem(atPath: folder)
    }

    private func startHelper(catalog: ToolCatalog = makeTestCatalog(), log: Log.Capture? = nil) async throws {
        listener = try await SocketListener.start(at: socket) { transport in
            await Log.$capture.withValue(log) {
                try? await ServerStartup.serveStdio(base: transport, catalog: catalog)
            }
        }
    }

    private func startBridge(
        grace: Duration = .zero, input: Int32? = nil, hasDesktopLogin: Bool = true
    ) throws -> BridgeHarness {
        let bridge = try BridgeHarness(socket: socket, grace: grace, input: input, hasDesktopLogin: hasDesktopLogin)
        bridges.append(bridge)
        return bridge
    }

    private func initialize(_ bridge: BridgeHarness) throws {
        bridge.send(initializeBody(id: 1, protocolVersion: "2025-11-25"))
        let reply = try bridge.output.nextJSON()
        XCTAssertEqual(reply["id"] as? Int, 1)
        XCTAssertNotNil((reply["result"] as? [String: Any])?["serverInfo"], "\(reply)")
        bridge.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
    }

    func testLegacySessionRunsThroughTheBridge() async throws {
        try await startHelper()
        let bridge = try startBridge()
        try initialize(bridge)

        bridge.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#)
        let list = try bridge.output.nextJSON()
        XCTAssertEqual(list["id"] as? Int, 2)
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]], "\(list)")
        XCTAssertEqual(tools.count, 13)
        XCTAssertTrue(tools.contains { $0["name"] as? String == "diagnose" })

        bridge.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"diagnose","arguments":{}}}"#)
        let call = try bridge.output.nextJSON()
        XCTAssertEqual(call["id"] as? Int, 3)
        let result = try XCTUnwrap(call["result"] as? [String: Any], "\(call)")
        XCTAssertNotEqual(result["isError"] as? Bool, true, "\(result)")
        XCTAssertNotNil((result["structuredContent"] as? [String: Any])?["capabilities"], "\(result)")

        bridge.closeInput()
        let outcome = await bridge.outcome(timeout: 10)
        XCTAssertEqual(outcome, .finished)
        XCTAssertEqual(outcome?.exitCode, 0)
    }

    func testModernRequestsRunThroughTheBridge() async throws {
        try await startHelper()
        let bridge = try startBridge()

        bridge.send(modernBody(id: 1, method: "server/discover"))
        let discover = try bridge.output.nextJSON()
        XCTAssertEqual(discover["id"] as? Int, 1)
        XCTAssertEqual((discover["result"] as? [String: Any])?["supportedVersions"] as? [String], ["2026-07-28"])

        bridge.send(modernBody(id: 2, method: "tools/list"))
        let list = try bridge.output.nextJSON()
        XCTAssertEqual(((list["result"] as? [String: Any])?["tools"] as? [Any])?.count, 13, "\(list)")

        bridge.send(modernBody(id: 3, method: "tools/call", params: #""name":"diagnose","arguments":{}"#))
        let call = try bridge.output.nextJSON()
        XCTAssertEqual(call["id"] as? Int, 3)
        let result = try XCTUnwrap(call["result"] as? [String: Any], "\(call)")
        XCTAssertEqual(result["resultType"] as? String, "complete")
        XCTAssertNotNil((result["structuredContent"] as? [String: Any])?["capabilities"], "\(result)")
    }

    func testHelperDownAnswersTheFirstRequestAndExits69() async throws {
        let bridge = try startBridge(grace: .zero)

        bridge.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        bridge.send(initializeBody(id: 7))
        let reply = try bridge.output.nextJSON()
        XCTAssertEqual(reply["id"] as? Int, 7)
        let error = try XCTUnwrap(reply["error"] as? [String: Any], "\(reply)")
        XCTAssertEqual(error["code"] as? Int, -32000)
        XCTAssertEqual(error["message"] as? String, "iMessage Max is not running. Open iMessage Max to start it.")

        let outcome = await bridge.outcome(timeout: 10)
        XCTAssertEqual(outcome, .helperUnavailable(.notRunning))
        XCTAssertEqual(outcome?.exitCode, 69)
    }

    func testHelperDownWithNoDesktopLoginSaysToLogIn() async throws {
        let bridge = try startBridge(grace: .zero, hasDesktopLogin: false)

        bridge.send(initializeBody(id: 7))
        let reply = try bridge.output.nextJSON()
        let error = try XCTUnwrap(reply["error"] as? [String: Any], "\(reply)")
        XCTAssertEqual(error["code"] as? Int, -32000)
        let message = try XCTUnwrap(error["message"] as? String)
        XCTAssertEqual(message, BridgeOutcome.Unavailable.noDesktopLogin.message)
        XCTAssertTrue(message.contains("not logged in to this Mac's desktop"), message)
        XCTAssertTrue(message.contains("Screen Sharing"), message)

        let outcome = await bridge.outcome(timeout: 10)
        XCTAssertEqual(outcome, .helperUnavailable(.noDesktopLogin))
        XCTAssertEqual(outcome?.exitCode, 69)
    }

    /// The real helper restarts mid-session: the client goes on with no new
    /// initialize, and the new helper sees the replayed handshake.
    func testHelperRestartKeepsTheLegacySession() async throws {
        try await startHelper()
        let bridge = try startBridge(grace: .seconds(10))
        try initialize(bridge)
        bridge.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#)
        XCTAssertEqual(try bridge.output.nextJSON()["id"] as? Int, 2)

        await listener?.stop()
        let restarted = Log.Capture()
        try await startHelper(log: restarted)

        bridge.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}"#)
        let list = try bridge.output.nextJSON()
        XCTAssertEqual(list["id"] as? Int, 3, "the replayed initialize's reply reached the client: \(list)")
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]], "\(list)")
        XCTAssertEqual(tools.count, 13)
        XCTAssertTrue(
            restarted.lines.contains { $0.contains("era=legacy transport=stdio version=2025-11-25 method=initialize") },
            "\(restarted.lines)")
        XCTAssertTrue(restarted.lines.contains { $0.contains("method=notifications/initialized") }, "\(restarted.lines)")

        bridge.closeInput()
        let outcome = await bridge.outcome(timeout: 10)
        XCTAssertEqual(outcome, .finished)
    }

    func testDesktopLoginReadsEverySession() {
        let switchedOut: [String: Any] = [
            "UID": 502,
            "SessionInfo": [["kCGSSessionUserIDKey": 502], ["kCGSSessionUserIDKey": 501]],
        ]
        XCTAssertTrue(DesktopLogin.hasSession(uid: 501, consoleUser: switchedOut))
        XCTAssertFalse(DesktopLogin.hasSession(uid: 503, consoleUser: switchedOut))
        XCTAssertFalse(DesktopLogin.hasSession(uid: 501, consoleUser: nil), "no console entry means no one is logged in")
        XCTAssertTrue(DesktopLogin.hasSession(uid: 501, consoleUser: ["UID": 501]))
        XCTAssertFalse(DesktopLogin.hasSession(uid: 501, consoleUser: ["UID": 0, "Name": "loginwindow"]))
    }

    func testHelperDownWithEOFFirstWritesNothing() async throws {
        let bridge = try startBridge(grace: .zero)
        bridge.closeInput()

        let outcome = await bridge.outcome(timeout: 10)
        XCTAssertEqual(outcome, .helperUnavailable(.notRunning))
        bridge.closeOutputWriter()
        XCTAssertNil(try bridge.output.nextLine(), "nothing written before EOF")
    }

    func testHelperDownAnswersAnUnparseableFirstLineWithAParseError() async throws {
        let bridge = try startBridge(grace: .zero)

        bridge.send("this is not json")
        let reply = try bridge.output.nextJSON()
        XCTAssertTrue(reply["id"] is NSNull, "\(reply)")
        let error = try XCTUnwrap(reply["error"] as? [String: Any], "\(reply)")
        XCTAssertEqual(error["code"] as? Int, -32700)
        let outcome = await bridge.outcome(timeout: 10)
        XCTAssertEqual(outcome, .helperUnavailable(.notRunning))
    }

    func testStdinReadErrorIsAnIOFailure() async throws {
        try await startHelper()
        // read(2) on a folder fails with EISDIR.
        let unreadable = open(folder, O_RDONLY)
        defer { close(unreadable) }
        let bridge = try startBridge(input: unreadable)

        let outcome = await bridge.outcome(timeout: 10)
        guard case .ioFailure(let reason) = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertTrue(reason.hasPrefix("read stdin"), reason)
        XCTAssertEqual(outcome?.exitCode, 74)
    }

    func testSessionThatFailsToStartReleasesItsTransport() async throws {
        let transport = RefusingTransport()
        do {
            try await ServerStartup.serveStdio(base: transport, catalog: makeTestCatalog())
            XCTFail("a transport that cannot connect must fail the session")
        } catch {}
        let released = await transport.disconnected
        XCTAssertTrue(released)
    }

    // The legacy lane cannot show this: the SDK server drops a reply still
    // in flight when its input ends, the same as with --direct.
    func testClosingStdinStillDeliversThePendingReplyThenFinishes() async throws {
        try await startHelper()
        let bridge = try startBridge()

        bridge.send(modernBody(id: 4, method: "tools/call", params: #""name":"diagnose","arguments":{}"#))
        bridge.closeInput()

        let call = try bridge.output.nextJSON()
        XCTAssertEqual(call["id"] as? Int, 4)
        XCTAssertNotNil(call["result"], "\(call)")
        let outcome = await bridge.outcome(timeout: 10)
        XCTAssertEqual(outcome, .finished)
        XCTAssertEqual(outcome?.exitCode, 0)
    }

    func testHelperThatDoesNotComeBackIsHelperDisconnected() async throws {
        try await startHelper()
        let bridge = try startBridge()
        try initialize(bridge)

        await listener?.stop()

        let outcome = await bridge.outcome(timeout: 10)
        XCTAssertEqual(outcome, .helperDisconnected(.notRunning))
        XCTAssertEqual(outcome?.exitCode, 75)
    }

    func testLateHelperIsReachedWithinTheGrace() async throws {
        let bridge = try startBridge(grace: .seconds(2))
        bridge.send(initializeBody(id: 1, protocolVersion: "2025-11-25"))
        usleep(150_000)
        try await startHelper()

        let reply = try bridge.output.nextJSON()
        XCTAssertEqual(reply["id"] as? Int, 1)
        XCTAssertNotNil(reply["result"], "\(reply)")
    }

    func testLegacyCancelThroughTheBridgeCancelsTheTool() async throws {
        let started = expectation(description: "tool started")
        let cancelled = expectation(description: "tool saw cancellation")
        let parked = fakeTool(named: "park") { _ in
            started.fulfill()
            let (wake, wakeSink) = AsyncStream<Void>.makeStream()
            await withTaskCancellationHandler {
                for await _ in wake {}
            } onCancel: {
                cancelled.fulfill()
                wakeSink.finish()
            }
            throw CancellationError()
        }
        let log = Log.Capture()
        try await startHelper(catalog: ToolCatalog([parked]), log: log)
        let bridge = try startBridge()
        try initialize(bridge)

        bridge.send(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"park","arguments":{}}}"#)
        await fulfillment(of: [started], timeout: 10)
        bridge.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5}}"#)
        await fulfillment(of: [cancelled], timeout: 10)

        let logged = expectation(description: "cancelled call logged")
        Task.detached {
            for _ in 0..<200 {
                if log.lines.contains(where: { $0.contains("call tool=park lane=legacy-stdio outcome=cancelled") }) {
                    return logged.fulfill()
                }
                await AsyncTimeout.sleep(.milliseconds(25))
            }
        }
        await fulfillment(of: [logged], timeout: 10)
    }
}

/// The bridge against a helper the test drives by hand, so each restart
/// lands exactly where the test wants it.
final class StdioBridgeReconnectTests: XCTestCase {
    private var folder: String!
    private var socket: SocketPath!
    private var bridges: [BridgeHarness] = []
    private var helpers: [FakeHelper] = []

    private static let replayId = "imessage-max-bridge-replay-1"

    override func setUpWithError() throws {
        signal(SIGPIPE, SIG_IGN)
        folder = try makeShortTempFolder()
        socket = try testSocketPath(in: folder)
    }

    override func tearDown() async throws {
        // Helpers first: a bridge parked in a fake's backlog never sees EOF.
        helpers.forEach { $0.close() }
        for bridge in bridges {
            bridge.closeInput()
            _ = await bridge.outcome(timeout: 20)
            bridge.closeOutput()
        }
        try? FileManager.default.removeItem(atPath: folder)
    }

    private func startHelper() throws -> FakeHelper {
        let helper = try FakeHelper(at: socket)
        helpers.append(helper)
        return helper
    }

    private func startBridge(grace: Duration = .seconds(10), hasDesktopLogin: Bool = true) throws -> BridgeHarness {
        let bridge = try BridgeHarness(socket: socket, grace: grace, hasDesktopLogin: hasDesktopLogin)
        bridges.append(bridge)
        return bridge
    }

    private func handshake(_ bridge: BridgeHarness, through helper: FakeConnection) throws {
        bridge.send(initializeBody(id: 1, protocolVersion: "2025-11-25"))
        XCTAssertEqual(try helper.nextJSON()["id"] as? Int, 1)
        helper.send(Self.initializeResult(id: "1"))
        XCTAssertEqual(try bridge.output.nextJSON()["id"] as? Int, 1)
        bridge.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertEqual(try helper.nextJSON()["method"] as? String, "notifications/initialized")
    }

    /// `id` is raw JSON: `1` or `"text"`.
    private static func initializeResult(id: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"fake","version":"1"}}}"#
    }

    /// Kills the helper. The listener goes first, so the bridge cannot
    /// reconnect to it, then the connection.
    private func kill(_ helper: FakeHelper, _ connection: FakeConnection) {
        helper.close()
        connection.close()
    }

    private func assertServerError(
        _ reply: [String: Any], id: Int, containing text: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(reply["id"] as? Int, id, "\(reply)", file: file, line: line)
        let error = reply["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32000, "\(reply)", file: file, line: line)
        XCTAssertTrue((error?["message"] as? String ?? "").contains(text), "\(reply)", file: file, line: line)
    }

    func testRestartAnswersTheInFlightRequestAndReplaysTheHandshake() async throws {
        let first = try startHelper()
        let bridge = try startBridge()
        let old = try first.accept()
        try handshake(bridge, through: old)
        bridge.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"send","arguments":{}}}"#)
        XCTAssertEqual(try old.nextJSON()["id"] as? Int, 2)

        kill(first, old)
        assertServerError(try bridge.output.nextJSON(), id: 2, containing: "restarted while this request was running")

        // The bridge has seen the drop, so this waits for the next helper.
        bridge.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}"#)
        let second = try startHelper()
        let new = try second.accept()
        let replay = try new.nextJSON()
        XCTAssertEqual(replay["method"] as? String, "initialize")
        XCTAssertEqual(replay["id"] as? String, Self.replayId)
        XCTAssertEqual((replay["params"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")
        XCTAssertThrowsError(try new.reader.nextLine(timeout: 0.3), "sent more before the replay was answered")

        new.send(Self.initializeResult(id: #""\#(Self.replayId)""#))
        XCTAssertEqual(try new.nextJSON()["method"] as? String, "notifications/initialized")
        let list = try new.nextJSON()
        XCTAssertEqual(list["id"] as? Int, 3)
        XCTAssertEqual(list["method"] as? String, "tools/list")
        new.send(#"{"jsonrpc":"2.0","id":3,"result":{"tools":[]}}"#)

        let reply = try bridge.output.nextJSON()
        XCTAssertEqual(reply["id"] as? Int, 3, "the replayed initialize's reply reached the client: \(reply)")
        XCTAssertNotNil(reply["result"], "\(reply)")

        // Every restart replays again.
        kill(second, new)
        let third = try startHelper()
        XCTAssertEqual(try third.accept().nextJSON()["id"] as? String, "imessage-max-bridge-replay-2")
    }

    func testModernRequestsNeedNoReplay() async throws {
        let first = try startHelper()
        let bridge = try startBridge()
        let old = try first.accept()
        bridge.send(modernBody(id: 1, method: "tools/list"))
        XCTAssertEqual(try old.nextJSON()["id"] as? Int, 1)

        kill(first, old)
        assertServerError(try bridge.output.nextJSON(), id: 1, containing: "restarted")
        bridge.send(modernBody(id: 2, method: "tools/list"))
        let second = try startHelper()
        let next = try second.accept().nextJSON()
        XCTAssertEqual(next["method"] as? String, "tools/list", "\(next)")
        XCTAssertEqual(next["id"] as? Int, 2)
    }

    func testRequestsPastTheQueueBoundFailAtOnceAndTheRestGoOutInOrder() async throws {
        let first = try startHelper()
        let bridge = try startBridge()
        let old = try first.accept()
        bridge.send(modernBody(id: 1, method: "tools/list"))
        XCTAssertEqual(try old.nextJSON()["id"] as? Int, 1)
        kill(first, old)
        assertServerError(try bridge.output.nextJSON(), id: 1, containing: "restarted")

        for id in 2...66 { bridge.send(modernBody(id: id, method: "tools/list")) }
        assertServerError(try bridge.output.nextJSON(), id: 66, containing: "too many requests are already waiting")

        let second = try startHelper()
        let new = try second.accept()
        for id in 2...65 {
            XCTAssertEqual(try new.nextJSON()["id"] as? Int, id)
        }
    }

    /// The socket never comes back: a waiting request and the exit both say
    /// that a desktop login is needed.
    func testHelperThatNeverReturnsExplainsTheDesktopLogin() async throws {
        let first = try startHelper()
        let bridge = try startBridge(grace: .milliseconds(500), hasDesktopLogin: false)
        let old = try first.accept()
        try handshake(bridge, through: old)
        bridge.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#)
        XCTAssertEqual(try old.nextJSON()["id"] as? Int, 2)

        kill(first, old)
        assertServerError(try bridge.output.nextJSON(), id: 2, containing: "restarted")
        bridge.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}"#)
        let reply = try bridge.output.nextJSON()
        assertServerError(reply, id: 3, containing: "not logged in to this Mac's desktop")
        XCTAssertEqual(
            (reply["error"] as? [String: Any])?["message"] as? String, BridgeOutcome.Unavailable.noDesktopLogin.message)

        let outcome = await bridge.outcome(timeout: 10)
        XCTAssertEqual(outcome, .helperDisconnected(.noDesktopLogin))
        XCTAssertEqual(outcome?.exitCode, 75)
    }

    func testHelperThatAcceptsButNeverAnswersTheReplayIsGivenUp() async throws {
        let first = try startHelper()
        let bridge = try startBridge(grace: .seconds(1))
        let old = try first.accept()
        try handshake(bridge, through: old)
        kill(first, old)
        let second = try startHelper()
        let silent = try second.accept()
        XCTAssertEqual(try silent.nextJSON()["id"] as? String, Self.replayId)

        let outcome = await bridge.outcome(timeout: 10)
        XCTAssertEqual(
            outcome, .helperDisconnected(.connectFailed(reason: "it accepted the connection but did not answer initialize")))
    }

    func testStdinEndingWhileTheHelperIsAwayFinishes() async throws {
        let first = try startHelper()
        let bridge = try startBridge()
        let old = try first.accept()
        try handshake(bridge, through: old)
        kill(first, old)
        bridge.closeInput()

        let outcome = await bridge.outcome(timeout: 5)
        XCTAssertEqual(outcome, .finished)
    }
}

/// A helper socket the test drives line by line.
private final class FakeHelper {
    private let listener: Int32
    private let path: String
    private var closed = false

    init(at socket: SocketPath) throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        unlink(socket.path)
        guard socket.withAddress({ bind(fd, $0, $1) }) == 0, listen(fd, 8) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        listener = fd
        path = socket.path
    }

    /// Waits for the bridge to connect.
    func accept(timeout: TimeInterval = 10) throws -> FakeConnection {
        var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, Int32(timeout * 1000)) > 0 else { throw SocketTestTimeout() }
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return FakeConnection(fd)
    }

    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(listener)
        unlink(path)
    }
}

private final class FakeConnection {
    let reader: LineReader
    private var open = true

    init(_ fd: Int32) {
        reader = LineReader(fd)
    }

    func nextJSON(file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        try reader.nextJSON(file: file, line: line)
    }

    func send(_ line: String) {
        writeLine(reader.fd, line)
    }

    func close() {
        guard open else { return }
        open = false
        Darwin.close(reader.fd)
    }

    deinit { close() }
}

/// One in-process bridge run over two pipes. The test writes the client's
/// stdin and reads its stdout.
private final class BridgeHarness: @unchecked Sendable {
    let output: LineReader
    private let toBridge: Int32
    private let bridgeOutput: Int32
    private let state = Mutex<(inputOpen: Bool, outputWriterOpen: Bool, outcome: BridgeOutcome?)>((true, true, nil))
    private let finished: AsyncStream<Void>
    private let finishedSink: AsyncStream<Void>.Continuation

    /// `input` replaces the stdin pipe as what the bridge reads.
    init(socket: SocketPath, grace: Duration, input bridgeStdin: Int32? = nil, hasDesktopLogin: Bool = true) throws {
        var input: [Int32] = [0, 0]
        var output: [Int32] = [0, 0]
        guard pipe(&input) == 0, pipe(&output) == 0 else { throw POSIXError(.EMFILE) }
        // The bridge's read end of stdin stays open: its up pump may still be
        // blocked reading it after run returns, as in the real process.
        let bridgeInput = bridgeStdin ?? input[0]
        toBridge = input[1]
        bridgeOutput = output[1]
        self.output = LineReader(output[0])
        (finished, finishedSink) = AsyncStream.makeStream()
        Task { [self] in
            let outcome = await StdioBridge.run(
                socket: socket, input: bridgeInput, output: bridgeOutput, connectGrace: grace,
                hasDesktopLogin: { hasDesktopLogin })
            state.withLock { $0.outcome = outcome }
            finishedSink.finish()
        }
    }

    func send(_ line: String) {
        writeLine(toBridge, line)
    }

    func closeInput() {
        let open = state.withLock { state in defer { state.inputOpen = false }; return state.inputOpen }
        if open { close(toBridge) }
    }

    func closeOutputWriter() {
        let open = state.withLock { state in defer { state.outputWriterOpen = false }; return state.outputWriterOpen }
        if open { close(bridgeOutput) }
    }

    func closeOutput() {
        closeOutputWriter()
        close(output.fd)
    }

    /// nil when the bridge has not returned within `timeout` seconds.
    func outcome(timeout: TimeInterval) async -> BridgeOutcome? {
        let finished = self.finished
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in finished {} }
            group.addTask { await AsyncTimeout.sleep(.seconds(timeout)) }
            await group.next()
            group.cancelAll()
        }
        return state.withLock { $0.outcome }
    }
}

private actor RefusingTransport: Transport {
    nonisolated let logger = Logger(label: "test.refusing-transport", factory: { _ in SwiftLogNoOpLogHandler() })
    private(set) var disconnected = false

    func connect() async throws { throw POSIXError(.ECONNREFUSED) }
    func disconnect() async { disconnected = true }
    func send(_ data: Data) async throws {}
    func receive() -> AsyncThrowingStream<Data, any Error> { AsyncThrowingStream { $0.finish() } }
}
