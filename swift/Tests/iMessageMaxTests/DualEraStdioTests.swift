import Foundation
import XCTest
import Logging
import MCP
@testable import iMessageMax

final class DualEraStdioTests: XCTestCase {
    private var definitions: [ToolDefinition] = []
    private var catalog: ToolCatalog { ToolCatalog(definitions) }

    func testModernDiscoverIsAnsweredDirectlyAndLegacyPassesThrough() async throws {
        let base = FakeBaseTransport()
        let dual = DualEraStdio(base: base, catalog: catalog)
        try await dual.start()

        let downstream = await dual.legacy.receive()
        var iterator = downstream.makeAsyncIterator()

        let discover = Data(modernBody(method: "server/discover").utf8)
        await base.feed(discover)

        let responseData = try await base.waitForFirstSend()
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["supportedVersions"] as? [String], ["2026-07-28"])

        let legacy = Data(initializeBody(id: 2, protocolVersion: "2025-11-25").utf8)
        await base.feed(legacy)

        let forwarded = try await iterator.next()
        XCTAssertEqual(forwarded, legacy)
        let sentCount = await base.sentCount()
        XCTAssertEqual(sentCount, 1, "legacy message must not be answered by the dispatcher")

        await dual.stop()
    }

    func testSendPassesThroughToBase() async throws {
        let base = FakeBaseTransport()
        let dual = DualEraStdio(base: base, catalog: catalog)
        try await dual.start()

        let payload = Data(#"{"jsonrpc":"2.0","id":3,"result":{}}"#.utf8)
        try await dual.legacy.send(payload)

        let sent = try await base.waitForFirstSend()
        XCTAssertEqual(sent, payload)

        await dual.stop()
    }

    func testLegacyInitializeResultGainsServerIcons() async throws {
        let base = FakeBaseTransport()
        let dual = DualEraStdio(base: base, catalog: catalog)
        try await dual.start()

        let result = Data(
            #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","serverInfo":{"name":"iMessage Max"},"capabilities":{}}}"#.utf8
        )
        try await dual.legacy.send(result)

        let sent = try await base.waitForFirstSend()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: Any])
        let serverInfo = try XCTUnwrap((object["result"] as? [String: Any])?["serverInfo"] as? [String: Any])
        let icons = try XCTUnwrap(serverInfo["icons"] as? [[String: Any]])
        XCTAssertEqual(icons.compactMap { ($0["sizes"] as? [String])?.first }, ["64x64", "32x32", "16x16"])

        await dual.stop()
    }

    func testModernToolsListIsAnsweredDirectly() async throws {
        let base = FakeBaseTransport()
        let dual = DualEraStdio(base: base, catalog: catalog)
        try await dual.start()

        let downstream = await dual.legacy.receive()
        var iterator = downstream.makeAsyncIterator()

        let toolsList = Data(modernBody(method: "tools/list").utf8)
        await base.feed(toolsList)

        let responseData = try await base.waitForFirstSend()
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNotNil(result["tools"], "tools/list must answer with a catalog")

        let legacy = Data(initializeBody(id: 2, protocolVersion: "2025-11-25").utf8)
        await base.feed(legacy)
        let forwarded = try await iterator.next()
        XCTAssertEqual(forwarded, legacy)

        let sentCount = await base.sentCount()
        XCTAssertEqual(sentCount, 1, "only the tools/list response should have been sent")

        await dual.stop()
    }

    func testModernToolCallIsAnsweredDirectly() async throws {
        registerFakeTool(named: "stdio_echo")

        let base = FakeBaseTransport()
        let dual = DualEraStdio(base: base, catalog: catalog)
        try await dual.start()

        let downstream = await dual.legacy.receive()
        var iterator = downstream.makeAsyncIterator()

        let toolCall = Data(modernBody(method: "tools/call", params: #""name":"stdio_echo","arguments":{}"#).utf8)
        await base.feed(toolCall)

        let responseData = try await base.waitForFirstSend()
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["resultType"] as? String, "complete")

        let legacy = Data(initializeBody(id: 2, protocolVersion: "2025-11-25").utf8)
        await base.feed(legacy)
        let forwarded = try await iterator.next()
        XCTAssertEqual(forwarded, legacy, "tools/call must never reach the legacy downstream stream")

        let sentCount = await base.sentCount()
        XCTAssertEqual(sentCount, 1, "only the tools/call response should have been sent")

        await dual.stop()
    }

    func testModernNotificationIsConsumedSilently() async throws {
        let base = FakeBaseTransport()
        let dual = DualEraStdio(base: base, catalog: catalog)
        try await dual.start()

        let downstream = await dual.legacy.receive()
        var iterator = downstream.makeAsyncIterator()

        let notification = Data(modernBody(id: nil, method: "notifications/cancelled", params: #""requestId":9"#).utf8)
        await base.feed(notification)

        let legacy = Data(initializeBody(id: 2, protocolVersion: "2025-11-25").utf8)
        await base.feed(legacy)

        let forwarded = try await iterator.next()
        XCTAssertEqual(forwarded, legacy, "the legacy message must be the first thing forwarded")

        let sentCount = await base.sentCount()
        XCTAssertEqual(sentCount, 0, "a notification must produce no response")

        await dual.stop()
    }

    func testInitializeWithModernMetaStaysLegacy() async throws {
        let base = FakeBaseTransport()
        let dual = DualEraStdio(base: base, catalog: catalog)
        try await dual.start()

        let downstream = await dual.legacy.receive()
        var iterator = downstream.makeAsyncIterator()

        let initializeWithModernMeta = Data(modernBody(method: "initialize", params: #""protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"tests","version":"1.0"}"#).utf8)
        await base.feed(initializeWithModernMeta)

        let forwarded = try await iterator.next()
        XCTAssertEqual(
            forwarded, initializeWithModernMeta,
            "initialize must pass through verbatim to the legacy lane even with modern _meta"
        )

        let sentCount = await base.sentCount()
        XCTAssertEqual(sentCount, 0, "the dispatcher must never answer initialize directly")

        await dual.stop()
    }

    func testUnparseableLinePassesThroughToLegacyLane() async throws {
        let base = FakeBaseTransport()
        let dual = DualEraStdio(base: base, catalog: catalog)
        try await dual.start()

        let downstream = await dual.legacy.receive()
        var iterator = downstream.makeAsyncIterator()

        let notJSON = Data("not json".utf8)
        await base.feed(notJSON)

        let forwarded = try await iterator.next()
        XCTAssertEqual(
            forwarded, notJSON,
            "unparseable input must pass through untouched; the SDK owns the legacy error shape"
        )

        let sentCount = await base.sentCount()
        XCTAssertEqual(sentCount, 0, "the dispatcher must never see unparseable input")

        await dual.stop()
    }

    func testSlowModernCallDoesNotBlockSubsequentMessages() async throws {
        let gate = AsyncStream<Void>.makeStream()
        registerFakeTool(named: "slow_tool") { _ in
            var iterator = gate.stream.makeAsyncIterator()
            _ = await iterator.next()
            return [.plainText("done")]
        }

        let base = FakeBaseTransport()
        let dual = DualEraStdio(base: base, catalog: catalog)
        try await dual.start()

        let downstream = await dual.legacy.receive()
        var iterator = downstream.makeAsyncIterator()

        let slowCall = Data(modernBody(method: "tools/call", params: #""name":"slow_tool","arguments":{}"#).utf8)
        await base.feed(slowCall)

        let legacy = Data(initializeBody(id: 2, protocolVersion: "2025-11-25").utf8)
        await base.feed(legacy)

        let forwarded = try await iterator.next()
        XCTAssertEqual(forwarded, legacy)

        let sentCountWhileParked = await base.sentCount()
        XCTAssertEqual(sentCountWhileParked, 0, "the slow tool call must still be in flight")

        gate.continuation.yield(())
        let responseData = try await base.waitForFirstSend()
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["resultType"] as? String, "complete")

        await dual.stop()
    }

    func testWriteFailureIsSwallowedButLogged() async throws {
        let base = FakeBaseTransport()
        let dual = DualEraStdio(base: base, catalog: catalog)
        let log = Log.Capture()
        try await Log.$capture.withValue(log) { try await dual.start() }

        await base.failNextSend()

        let discover1 = Data(modernBody(method: "server/discover").utf8)
        await base.feed(discover1)

        await base.waitForAttempts(1)
        let attempts = await base.sendAttemptCount()
        XCTAssertEqual(attempts, 1, "the first response must have attempted a write")
        let sentSoFar = await base.sentCount()
        XCTAssertEqual(sentSoFar, 0, "a failed write must not be recorded as sent")

        let discover2 = Data(modernBody(id: 2, method: "server/discover").utf8)
        await base.feed(discover2)

        let responseData = try await base.waitForFirstSend()
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        XCTAssertEqual(response["id"] as? Int, 2)
        XCTAssertTrue(
            log.lines.contains { $0.hasPrefix("stdio write failed; response dropped:") && $0.contains("simulated write failure") },
            "\(log.lines)"
        )

        await dual.stop()
    }

    func testRepliesAreWrittenOneAtATime() async throws {
        let base = FakeBaseTransport(suspendsMidWrite: true)
        let dual = DualEraStdio(base: base, catalog: catalog)
        try await dual.start()

        async let first: Void = dual.legacy.send(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
        async let second: Void = dual.legacy.send(Data(#"{"jsonrpc":"2.0","id":2,"result":{}}"#.utf8))
        await base.feed(Data(modernBody(id: 3, method: "server/discover").utf8))
        _ = try await (first, second)
        await base.waitForSent(3)
        await dual.stop()

        let events = await base.writeEvents()
        XCTAssertEqual(events.count, 6)
        for pair in stride(from: 0, to: events.count, by: 2) {
            XCTAssertEqual(events[pair], "begin")
            XCTAssertEqual(events[pair + 1], "end")
        }
    }

    func testCancelledNotificationStopsModernToolCall() async throws {
        let cancels = [
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5}}"#,
            modernBody(id: nil, method: "notifications/cancelled", params: #""requestId":5"#),
        ]
        for cancel in cancels {
            let (started, startedSink) = AsyncStream<Void>.makeStream()
            let base = FakeBaseTransport()
            let dual = DualEraStdio(base: base, catalog: ToolCatalog([waitForCancelTool(started: startedSink)]))
            try await dual.start()
            let clock = ContinuousClock()
            let begin = clock.now

            await base.feed(Data(modernBody(id: 5, method: "tools/call", params: #""name":"wait_for_cancel","arguments":{}"#).utf8))
            var iterator = started.makeAsyncIterator()
            _ = await iterator.next()
            await base.feed(Data(cancel.utf8))

            let sent = try await base.waitForFirstSend()
            let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: Any])
            XCTAssertLessThan(clock.now - begin, .seconds(5), "the call ran on after \(cancel)")
            XCTAssertEqual(reply["id"] as? Int, 5)
            XCTAssertEqual((reply["result"] as? [String: Any])?["isError"] as? Bool, true, "\(reply)")
            await dual.stop()
        }
    }

    func testModernReplyIsWrittenBeforeServeStdioReturnsAtEndOfInput() async throws {
        let slow = fakeTool(named: "slow") { _ in
            await AsyncTimeout.sleep(.milliseconds(300))
            return [.plainText(#"{"done":true}"#)]
        }
        let base = FakeBaseTransport()
        await base.feed(Data(modernBody(id: 9, method: "tools/call", params: #""name":"slow","arguments":{}"#).utf8))
        await base.endInput()

        try await ServerStartup.serveStdio(base: base, catalog: ToolCatalog([slow]))

        let replies = await base.sentMessages().compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let reply = try XCTUnwrap(replies.first { $0["id"] as? Int == 9 }, "no reply written: \(replies)")
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual((result["structuredContent"] as? [String: Any])?["done"] as? Bool, true)
    }

    private func registerFakeTool(
        named name: String,
        handler: @escaping @Sendable ([String: Value]?) async throws -> [Tool.Content] = { _ in [.plainText("ok")] }
    ) {
        definitions.append(fakeTool(named: name, handler: handler))
    }
}

private actor FakeBaseTransport: Transport {
    nonisolated let logger: Logger

    private var sent: [Data] = []
    private var events: [String] = []
    private let suspendsMidWrite: Bool
    private var shouldFailNextSend = false
    private var sendAttempts = 0
    private var waiters: [(ready: @Sendable (Int, Int) -> Bool, continuation: CheckedContinuation<Void, Never>)] = []
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init(suspendsMidWrite: Bool = false) {
        self.suspendsMidWrite = suspendsMidWrite
        self.logger = Logger(
            label: "test.fake-transport",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async throws {}

    func disconnect() async {
        continuation.finish()
    }

    func send(_ data: Data) async throws {
        sendAttempts += 1
        defer { wakeWaiters() }
        if shouldFailNextSend {
            shouldFailNextSend = false
            throw NSError(
                domain: "FakeBaseTransport", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "simulated write failure"]
            )
        }
        events.append("begin")
        if suspendsMidWrite {
            for _ in 0..<5 { await Task.yield() }
        }
        events.append("end")
        sent.append(data)
    }

    func writeEvents() -> [String] {
        events
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        stream
    }

    func feed(_ data: Data) {
        continuation.yield(data)
    }

    func endInput() {
        continuation.finish()
    }

    func sentCount() -> Int {
        sent.count
    }

    func sentMessages() -> [Data] {
        sent
    }

    func failNextSend() {
        shouldFailNextSend = true
    }

    func sendAttemptCount() -> Int {
        sendAttempts
    }

    func waitForAttempts(_ count: Int) async {
        await wait { attempts, _ in attempts >= count }
    }

    func waitForSent(_ count: Int) async {
        await wait { _, sent in sent >= count }
    }

    func waitForFirstSend() async throws -> Data {
        await waitForSent(1)
        return sent[0]
    }

    private func wait(until ready: @escaping @Sendable (Int, Int) -> Bool) async {
        if ready(sendAttempts, sent.count) { return }
        await withCheckedContinuation { waiters.append((ready, $0)) }
    }

    private func wakeWaiters() {
        let (attempts, sentCount) = (sendAttempts, sent.count)
        let due = waiters.filter { $0.ready(attempts, sentCount) }
        waiters.removeAll { $0.ready(attempts, sentCount) }
        due.forEach { $0.continuation.resume() }
    }
}
