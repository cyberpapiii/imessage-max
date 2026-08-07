import Foundation
import XCTest
import Logging
import MCP
@testable import iMessageMax

/// Verifies era routing in the stdio dual-era adapter: modern 2026-07-28
/// messages are answered directly by ModernDispatcher, while legacy traffic
/// passes through untouched to the SDK Server's receive stream.
final class DualEraStdioTransportTests: XCTestCase {
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
