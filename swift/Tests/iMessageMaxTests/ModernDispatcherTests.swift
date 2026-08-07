import Foundation
import XCTest
import MCP
@testable import iMessageMax

/// Unit tests for the MCP 2026-07-28 modern-era dispatcher: per-request
/// `_meta` validation, version negotiation, discovery, catalog cache hints,
/// deterministic ordering, and protocol/tool error separation.
final class ModernDispatcherTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ToolHandlerRegistry.shared.resetForTesting()
    }

    override func tearDown() {
        ToolHandlerRegistry.shared.resetForTesting()
        super.tearDown()
    }

    // MARK: - Era detection

    func testModernMessageDetection() throws {
        XCTAssertTrue(ModernDispatcher.isModernMessage(try json(discoverPayload())))
        XCTAssertTrue(
            ModernDispatcher.isModernMessage(
                try json(modernRequest(method: "tools/list"))
            )
        )
        XCTAssertFalse(
            ModernDispatcher.isModernMessage(
                try json(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#.utf8))
            )
        )
        XCTAssertFalse(
            ModernDispatcher.isModernMessage(
                try json(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#.utf8))
            )
        )
        // JSON-RPC responses are never modern-lane messages.
        XCTAssertFalse(
            ModernDispatcher.isModernMessage(
                try json(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
            )
        )
    }

    // MARK: - server/discover

    func testDiscoverReturnsSupportedVersionsCapabilitiesAndCacheHints() async throws {
        let outcome = await ModernDispatcher.handle(discoverPayload(), transport: "test")
        XCTAssertEqual(outcome.httpStatus, 200)
        let result = try result(from: outcome)

        XCTAssertEqual(result["resultType"] as? String, "complete")
        XCTAssertEqual(result["supportedVersions"] as? [String], ["2026-07-28"])
        XCTAssertEqual(result["cacheScope"] as? String, "private")
        XCTAssertNotNil(result["ttlMs"] as? Int)
        XCTAssertNotNil(result["instructions"] as? String)

        let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
        XCTAssertNotNil(capabilities["tools"])

        let meta = try XCTUnwrap(result["_meta"] as? [String: Any])
        let serverInfo = try XCTUnwrap(
            meta["io.modelcontextprotocol/serverInfo"] as? [String: Any]
        )
        XCTAssertEqual(serverInfo["name"] as? String, Version.name)
        XCTAssertEqual(serverInfo["version"] as? String, Version.current)
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
        let outcome = await ModernDispatcher.handle(payload, transport: "test")
        XCTAssertEqual(outcome.httpStatus, 400)
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
        let outcome = await ModernDispatcher.handle(payload, transport: "test")
        XCTAssertEqual(outcome.httpStatus, 400)
        let error = try error(from: outcome)
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertTrue((error["message"] as? String ?? "").contains("clientCapabilities"))
    }

    func testUnsupportedVersionReturnsSupportedList() async throws {
        let outcome = await ModernDispatcher.handle(
            modernRequest(method: "tools/list", protocolVersion: "2027-01-01"),
            transport: "test"
        )
        XCTAssertEqual(outcome.httpStatus, 400)
        let error = try error(from: outcome)
        XCTAssertEqual(error["code"] as? Int, -32022)
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(data["supported"] as? [String], ["2026-07-28"])
        XCTAssertEqual(data["requested"] as? String, "2027-01-01")
    }

    func testUnknownMethodIsMethodNotFoundWith404() async throws {
        for legacyOnlyMethod in ["ping", "logging/setLevel", "subscriptions/listen", "no/such"] {
            let outcome = await ModernDispatcher.handle(
                modernRequest(method: legacyOnlyMethod),
                transport: "test"
            )
            XCTAssertEqual(outcome.httpStatus, 404, legacyOnlyMethod)
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
        let outcome = await ModernDispatcher.handle(payload, transport: "test")
        XCTAssertEqual(outcome.httpStatus, 202)
        XCTAssertNil(outcome.data)
    }

    // MARK: - tools/list

    func testToolsListHasResultTypeCacheHintsAndDeterministicOrder() async throws {
        registerFakeTool(named: "zeta_tool")
        registerFakeTool(named: "alpha_tool")
        registerFakeTool(named: "mid_tool")

        let outcome = await ModernDispatcher.handle(
            modernRequest(method: "tools/list"),
            transport: "test"
        )
        XCTAssertEqual(outcome.httpStatus, 200)
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

        let outcome = await ModernDispatcher.handle(
            modernRequest(
                method: "tools/call",
                extraParams: ["name": "modern_echo", "arguments": ["x": 1]]
            ),
            transport: "test"
        )
        XCTAssertEqual(outcome.httpStatus, 200)
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
            throw ToolError(content: [.plainText("tool exploded")])
        }

        let outcome = await ModernDispatcher.handle(
            modernRequest(
                method: "tools/call",
                extraParams: ["name": "modern_fail", "arguments": [:]]
            ),
            transport: "test"
        )
        // Tool execution failures are results with isError, not JSON-RPC errors.
        XCTAssertEqual(outcome.httpStatus, 200)
        let result = try result(from: outcome)
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual(result["resultType"] as? String, "complete")
    }

    func testUnknownToolIsInvalidParams() async throws {
        let outcome = await ModernDispatcher.handle(
            modernRequest(
                method: "tools/call",
                extraParams: ["name": "does_not_exist", "arguments": [:]]
            ),
            transport: "test"
        )
        XCTAssertEqual(outcome.httpStatus, 400)
        let error = try error(from: outcome)
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    // MARK: - Base64 sentinel

    func testBase64SentinelDecoding() {
        XCTAssertEqual(ModernDispatcher.decodeBase64Sentinel("plain"), "plain")
        let encoded = "=?base64?" + Data("héllo".utf8).base64EncodedString() + "?="
        XCTAssertEqual(ModernDispatcher.decodeBase64Sentinel(encoded), "héllo")
        // Invalid base64 falls back to the literal value.
        XCTAssertEqual(ModernDispatcher.decodeBase64Sentinel("=?base64?!!?="), "=?base64?!!?=")
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

    private func payloadData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func result(from outcome: ModernDispatchResult) throws -> [String: Any] {
        let envelope = try json(XCTUnwrap(outcome.data))
        return try XCTUnwrap(envelope["result"] as? [String: Any])
    }

    private func error(from outcome: ModernDispatchResult) throws -> [String: Any] {
        let envelope = try json(XCTUnwrap(outcome.data))
        return try XCTUnwrap(envelope["error"] as? [String: Any])
    }
}
