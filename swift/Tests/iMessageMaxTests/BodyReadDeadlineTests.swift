import XCTest
import Hummingbird
import NIOCore
@testable import iMessageMax

final class BodyReadDeadlineTests: XCTestCase {
    func testStalledBodyReturnsTimedOutWithinDeadline() async throws {
        let (body, source) = RequestBody.makeStream()
        let producer = Task {
            await source.yield(ByteBuffer(bytes: [0x7b]))  // "{" then silence
            // Never finish. The collector must give up on its own.
        }
        let start = ContinuousClock.now
        let result = try await HTTPRequestParsing.collectBodyDrainingOverflow(
            body,
            declaredLength: 64,
            maxBytes: HTTPTransport.maxRequestBodyBytes,
            drainLimit: HTTPTransport.overLimitDrainBytes,
            deadline: .milliseconds(200)
        )
        let elapsed = ContinuousClock.now - start
        guard case .timedOut = result else { return XCTFail("Expected .timedOut, got \(result)") }
        XCTAssertLessThan(elapsed, .seconds(2))
        source.finish()
        await producer.value
    }

    func testCompleteBodyIsUnaffectedByDeadline() async throws {
        let (body, source) = RequestBody.makeStream()
        let producer = Task {
            await source.yield(ByteBuffer(string: "{}"))
            source.finish()
        }
        let result = try await HTTPRequestParsing.collectBodyDrainingOverflow(
            body, declaredLength: 2,
            maxBytes: HTTPTransport.maxRequestBodyBytes,
            drainLimit: HTTPTransport.overLimitDrainBytes,
            deadline: .seconds(5)
        )
        guard case .complete(let data) = result else { return XCTFail("Expected .complete") }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{}")
        await producer.value
    }
}
