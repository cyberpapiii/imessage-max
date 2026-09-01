import XCTest
import Hummingbird
import HTTPTypes
import Logging
import NIOCore
import NIOEmbedded
@testable import iMessageMax

/// Characterization tests for the host-parsing branches of
/// `OriginValidationMiddleware`, the DNS-rebinding defense. The existing
/// integration test only exercises authorities "localhost" and "example.com";
/// these pin the port-stripping and IPv6 branches.
final class OriginHostParsingTests: XCTestCase {

    private func makeContext() -> BasicRequestContext {
        BasicRequestContext(
            source: ApplicationRequestContextSource(
                channel: EmbeddedChannel(),
                logger: Logger(label: #function)
            )
        )
    }

    private func makeRequest(authority: String, origin: String?) -> Request {
        var headers = HTTPFields()
        if let origin {
            headers[HTTPField.Name("Origin")!] = origin
        }
        return Request(
            head: .init(
                method: .post,
                scheme: "http",
                authority: authority,
                path: "/",
                headerFields: headers
            ),
            body: .init(buffer: ByteBuffer())
        )
    }

    private func status(
        forAuthority authority: String,
        origin: String? = nil,
        middleware: OriginValidationMiddleware<BasicRequestContext> = .init()
    ) async throws -> HTTPResponse.Status {
        let response = try await middleware.handle(
            makeRequest(authority: authority, origin: origin),
            context: makeContext()
        ) { _, _ in
            Response(status: .ok)
        }
        return response.head.status
    }

    /// Drains a middleware `Response` body into a String.
    private func bodyString(of response: Response) async throws -> String {
        let box = ByteBufferBox()
        try await response.body.write(CollectingWriter(box: box))
        return String(buffer: box.buffer)
    }

    func testAllowedHostsWithPortAreAccepted() async throws {
        for authority in ["localhost:8080", "127.0.0.1:8080", "[::1]:8080"] {
            let status = try await status(forAuthority: authority)
            XCTAssertEqual(status, .ok, "authority: \(authority)")
        }
    }

    func testAllowedHostsWithoutPortAreAccepted() async throws {
        // "::1" (bare) is in the default allowedHosts alongside "[::1]", and the
        // multi-colon branch leaves it untouched, so it is accepted.
        for authority in ["localhost", "127.0.0.1", "[::1]", "::1"] {
            let status = try await status(forAuthority: authority)
            XCTAssertEqual(status, .ok, "authority: \(authority)")
        }
    }

    func testDisallowedHostsWithPortAreRejected() async throws {
        for authority in ["evil.example:8080", "evil.example", "[2001:db8::1]:8080", "10.0.0.1:8080"] {
            let status = try await status(forAuthority: authority)
            XCTAssertEqual(status, .forbidden, "authority: \(authority)")
        }
    }

    func testNonNumericPortSuffixIsNotStripped() async throws {
        let status = try await status(forAuthority: "localhost:notaport")
        XCTAssertEqual(status, .forbidden, "a non-numeric suffix keeps the whole authority, which is not an allowed host")
    }

    func testMissingOriginIsAllowedByDefault() async throws {
        let status = try await status(forAuthority: "localhost", origin: nil)
        XCTAssertEqual(status, .ok)
    }

    func testRequireOriginRejectsMissingOrigin() async throws {
        let middleware = OriginValidationMiddleware<BasicRequestContext>(requireOrigin: true)
        let response = try await middleware.handle(
            makeRequest(authority: "localhost", origin: nil),
            context: makeContext()
        ) { _, _ in
            XCTFail("A missing Origin in strict mode should not reach the next handler")
            return Response(status: .ok)
        }
        XCTAssertEqual(response.head.status, .forbidden)

        let body = try await bodyString(of: response)
        XCTAssertTrue(body.contains("Origin header required"), "body: \(body)")
    }
}

// MARK: - Body collection helpers

private final class ByteBufferBox: @unchecked Sendable {
    var buffer = ByteBuffer()
}

private struct CollectingWriter: ResponseBodyWriter {
    let box: ByteBufferBox

    mutating func write(_ buffer: ByteBuffer) async throws {
        var copy = buffer
        box.buffer.writeBuffer(&copy)
    }

    consuming func finish(_ trailingHeaders: HTTPFields?) async throws {}
}
