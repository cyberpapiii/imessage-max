import XCTest
import MCP
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
@testable import iMessageMax

/// Streamable HTTP integration tests for the modern era (MCP 2026-07-28):
/// header requirements, header/body consistency, version negotiation over
/// the wire, and coexistence with the legacy session lane on one endpoint.
final class ModernHTTPIntegrationTests: XCTestCase {
    func testDiscoverOverHTTPReturnsSupportedVersions() async throws {
        let app = await makeModernTestTransport().makeApplicationForTesting()
        try await app.test(TestingSetup.router) { client in
            let response = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: modernHeaders(method: "server/discover"),
                body: modernByteBuffer(for: modernPayload(method: "server/discover"))
            )

            let bodyText = try modernDecodeJSONString(from: response.body)
            XCTAssertEqual(response.head.status, .ok, bodyText)
            let json = try modernDecodeJSON(from: response.body)
            let result = try XCTUnwrap(json["result"] as? [String: Any])
            XCTAssertEqual(result["supportedVersions"] as? [String], ["2026-07-28"])
            XCTAssertEqual(result["resultType"] as? String, "complete")
            // Stateless era: no session is created for modern requests.
            XCTAssertNil(response.head.headerFields[.mcpSessionId])
        }
    }

    func testModernToolsListReturnsFullCatalogWithCacheHints() async throws {
        let app = await makeModernTestTransport().makeApplicationForTesting()
        try await app.test(TestingSetup.router) { client in
            let response = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: modernHeaders(method: "tools/list"),
                body: modernByteBuffer(for: modernPayload(method: "tools/list"))
            )

            let bodyText = try modernDecodeJSONString(from: response.body)
            XCTAssertEqual(response.head.status, .ok, bodyText)
            let json = try modernDecodeJSON(from: response.body)
            let result = try XCTUnwrap(json["result"] as? [String: Any])
            XCTAssertEqual(result["resultType"] as? String, "complete")
            XCTAssertNotNil(result["ttlMs"] as? Int)
            XCTAssertEqual(result["cacheScope"] as? String, "private")
            let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
            XCTAssertEqual(tools.count, 12)
            XCTAssertTrue(tools.contains { $0["name"] as? String == "send" })
            XCTAssertNil(response.head.headerFields[.mcpSessionId])
        }
    }

    func testModernToolCallWithMcpNameHeader() async throws {
        let app = await makeModernTestTransport().makeApplicationForTesting()
        try await app.test(TestingSetup.router) { client in
            let response = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: modernHeaders(method: "tools/call", name: "diagnose"),
                body: modernByteBuffer(
                    for: modernPayload(
                        method: "tools/call",
                        extraParams: #""name":"diagnose","arguments":{}"#
                    )
                )
            )

            let bodyText = try modernDecodeJSONString(from: response.body)
            XCTAssertEqual(response.head.status, .ok, bodyText)
            let json = try modernDecodeJSON(from: response.body)
            let result = try XCTUnwrap(json["result"] as? [String: Any])
            XCTAssertEqual(result["resultType"] as? String, "complete")
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            XCTAssertEqual(content.first?["type"] as? String, "text")
        }
    }

    func testModernToolCallAcceptsBase64SentinelName() async throws {
        let app = await makeModernTestTransport().makeApplicationForTesting()
        try await app.test(TestingSetup.router) { client in
            let sentinel = "=?base64?" + Data("diagnose".utf8).base64EncodedString() + "?="
            let response = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: modernHeaders(method: "tools/call", name: sentinel),
                body: modernByteBuffer(
                    for: modernPayload(
                        method: "tools/call",
                        extraParams: #""name":"diagnose","arguments":{}"#
                    )
                )
            )

            let bodyText = try modernDecodeJSONString(from: response.body)
            XCTAssertEqual(response.head.status, .ok, bodyText)
        }
    }

    // MARK: - Header validation (-32020 HeaderMismatch)

    func testMissingMcpMethodHeaderIsHeaderMismatch() async throws {
        let app = await makeModernTestTransport().makeApplicationForTesting()
        try await app.test(TestingSetup.router) { client in
            var headers = modernHeaders(method: "tools/list")
            headers[.mcpMethod] = nil
            let response = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: headers,
                body: modernByteBuffer(for: modernPayload(method: "tools/list"))
            )

            try assertHeaderMismatch(response)
        }
    }

    func testMcpMethodHeaderBodyMismatchIsHeaderMismatch() async throws {
        let app = await makeModernTestTransport().makeApplicationForTesting()
        try await app.test(TestingSetup.router) { client in
            let response = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: modernHeaders(method: "server/discover"),
                body: modernByteBuffer(for: modernPayload(method: "tools/list"))
            )

            try assertHeaderMismatch(response)
        }
    }

    func testMissingProtocolVersionHeaderIsHeaderMismatch() async throws {
        let app = await makeModernTestTransport().makeApplicationForTesting()
        try await app.test(TestingSetup.router) { client in
            var headers = modernHeaders(method: "tools/list")
            headers[.mcpProtocolVersion] = nil
            let response = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: headers,
                body: modernByteBuffer(for: modernPayload(method: "tools/list"))
            )

            try assertHeaderMismatch(response)
        }
    }

    func testProtocolVersionHeaderBodyMismatchIsHeaderMismatch() async throws {
        let app = await makeModernTestTransport().makeApplicationForTesting()
        try await app.test(TestingSetup.router) { client in
            var headers = modernHeaders(method: "tools/list")
            headers[.mcpProtocolVersion] = "2026-07-28"
            let response = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: headers,
                body: modernByteBuffer(for: modernPayload(method: "tools/list", version: "2027-01-01"))
            )

            try assertHeaderMismatch(response)
        }
    }

    func testMcpNameHeaderBodyMismatchIsHeaderMismatch() async throws {
        let app = await makeModernTestTransport().makeApplicationForTesting()
        try await app.test(TestingSetup.router) { client in
            let response = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: modernHeaders(method: "tools/call", name: "search"),
                body: modernByteBuffer(
                    for: modernPayload(
                        method: "tools/call",
                        extraParams: #""name":"diagnose","arguments":{}"#
                    )
                )
            )

            try assertHeaderMismatch(response)
        }
    }

    // MARK: - Version negotiation and routing over the wire

    func testUnsupportedVersionReturns32022WithSupportedList() async throws {
        let app = await makeModernTestTransport().makeApplicationForTesting()
        try await app.test(TestingSetup.router) { client in
            var headers = modernHeaders(method: "tools/list")
            headers[.mcpProtocolVersion] = "2027-01-01"
            let response = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: headers,
                body: modernByteBuffer(for: modernPayload(method: "tools/list", version: "2027-01-01"))
            )

            XCTAssertEqual(response.head.status, .badRequest)
            let json = try modernDecodeJSON(from: response.body)
            let error = try XCTUnwrap(json["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, -32022)
            let data = try XCTUnwrap(error["data"] as? [String: Any])
            XCTAssertEqual(data["supported"] as? [String], ["2026-07-28"])
        }
    }

    func testUnknownModernMethodReturns404MethodNotFound() async throws {
        let app = await makeModernTestTransport().makeApplicationForTesting()
        try await app.test(TestingSetup.router) { client in
            let response = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: modernHeaders(method: "resources/list"),
                body: modernByteBuffer(for: modernPayload(method: "resources/list"))
            )

            XCTAssertEqual(response.head.status, .notFound)
            let json = try modernDecodeJSON(from: response.body)
            let error = try XCTUnwrap(json["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, -32601)
        }
    }

    func testModernNotificationReturns202NoBody() async throws {
        let app = await makeModernTestTransport().makeApplicationForTesting()
        try await app.test(TestingSetup.router) { client in
            let payload = #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":9,"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#
            let response = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: modernHeaders(method: "notifications/cancelled"),
                body: modernByteBuffer(for: payload)
            )

            XCTAssertEqual(response.head.status, .accepted)
            XCTAssertEqual(response.body.readableBytes, 0)
        }
    }

    // MARK: - Dual-era coexistence

    /// Regression: plug (a real legacy client) sends Mcp-Method and
    /// MCP-Protocol-Version headers on legacy session traffic. Header
    /// presence must NOT reroute a legacy-body request to the modern lane;
    /// only modern `_meta` in the body (or server/discover) selects the era.
    func testLegacyRequestWithModernHeadersStaysOnLegacyLane() async throws {
        let app = await makeModernTestTransport().makeApplicationForTesting()
        try await app.test(TestingSetup.router) { client in
            let initialize = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: modernLegacyHeaders(),
                body: modernByteBuffer(
                    for: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"plug-shape","version":"1.0"}}}"#
                )
            )
            let sessionId = try XCTUnwrap(initialize.head.headerFields[.mcpSessionId])

            var headers = modernLegacyHeaders()
            headers[.mcpSessionId] = sessionId
            headers[.mcpProtocolVersion] = "2025-11-25"
            headers[.mcpMethod] = "tools/list"
            let tools = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: headers,
                body: modernByteBuffer(for: #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#)
            )

            let bodyText = try modernDecodeJSONString(from: tools.body)
            XCTAssertEqual(tools.head.status, .ok, bodyText)
            let json = try modernDecodeJSON(from: tools.body)
            let result = try XCTUnwrap(json["result"] as? [String: Any])
            let toolList = try XCTUnwrap(result["tools"] as? [[String: Any]])
            XCTAssertEqual(toolList.count, 12)
        }
    }

    /// Regression: an `initialize` request whose BODY carries the modern
    /// per-request `_meta` protocolVersion key must still be routed to the
    /// legacy SDK handshake, not the modern dispatcher. `initialize` always
    /// selects the legacy lane regardless of what `_meta` it carries.
    func testInitializeWithModernMetaInBodyStaysLegacy() async throws {
        let app = await makeModernTestTransport().makeApplicationForTesting()
        try await app.test(TestingSetup.router) { client in
            let initialize = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: modernLegacyHeaders(),
                body: modernByteBuffer(
                    for: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"plug-shape","version":"1.0"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#
                )
            )

            let bodyText = try modernDecodeJSONString(from: initialize.body)
            XCTAssertEqual(initialize.head.status, .ok, bodyText)
            XCTAssertNotNil(
                initialize.head.headerFields[.mcpSessionId],
                "initialize with modern _meta in the body must still create a legacy session"
            )
            let json = try modernDecodeJSON(from: initialize.body)
            XCTAssertNil(json["error"], "initialize with modern _meta must not be a dispatcher error")
            let result = try XCTUnwrap(json["result"] as? [String: Any])
            XCTAssertEqual(
                result["protocolVersion"] as? String, "2025-11-25",
                "response must be the legacy SDK initialize result, not a modern-lane result"
            )
        }
    }

    func testLegacySessionFlowStillWorksAlongsideModernRequests() async throws {
        let app = await makeModernTestTransport().makeApplicationForTesting()
        try await app.test(TestingSetup.router) { client in
            // Modern request first (would previously have hit an empty catalog).
            let discover = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: modernHeaders(method: "server/discover"),
                body: modernByteBuffer(for: modernPayload(method: "server/discover"))
            )
            XCTAssertEqual(discover.head.status, .ok)

            // Legacy handshake on the same endpoint remains untouched.
            let initialize = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: modernLegacyHeaders(),
                body: modernByteBuffer(
                    for: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"tests","version":"1.0"}}}"#
                )
            )
            let initializeBody = try modernDecodeJSONString(from: initialize.body)
            XCTAssertEqual(initialize.head.status, .ok, initializeBody)
            let sessionId = try XCTUnwrap(initialize.head.headerFields[.mcpSessionId])

            var toolsHeaders = modernLegacyHeaders()
            toolsHeaders[.mcpSessionId] = sessionId
            toolsHeaders[.mcpProtocolVersion] = "2025-11-25"
            let tools = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: toolsHeaders,
                body: modernByteBuffer(for: #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#)
            )
            XCTAssertEqual(tools.head.status, .ok)
            let json = try modernDecodeJSON(from: tools.body)
            let result = try XCTUnwrap(json["result"] as? [String: Any])
            let toolList = try XCTUnwrap(result["tools"] as? [[String: Any]])
            XCTAssertEqual(toolList.count, 12)
        }
    }
}

