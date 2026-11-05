import Foundation
import XCTest
import MCP
@testable import iMessageMax

/// Unit tests for the MCP 2026-07-28 modern-era dispatcher: per-request
/// `_meta` validation, version negotiation, discovery, catalog cache hints,
/// deterministic ordering, and protocol/tool error separation.
final class ModernDispatcherTests: XCTestCase {
    private var definitions: [ToolDefinition] = []
    private var catalog: ToolCatalog { ToolCatalog(definitions) }

    // MARK: - Era detection

    func testModernMessageDetection() throws {
        XCTAssertTrue(isModern(try json(discoverPayload())))
        XCTAssertTrue(
            isModern(try json(modernRequest(method: "tools/list")))
        )
        XCTAssertFalse(
            isModern(try json(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#.utf8)))
        )
        XCTAssertFalse(
            isModern(try json(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#.utf8)))
        )
        XCTAssertFalse(
            isModern(try json(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)))
        )
    }

    // MARK: - server/discover

    func testDiscoverReturnsSupportedVersionsCapabilitiesAndCacheHints() async throws {
        let outcome = await dispatch(discoverPayload())
        XCTAssertEqual(HTTPTransport.status(for: outcome).code, 200)
        let result = try result(from: outcome)

        XCTAssertEqual(result["resultType"] as? String, "complete")
        XCTAssertEqual(result["supportedVersions"] as? [String], ["2026-07-28"])
        XCTAssertEqual(result["cacheScope"] as? String, "private")
        XCTAssertNotNil(result["ttlMs"] as? Int)
        XCTAssertNotNil(result["instructions"] as? String)

        let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
        XCTAssertEqual(capabilities.count, 1, "\(capabilities)")
        XCTAssertEqual(capabilities["tools"] as? [String: Bool], ["listChanged": false])

        let meta = try XCTUnwrap(result["_meta"] as? [String: Any])
        let serverInfo = try XCTUnwrap(
            meta["io.modelcontextprotocol/serverInfo"] as? [String: Any]
        )
        XCTAssertEqual(serverInfo["name"] as? String, Version.name)
        XCTAssertEqual(serverInfo["version"] as? String, Version.current)
        XCTAssertEqual(serverInfo["title"] as? String, Version.title)
        XCTAssertNotNil(serverInfo["icons"])
    }

    // MARK: - _meta validation

    func testMissingProtocolVersionIsInvalidParams() async throws {
        let payload = try payloadData([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "server/discover",
            "params": ["_meta": ["io.modelcontextprotocol/clientCapabilities": [:]]],
        ])
        let outcome = await dispatch(payload)
        XCTAssertEqual(HTTPTransport.status(for: outcome).code, 400)
        let error = try error(from: outcome)
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    func testMissingClientCapabilitiesIsInvalidParams() async throws {
        let payload = try payloadData([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
            "params": ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]],
        ])
        let outcome = await dispatch(payload)
        XCTAssertEqual(HTTPTransport.status(for: outcome).code, 400)
        let error = try error(from: outcome)
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertTrue((error["message"] as? String ?? "").contains("clientCapabilities"))
    }

    func testUnsupportedVersionReturnsSupportedList() async throws {
        let outcome = await dispatch(modernRequest(method: "tools/list", protocolVersion: "2027-01-01"))
        XCTAssertEqual(HTTPTransport.status(for: outcome).code, 400)
        let error = try error(from: outcome)
        XCTAssertEqual(error["code"] as? Int, -32022)
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(data["supported"] as? [String], ["2026-07-28"])
        XCTAssertEqual(data["requested"] as? String, "2027-01-01")
    }

    func testUnknownMethodIsMethodNotFoundWith404() async throws {
        for legacyOnlyMethod in ["ping", "logging/setLevel", "subscriptions/listen", "no/such"] {
            let outcome = await dispatch(modernRequest(method: legacyOnlyMethod))
            XCTAssertEqual(HTTPTransport.status(for: outcome).code, 404, legacyOnlyMethod)
            let error = try error(from: outcome)
            XCTAssertEqual(error["code"] as? Int, -32601, legacyOnlyMethod)
        }
    }

    func testNotificationIsAcceptedWithoutBody() async throws {
        let payload = try payloadData([
            "jsonrpc": "2.0",
            "method": "notifications/cancelled",
            "params": [
                "requestId": 7,
                "_meta": modernMeta(),
            ],
        ])
        let outcome = await dispatch(payload)
        XCTAssertEqual(HTTPTransport.status(for: outcome).code, 202)
        XCTAssertNil(outcome.body)
    }

    // MARK: - tools/list

    func testToolsListHasResultTypeCacheHintsAndDeterministicOrder() async throws {
        registerFakeTool(named: "zeta_tool")
        registerFakeTool(named: "alpha_tool")
        registerFakeTool(named: "mid_tool")

        let outcome = await dispatch(modernRequest(method: "tools/list"))
        XCTAssertEqual(HTTPTransport.status(for: outcome).code, 200)
        let result = try result(from: outcome)
        XCTAssertEqual(result["resultType"] as? String, "complete")
        XCTAssertEqual(result["cacheScope"] as? String, "private")
        XCTAssertNotNil(result["ttlMs"] as? Int)

        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        // Registration order, not dictionary order, so clients can cache
        // the catalog.
        XCTAssertEqual(
            tools.map { $0["name"] as? String },
            ["zeta_tool", "alpha_tool", "mid_tool"]
        )
    }

    // MARK: - tools/call

    func testToolCallReturnsCompleteResultWithContentAndStructuredContent() async throws {
        registerFakeTool(named: "modern_echo") { _ in
            [.plainText(#"{"ok":true}"#)]
        }

        let outcome = await dispatch(modernRequest(
                method: "tools/call",
                extraParams: ["name": "modern_echo", "arguments": ["x": 1]]
            ))
        XCTAssertEqual(HTTPTransport.status(for: outcome).code, 200)
        let result = try result(from: outcome)
        XCTAssertEqual(result["resultType"] as? String, "complete")
        XCTAssertNil(result["isError"])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["ok"] as? Bool, true)
        let meta = try XCTUnwrap(result["_meta"] as? [String: Any])
        XCTAssertNotNil(meta["io.modelcontextprotocol/serverInfo"])
    }

    func testToolErrorBecomesIsErrorResultNotProtocolError() async throws {
        registerFakeTool(named: "modern_fail") { _ in
            throw ToolFailure("tool_exploded", "tool exploded")
        }

        let outcome = await dispatch(modernRequest(
                method: "tools/call",
                extraParams: ["name": "modern_fail", "arguments": [:]]
            ))
        // Tool execution failures are results with isError, not JSON-RPC errors.
        XCTAssertEqual(HTTPTransport.status(for: outcome).code, 200)
        let result = try result(from: outcome)
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual(result["resultType"] as? String, "complete")
    }

    func testUnknownToolIsInvalidParams() async throws {
        let outcome = await dispatch(modernRequest(
                method: "tools/call",
                extraParams: ["name": "does_not_exist", "arguments": [:]]
            ))
        XCTAssertEqual(HTTPTransport.status(for: outcome).code, 400)
        let error = try error(from: outcome)
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    // MARK: - Base64 sentinel

    func testBase64SentinelDecoding() {
        XCTAssertEqual(HTTPRequestParsing.decodeBase64Sentinel("plain"), "plain")
        let encoded = "=?base64?" + Data("héllo".utf8).base64EncodedString() + "?="
        XCTAssertEqual(HTTPRequestParsing.decodeBase64Sentinel(encoded), "héllo")
        XCTAssertEqual(HTTPRequestParsing.decodeBase64Sentinel("=?base64?!!?="), "=?base64?!!?=")
    }

    // MARK: - Catalog cache

    func testCatalogCacheServesConsistentResultAcrossCalls() async throws {
        registerFakeTool(named: "zeta_tool")
        registerFakeTool(named: "alpha_tool")
        registerFakeTool(named: "mid_tool")

        let firstOutcome = await dispatch(modernRequest(method: "tools/list"))
        let secondOutcome = await dispatch(modernRequest(method: "tools/list"))

        let firstTools = try XCTUnwrap(try result(from: firstOutcome)["tools"] as? [[String: Any]])
        let secondTools = try XCTUnwrap(try result(from: secondOutcome)["tools"] as? [[String: Any]])

        XCTAssertEqual(
            firstTools.map { $0["name"] as? String },
            secondTools.map { $0["name"] as? String }
        )
        XCTAssertEqual(
            secondTools.map { $0["name"] as? String },
            ["zeta_tool", "alpha_tool", "mid_tool"]
        )
    }

    // MARK: - Log sanitization

    func testLogFieldSanitization() {
        // A newline would let a client forge whole log lines.
        XCTAssertEqual(Log.sanitizedField("evil\nname"), "evilname")
        XCTAssertEqual(Log.sanitizedField("tab\there\r\n"), "tabhere")

        // Unbounded input is clamped so a client cannot flood the service log.
        let long = String(repeating: "a", count: 300)
        XCTAssertEqual(Log.sanitizedField(long).count, 64)

        XCTAssertEqual(Log.sanitizedField("plug/1.2.3"), "plug/1.2.3")
    }

    func testSerializeFallbackPreservesScalarId() {
        // The correlation rule behind the id-preserving fallback: a client
        // waiting on id 7 must not receive an id:null envelope.
        XCTAssertEqual(JSONRPC.fallbackId(for: 7) as? Int, 7)
        XCTAssertEqual(JSONRPC.fallbackId(for: "req-7") as? String, "req-7")
        XCTAssertTrue(JSONRPC.fallbackId(for: nil) is NSNull)
        // Non-scalar ids have no safe echo, so they degrade to null.
        XCTAssertTrue(JSONRPC.fallbackId(for: ["a": 1]) is NSNull)
    }

    // MARK: - Helpers

    private func registerFakeTool(
        named name: String,
        handler: @escaping @Sendable ([String: Value]?) async throws -> [Tool.Content] = { _ in
            [.plainText("ok")]
        }
    ) {
        definitions.append(
            ToolDefinition(name: name, description: "test tool", inputSchema: InputSchema.object(properties: [:]), handler: handler)
        )
    }

    private func modernMeta(protocolVersion: String = "2026-07-28") -> [String: Any] {
        [
            "io.modelcontextprotocol/protocolVersion": protocolVersion,
            "io.modelcontextprotocol/clientCapabilities": [:],
            "io.modelcontextprotocol/clientInfo": ["name": "test-client", "version": "1.0"],
        ]
    }

    private func modernRequest(
        method: String,
        protocolVersion: String = "2026-07-28",
        extraParams: [String: Any] = [:]
    ) -> Data {
        var params = extraParams
        params["_meta"] = modernMeta(protocolVersion: protocolVersion)
        return (try? payloadData([
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params,
        ])) ?? Data()
    }

    private func discoverPayload() -> Data {
        modernRequest(method: "server/discover")
    }

    private func dispatch(_ data: Data) async -> ModernReply {
        guard case .message(let message) = JSONRPCMessage.parse(data) else {
            XCTFail("payload is not a JSON object")
            return .accepted
        }
        return await ModernDispatcher.handle(message, transport: "test", catalog: catalog)
    }

    private func isModern(_ object: [String: Any]) -> Bool {
        JSONRPCMessage(object).era == .modern
    }

    private func payloadData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func result(from outcome: ModernReply) throws -> [String: Any] {
        let envelope = try json(XCTUnwrap(outcome.body))
        return try XCTUnwrap(envelope["result"] as? [String: Any])
    }

    private func error(from outcome: ModernReply) throws -> [String: Any] {
        let envelope = try json(XCTUnwrap(outcome.body))
        return try XCTUnwrap(envelope["error"] as? [String: Any])
    }
}
