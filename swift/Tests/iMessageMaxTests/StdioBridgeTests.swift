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

    private func startBridge(grace: Duration = .zero, input: Int32? = nil) throws -> BridgeHarness {
        let bridge = try BridgeHarness(socket: socket, grace: grace, input: input)
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

    func testHelperStopMidSessionIsHelperDisconnected() async throws {
        try await startHelper()
        let bridge = try startBridge()
        try initialize(bridge)

        await listener?.stop()

        let outcome = await bridge.outcome(timeout: 10)
        XCTAssertEqual(outcome, .helperDisconnected)
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
    init(socket: SocketPath, grace: Duration, input bridgeStdin: Int32? = nil) throws {
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
            let outcome = await StdioBridge.run(socket: socket, input: bridgeInput, output: bridgeOutput, connectGrace: grace)
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