// MARK: - Helpers (file-private free functions so @Sendable test closures
// don't capture the XCTestCase instance)

private func makeModernTestTransport() -> HTTPTransport {
    HTTPTransport(
        host: "127.0.0.1",
        port: 0,
        database: Database(),
        resolver: ContactResolver(seedCache: [:]),
        requestTimeout: .seconds(5)
    )
}

private func modernLegacyHeaders() -> HTTPFields {
    [
        .contentType: "application/json",
        .accept: "application/json, text/event-stream",
    ]
}

private func modernHeaders(
    method: String,
    name: String? = nil,
    version: String = "2026-07-28"
) -> HTTPFields {
    var headers = modernLegacyHeaders()
    headers[.mcpProtocolVersion] = version
    headers[.mcpMethod] = method
    if let name {
        headers[.mcpName] = name
    }
    return headers
}

private func modernPayload(
    id: Int = 1,
    method: String,
    version: String = "2026-07-28",
    extraParams: String = ""
) -> String {
    let extra = extraParams.isEmpty ? "" : "\(extraParams),"
    return #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":{\#(extra)"_meta":{"io.modelcontextprotocol/protocolVersion":"\#(version)","io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/clientInfo":{"name":"modern-tests","version":"1.0"}}}}"#
}

private func modernByteBuffer(for string: String) -> ByteBuffer {
    ByteBuffer(string: string)
}

private func modernDecodeJSONString(from buffer: ByteBuffer) throws -> String {
    var body = buffer
    return try XCTUnwrap(body.readString(length: body.readableBytes))
}

private func modernDecodeJSON(from buffer: ByteBuffer) throws -> [String: Any] {
    let body = try modernDecodeJSONString(from: buffer)
    return try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
    )
}

private func assertHeaderMismatch(
    _ response: TestResponse,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    XCTAssertEqual(response.head.status, .badRequest, file: file, line: line)
    let json = try modernDecodeJSON(from: response.body)
    let error = try XCTUnwrap(json["error"] as? [String: Any], file: file, line: line)
    XCTAssertEqual(error["code"] as? Int, -32020, file: file, line: line)
}
