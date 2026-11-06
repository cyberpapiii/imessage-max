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
        let app = await makeTestTransport().application()
        try await app.test(TestingSetup.router) { client in
            let response = try await client.post(
                modernBody(method: "server/discover"), headers: modernHeaders(method: "server/discover")
            )

            XCTAssertEqual(response.head.status, .ok, String(buffer: response.body))
            let result = try XCTUnwrap(try decodeJSON(from: response.body)["result"] as? [String: Any])
            XCTAssertEqual(result["supportedVersions"] as? [String], ["2026-07-28"])
            XCTAssertEqual(result["resultType"] as? String, "complete")
            // Stateless era: no session is created for modern requests.
            XCTAssertNil(response.head.headerFields[.mcpSessionId])
        }
    }

    func testModernToolsListReturnsFullCatalogWithCacheHints() async throws {
        let app = await makeTestTransport().application()
        try await app.test(TestingSetup.router) { client in
            let response = try await client.post(modernBody(method: "tools/list"), headers: modernHeaders(method: "tools/list"))

            XCTAssertEqual(response.head.status, .ok, String(buffer: response.body))
            let result = try XCTUnwrap(try decodeJSON(from: response.body)["result"] as? [String: Any])
            XCTAssertEqual(result["resultType"] as? String, "complete")
            XCTAssertNotNil(result["ttlMs"] as? Int)
            XCTAssertEqual(result["cacheScope"] as? String, "private")
            let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
            XCTAssertEqual(tools.count, 13)
            XCTAssertTrue(tools.contains { $0["name"] as? String == "send" })
            XCTAssertNil(response.head.headerFields[.mcpSessionId])
        }
    }

    func testModernToolCallWithMcpNameHeader() async throws {
        let app = await makeTestTransport().application()
        try await app.test(TestingSetup.router) { client in
            let response = try await client.post(
                modernBody(method: "tools/call", params: #""name":"diagnose","arguments":{}"#),
                headers: modernHeaders(method: "tools/call", name: "diagnose")
            )

            XCTAssertEqual(response.head.status, .ok, String(buffer: response.body))
            let result = try XCTUnwrap(try decodeJSON(from: response.body)["result"] as? [String: Any])
            XCTAssertEqual(result["resultType"] as? String, "complete")
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            XCTAssertEqual(content.first?["type"] as? String, "text")
        }
    }

    func testModernToolCallAcceptsBase64SentinelName() async throws {
        let app = await makeTestTransport().application()
        try await app.test(TestingSetup.router) { client in
            let sentinel = "=?base64?" + Data("diagnose".utf8).base64EncodedString() + "?="
            let response = try await client.post(
                modernBody(method: "tools/call", params: #""name":"diagnose","arguments":{}"#),
                headers: modernHeaders(method: "tools/call", name: sentinel)
            )

            XCTAssertEqual(response.head.status, .ok, String(buffer: response.body))
        }
    }

    // MARK: - Header validation (-32020 HeaderMismatch)

    func testMissingMcpMethodHeaderIsHeaderMismatch() async throws {
        var headers = modernHeaders(method: "tools/list")
        headers[.mcpMethod] = nil
        try await assertHeaderMismatch(body: modernBody(method: "tools/list"), headers: headers)
    }

    func testMcpMethodHeaderBodyMismatchIsHeaderMismatch() async throws {
        try await assertHeaderMismatch(body: modernBody(method: "tools/list"), headers: modernHeaders(method: "server/discover"))
    }

    func testMissingProtocolVersionHeaderIsHeaderMismatch() async throws {
        var headers = modernHeaders(method: "tools/list")
        headers[.mcpProtocolVersion] = nil
        try await assertHeaderMismatch(body: modernBody(method: "tools/list"), headers: headers)
    }

    func testProtocolVersionHeaderBodyMismatchIsHeaderMismatch() async throws {
        try await assertHeaderMismatch(
            body: modernBody(method: "tools/list", version: "2027-01-01"),
            headers: modernHeaders(method: "tools/list", version: "2026-07-28")
        )
    }

    func testMcpNameHeaderBodyMismatchIsHeaderMismatch() async throws {
        try await assertHeaderMismatch(
            body: modernBody(method: "tools/call", params: #""name":"diagnose","arguments":{}"#),
            headers: modernHeaders(method: "tools/call", name: "search")
        )
    }

    // MARK: - Version negotiation and routing over the wire

    func testUnsupportedVersionReturns32022WithSupportedList() async throws {
        let app = await makeTestTransport().application()
        try await app.test(TestingSetup.router) { client in
            let response = try await client.post(
                modernBody(method: "tools/list", version: "2027-01-01"),
                headers: modernHeaders(method: "tools/list", version: "2027-01-01")
            )

            XCTAssertEqual(response.head.status, .badRequest)
            let error = try XCTUnwrap(try decodeJSON(from: response.body)["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, -32022)
            let data = try XCTUnwrap(error["data"] as? [String: Any])
            XCTAssertEqual(data["supported"] as? [String], ["2026-07-28"])
        }
    }

    func testModernNotificationReturns202NoBody() async throws {
        let app = await makeTestTransport().application()
        try await app.test(TestingSetup.router) { client in
            let response = try await client.post(
                modernBody(id: nil, method: "notifications/cancelled", params: #""requestId":9"#),
                headers: modernHeaders(method: "notifications/cancelled")
            )

            XCTAssertEqual(response.head.status, .accepted)
            XCTAssertEqual(response.body.readableBytes, 0)
        }
    }

    // MARK: - Dual-era coexistence

    /// plug, a legacy client, sends Mcp-Method and MCP-Protocol-Version
    /// headers on legacy session traffic. Header presence does not reroute
    /// a legacy-body request to the modern lane; only modern `_meta` in the
    /// body (or server/discover) selects the era.
    func testLegacyRequestWithModernHeadersStaysOnLegacyLane() async throws {
        let app = await makeTestTransport().application()
        try await app.test(TestingSetup.router) { client in
            let sessionId = try await client.initializeSession(protocolVersion: "2025-11-25")

            var headers = jsonHeaders(sessionId: sessionId, protocolVersion: "2025-11-25")
            headers[.mcpMethod] = "tools/list"
            let tools = try await client.post(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#, headers: headers)

            XCTAssertEqual(tools.head.status, .ok, String(buffer: tools.body))
            let result = try XCTUnwrap(try decodeJSON(from: tools.body)["result"] as? [String: Any])
            let toolList = try XCTUnwrap(result["tools"] as? [[String: Any]])
            XCTAssertEqual(toolList.count, 13)
        }
    }

    /// `initialize` always selects the legacy lane, even when its body
    /// carries the modern per-request `_meta`.
    func testInitializeWithModernMetaInBodyStaysLegacy() async throws {
        let app = await makeTestTransport().application()
        try await app.test(TestingSetup.router) { client in
            let initialize = try await client.post(
                modernBody(
                    method: "initialize",
                    params: #""protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"plug-shape","version":"1.0"}"#
                )
            )

            XCTAssertEqual(initialize.head.status, .ok, String(buffer: initialize.body))
            XCTAssertNotNil(initialize.head.headerFields[.mcpSessionId], "initialize must create a legacy session")
            let json = try decodeJSON(from: initialize.body)
            XCTAssertNil(json["error"])
            let result = try XCTUnwrap(json["result"] as? [String: Any])
            XCTAssertEqual(result["protocolVersion"] as? String, "2025-11-25", "the legacy SDK initialize result")
        }
    }

    func testLegacySessionFlowStillWorksAlongsideModernRequests() async throws {
        let app = await makeTestTransport().application()
        try await app.test(TestingSetup.router) { client in
            let discover = try await client.post(
                modernBody(method: "server/discover"), headers: modernHeaders(method: "server/discover")
            )
            XCTAssertEqual(discover.head.status, .ok)

            let sessionId = try await client.initializeSession(protocolVersion: "2025-11-25")
            let tools = try await client.post(
                #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#,
                headers: jsonHeaders(sessionId: sessionId, protocolVersion: "2025-11-25")
            )
            XCTAssertEqual(tools.head.status, .ok)
            let result = try XCTUnwrap(try decodeJSON(from: tools.body)["result"] as? [String: Any])
            let toolList = try XCTUnwrap(result["tools"] as? [[String: Any]])
            XCTAssertEqual(toolList.count, 13)
        }
    }
}

/// POSTs `body` and expects a 400 carrying HeaderMismatch (-32020).
private func assertHeaderMismatch(
    body: String,
    headers: HTTPFields,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    let app = await makeTestTransport().application()
    try await app.test(TestingSetup.router) { client in
        let response = try await client.post(body, headers: headers)
        XCTAssertEqual(response.head.status, .badRequest, file: file, line: line)
        let error = try XCTUnwrap(try decodeJSON(from: response.body)["error"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(error["code"] as? Int, -32020, file: file, line: line)
    }
}
