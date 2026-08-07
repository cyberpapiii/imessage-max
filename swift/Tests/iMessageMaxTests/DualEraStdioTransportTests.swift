import Foundation
import XCTest
import Logging
import MCP
@testable import iMessageMax

/// Verifies era routing in the stdio dual-era adapter: modern 2026-07-28
/// messages are answered directly by ModernDispatcher, while legacy traffic
/// passes through untouched to the SDK Server's receive stream.
final class DualEraStdioTransportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ToolHandlerRegistry.shared.resetForTesting()
    }

    override func tearDown() {
        ToolHandlerRegistry.shared.resetForTesting()
        super.tearDown()
    }

    func testModernDiscoverIsAnsweredDirectlyAndLegacyPassesThrough() async throws {
        let base = FakeBaseTransport()
        let dual = DualEraStdioTransport(base: base)
        try await dual.connect()

        let downstream = await dual.receive()
        var iterator = downstream.makeAsyncIterator()

        let discover = Data(
            #"{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#
                .utf8
        )
        await base.feed(discover)

        let responseData = try await base.waitForFirstSend()
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["supportedVersions"] as? [String], ["2026-07-28"])

        // Legacy initialize must reach the downstream (SDK) stream, not the
        // dispatcher, and the discover message must never have been forwarded.
        let legacy = Data(
            #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"tests","version":"1.0"}}}"#
                .utf8
        )
        await base.feed(legacy)

        let forwarded = try await iterator.next()
        XCTAssertEqual(forwarded, legacy)
        let sentCount = await base.sentCount()
        XCTAssertEqual(sentCount, 1, "legacy message must not be answered by the dispatcher")

        await dual.disconnect()
    }

    func testSendPassesThroughToBase() async throws {
        let base = FakeBaseTransport()
        let dual = DualEraStdioTransport(base: base)
        try await dual.connect()

        let payload = Data(#"{"jsonrpc":"2.0","id":3,"result":{}}"#.utf8)
        try await dual.send(payload)

        let sent = try await base.waitForFirstSend()
        XCTAssertEqual(sent, payload)

        await dual.disconnect()
    }

    // MARK: - Matrix row 1: modern tools/list

    func testModernToolsListIsAnsweredDirectly() async throws {
        let base = FakeBaseTransport()
        let dual = DualEraStdioTransport(base: base)
        try await dual.connect()

        let downstream = await dual.receive()
        var iterator = downstream.makeAsyncIterator()

        let toolsList = Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#
                .utf8
        )
        await base.feed(toolsList)

        let responseData = try await base.waitForFirstSend()
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNotNil(result["tools"], "tools/list must answer with a catalog")

        // Prove tools/list was never forwarded downstream: the next thing on
        // the downstream stream must be the legacy message fed after it.
        let legacy = Data(
            #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"tests","version":"1.0"}}}"#
                .utf8
        )
        await base.feed(legacy)
        let forwarded = try await iterator.next()
        XCTAssertEqual(forwarded, legacy)

        let sentCount = await base.sentCount()
        XCTAssertEqual(sentCount, 1, "only the tools/list response should have been sent")

        await dual.disconnect()
    }

    // MARK: - Matrix row 2: modern tools/call

    func testModernToolCallIsAnsweredDirectly() async throws {
        registerFakeTool(named: "stdio_echo")

        let base = FakeBaseTransport()
        let dual = DualEraStdioTransport(base: base)
        try await dual.connect()

        let downstream = await dual.receive()
        var iterator = downstream.makeAsyncIterator()

        let toolCall = Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"stdio_echo","arguments":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#
                .utf8
        )
        await base.feed(toolCall)

        let responseData = try await base.waitForFirstSend()
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["resultType"] as? String, "complete")

        let legacy = Data(
            #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"tests","version":"1.0"}}}"#
                .utf8
        )
        await base.feed(legacy)
        let forwarded = try await iterator.next()
        XCTAssertEqual(forwarded, legacy, "tools/call must never reach the legacy downstream stream")

        let sentCount = await base.sentCount()
        XCTAssertEqual(sentCount, 1, "only the tools/call response should have been sent")

        await dual.disconnect()
    }

    // MARK: - Matrix row 3: modern notification

    func testModernNotificationIsConsumedSilently() async throws {
        let base = FakeBaseTransport()
        let dual = DualEraStdioTransport(base: base)
        try await dual.connect()

        let downstream = await dual.receive()
        var iterator = downstream.makeAsyncIterator()

        // Modern-shaped message with no `id`: a notification. The dispatcher
        // must accept and drop it (no response), and it must never reach the
        // legacy downstream stream.
        let notification = Data(
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":9,"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#
                .utf8
        )
        await base.feed(notification)

        let legacy = Data(
            #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"tests","version":"1.0"}}}"#
                .utf8
        )
        await base.feed(legacy)

        // Awaiting this guarantees the pump has already finished processing
        // the notification (it is handled synchronously-in-order before the
        // legacy message can be yielded).
        let forwarded = try await iterator.next()
        XCTAssertEqual(forwarded, legacy, "the legacy message must be the first thing forwarded")

        let sentCount = await base.sentCount()
        XCTAssertEqual(sentCount, 0, "a notification must produce no response")

        await dual.disconnect()
    }

    // MARK: - Matrix row 4: initialize carrying modern _meta

    func testInitializeWithModernMetaStaysLegacy() async throws {
        let base = FakeBaseTransport()
        let dual = DualEraStdioTransport(base: base)
        try await dual.connect()

        let downstream = await dual.receive()
        var iterator = downstream.makeAsyncIterator()

        // An `initialize` request whose params carry the modern protocol
        // version _meta key must still be treated as legacy: era selection
        // always keeps `initialize` on the legacy lane, matching HTTP.
        let initializeWithModernMeta = Data(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"tests","version":"1.0"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#
                .utf8
        )
        await base.feed(initializeWithModernMeta)

        let forwarded = try await iterator.next()
        XCTAssertEqual(
            forwarded, initializeWithModernMeta,
            "initialize must pass through verbatim to the legacy lane even with modern _meta"
        )

        let sentCount = await base.sentCount()
        XCTAssertEqual(sentCount, 0, "the dispatcher must never answer initialize directly")

        await dual.disconnect()
    }

    // MARK: - Matrix row 6: unparseable line

    func testUnparseableLinePassesThroughToLegacyLane() async throws {
        let base = FakeBaseTransport()
        let dual = DualEraStdioTransport(base: base)
        try await dual.connect()

        let downstream = await dual.receive()
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

        await dual.disconnect()
    }

    // MARK: - Helpers

    private func registerFakeTool(
        named name: String,
        handler: @escaping @Sendable ([String: Value]?) async throws -> [Tool.Content] = { _ in
            [.plainText("ok")]
        }
    ) {
        let tool = Tool(
            name: name,
            description: "test tool",
            inputSchema: InputSchema.object(properties: [:])
        )
        ToolHandlerRegistry.shared.register(tool: tool, handler: handler)
    }
}

/// Minimal in-memory Transport double: `feed` injects inbound messages,
/// `sent` records everything the adapter writes back.
private actor FakeBaseTransport: Transport {
    nonisolated let logger: Logger

    private var sent: [Data] = []
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init() {
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
        sent.append(data)
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        stream
    }

    func feed(_ data: Data) {
        continuation.yield(data)
    }

    func sentCount() -> Int {
        sent.count
    }

    /// Polls until the adapter has written at least one message (the pump
    /// task answers asynchronously) or fails after ~2 seconds.
    func waitForFirstSend() async throws -> Data {
        for _ in 0..<200 {
            if let first = sent.first { return first }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "DualEraStdioTransportTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for transport send"]
        )
    }
}
