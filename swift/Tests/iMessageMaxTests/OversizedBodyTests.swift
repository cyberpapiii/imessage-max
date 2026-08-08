import XCTest
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
@testable import iMessageMax

/// Oversized POST bodies must return 413 and leave the request body fully
/// consumed. The old `collect(upTo:)` path threw with megabytes unread; for
/// `Connection: close` clients (Python urllib default) Hummingbird's HTTP1
/// loop then blocked on channel close with reads back-pressured off, leaking
/// one server FD per oversized request.
final class OversizedBodyTests: XCTestCase {
    private let maxBytes = HTTPTransport.maxRequestBodyBytes
    private let drainLimit = HTTPTransport.overLimitDrainBytes

    /// The core regression: on overflow the helper keeps consuming the body
    /// stream to the end. If it stops early, the producer below suspends on
    /// back-pressure and this test hangs rather than passes.
    func testOverflowDrainsRemainingBody() async throws {
        let (body, source) = RequestBody.makeStream()
        let chunk = ByteBuffer(repeating: 0x78, count: 64 * 1024)
        let chunkCount = 24  // 1.5 MB total, the confirmed reproducing size

        let producer = Task {
            for _ in 0..<chunkCount {
                await source.yield(chunk)
            }
            source.finish()
        }

        let result = try await HTTPTransport.collectBodyDrainingOverflow(
            body,
            declaredLength: chunk.readableBytes * chunkCount,
            maxBytes: maxBytes,
            drainLimit: drainLimit
        )

        guard case .tooLarge = result else {
            return XCTFail("Expected .tooLarge, got \(result)")
        }

        // All yields must have been consumed; back-pressure (high watermark 4)
        // would otherwise keep the producer suspended forever.
        await producer.value
    }

    func testUnderLimitBodyCollectsCompletely() async throws {
        let (body, source) = RequestBody.makeStream()
        let chunk = ByteBuffer(repeating: 0x79, count: 1024)

        let producer = Task {
            for _ in 0..<4 {
                await source.yield(chunk)
            }
            source.finish()
        }

        let result = try await HTTPTransport.collectBodyDrainingOverflow(
            body,
            declaredLength: 4096,
            maxBytes: maxBytes,
            drainLimit: drainLimit
        )
        await producer.value

        guard case .complete(let data) = result else {
            return XCTFail("Expected .complete, got \(result)")
        }
        XCTAssertEqual(data.count, 4096)
    }

    /// Bodies whose declared length exceeds the drain bound are rejected
    /// without reading anything.
    func testAbsurdDeclaredLengthRejectsWithoutReading() async throws {
        let (body, source) = RequestBody.makeStream()
        defer { source.finish() }

        let result = try await HTTPTransport.collectBodyDrainingOverflow(
            body,
            declaredLength: drainLimit + 1,
            maxBytes: maxBytes,
            drainLimit: drainLimit
        )

        guard case .tooLarge = result else {
            return XCTFail("Expected .tooLarge, got \(result)")
        }
    }

    /// Observable contract unchanged: oversized POST returns HTTP 413 with an
    /// empty body, exactly like the old Hummingbird-converted throw.
    func testOversizedPostReturns413WithEmptyBody() async throws {
        let transport = HTTPTransport(
            host: "127.0.0.1",
            port: 0,
            database: Database(),
            resolver: ContactResolver(seedCache: [:]),
            requestTimeout: .seconds(5)
        )
        let app = await transport.makeApplicationForTesting()

        try await app.test(TestingSetup.router) { client in
            let oversized = ByteBuffer(repeating: 0x7A, count: HTTPTransport.maxRequestBodyBytes + 1)
            let response = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: [
                    .contentType: "application/json",
                    .accept: "application/json, text/event-stream",
                ],
                body: oversized
            )

            XCTAssertEqual(response.head.status, .contentTooLarge)
            XCTAssertEqual(response.body.readableBytes, 0)
        }
    }
}
