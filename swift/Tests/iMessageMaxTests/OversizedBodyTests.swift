import XCTest
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
@testable import iMessageMax

/// Oversized POST bodies must return 413 and leave the request body fully
/// consumed. A body left with megabytes unread blocks Hummingbird's HTTP1
/// loop on channel close for `Connection: close` clients (Python urllib's
/// default), leaking one server FD per oversized request.
final class OversizedBodyTests: XCTestCase {
    private let maxBytes = HTTPRequestParsing.maxRequestBodyBytes
    private let drainLimit = HTTPRequestParsing.overLimitDrainBytes

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

        let result = try await HTTPRequestParsing.collectBodyDrainingOverflow(
            body,
            declaredLength: chunk.readableBytes * chunkCount,
            maxBytes: maxBytes,
            drainLimit: drainLimit,
            deadline: .seconds(30)
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

        let result = try await HTTPRequestParsing.collectBodyDrainingOverflow(
            body,
            declaredLength: 4096,
            maxBytes: maxBytes,
            drainLimit: drainLimit,
            deadline: .seconds(30)
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

        let result = try await HTTPRequestParsing.collectBodyDrainingOverflow(
            body,
            declaredLength: drainLimit + 1,
            maxBytes: maxBytes,
            drainLimit: drainLimit,
            deadline: .seconds(30)
        )

        guard case .tooLarge = result else {
            return XCTFail("Expected .tooLarge, got \(result)")
        }
    }

    /// An oversized POST answers HTTP 413 with an empty body.
    func testOversizedPostReturns413WithEmptyBody() async throws {
        let app = await makeTestTransport().application()

        try await app.test(TestingSetup.router) { client in
            let oversized = ByteBuffer(repeating: 0x7A, count: HTTPRequestParsing.maxRequestBodyBytes + 1)
            let response = try await client.executeRequest(uri: "/", method: .post, headers: jsonHeaders(), body: oversized)

            XCTAssertEqual(response.head.status, .contentTooLarge)
            XCTAssertEqual(response.body.readableBytes, 0)
        }
    }
}
