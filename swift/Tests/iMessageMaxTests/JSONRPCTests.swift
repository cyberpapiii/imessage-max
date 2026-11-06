import XCTest
import IMessageMaxContract
import MCP
@testable import iMessageMax

final class JSONRPCTests: XCTestCase {

    func testParseSeparatesBatchesAndNonObjects() {
        guard case .batch = JSONRPCMessage.parse(Data(#" [{"jsonrpc":"2.0","id":1,"method":"ping"}]"#.utf8)) else {
            return XCTFail("a leading [ is a batch")
        }
        guard case .invalid = JSONRPCMessage.parse(Data("not json".utf8)) else {
            return XCTFail("non-JSON is invalid")
        }
        guard case .invalid = JSONRPCMessage.parse(Data("42".utf8)) else {
            return XCTFail("a JSON scalar is invalid")
        }
    }

    func testKindFollowsMethodIdAndResult() {
        XCTAssertEqual(JSONRPCMessage(["method": "ping", "id": 1]).kind, .request)
        XCTAssertEqual(JSONRPCMessage(["method": "ping", "id": NSNull()]).kind, .request)
        XCTAssertEqual(JSONRPCMessage(["method": "notifications/initialized"]).kind, .notification)
        XCTAssertEqual(JSONRPCMessage(["id": 1, "result": [:]]).kind, .response)
        XCTAssertEqual(JSONRPCMessage(["id": 1, "error": [:]]).kind, .response)
        XCTAssertEqual(JSONRPCMessage([:]).kind, .notification)
    }

    func testInitializeStaysLegacyWhateverItsMeta() {
        let meta = [ModernMetaKey.protocolVersion: "2026-07-28"]
        XCTAssertEqual(JSONRPCMessage(["method": "initialize", "id": 1, "params": ["_meta": meta]]).era, .legacy)
        XCTAssertEqual(JSONRPCMessage(["method": "tools/list", "id": 1, "params": ["_meta": meta]]).era, .modern)
        XCTAssertEqual(JSONRPCMessage(["method": "server/discover", "id": 1]).era, .modern)
        XCTAssertEqual(JSONRPCMessage(["method": "tools/list", "id": 1]).era, .legacy)
    }

    func testErrorEnvelopeHasFixedLayout() {
        XCTAssertEqual(
            String(decoding: JSONRPC.error(id: nil, code: .invalidRequest, message: "Origin not allowed"), as: UTF8.self),
            #"{"jsonrpc":"2.0","error":{"code":-32600,"message":"Origin not allowed"},"id":null}"#
        )
        XCTAssertEqual(
            String(decoding: JSONRPC.error(id: 7, code: .methodNotFound, message: "Method not found: ping"), as: UTF8.self),
            #"{"jsonrpc":"2.0","error":{"code":-32601,"message":"Method not found: ping"},"id":7}"#
        )
    }

    func testErrorEnvelopeEncodesClientText() throws {
        let hostile = #"bad\"},"id":1,"x":"\#n"#
        let data = JSONRPC.error(id: "req\"1", code: .invalidRequest, message: hostile, data: ["detail": hostile])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["message"] as? String, hostile)
        XCTAssertEqual((error["data"] as? [String: Any])?["detail"] as? String, hostile)
        XCTAssertEqual(object["id"] as? String, "req\"1")
    }

    func testLegacyEraLineSkipsToolCallsAndSanitizes() {
        let lines = captureLog {
            EraLog.legacy(JSONRPCMessage(["method": "tools/call", "id": 1]), transport: "http", version: "2025-11-25", session: "ABCDEF0123456789")
            EraLog.legacy(JSONRPCMessage(["method": "tools/list", "id": 2]), transport: "http", version: "2025-11-25", session: "ABCDEF0123456789")
            EraLog.legacy(JSONRPCMessage(["method": "evil\nINFO forged", "id": 3]), transport: "stdio", version: "legacy")
            EraLog.legacy(nil, transport: "stdio", version: "legacy")
        }
        XCTAssertEqual(lines, [
            "era=legacy transport=http version=2025-11-25 method=tools/list session=ABCDEF01",
            "era=legacy transport=stdio version=legacy method=evilINFO forged",
            "era=legacy transport=stdio version=legacy method=unknown",
        ])
    }

    func testModernEraLineNamesTheClient() {
        let message = JSONRPCMessage([
            "method": "tools/call", "id": 1,
            "params": ["_meta": [ModernMetaKey.clientInfo: ["name": "plug", "version": "1.2"]]],
        ])
        let lines = captureLog { EraLog.modern(message, transport: "http", version: "2026-07-28") }
        XCTAssertEqual(lines, ["era=modern transport=http version=2026-07-28 method=tools/call client=plug/1.2"])
    }

    func testLegacyNegotiationMatchesTheSDK() {
        XCTAssertEqual(LegacyProtocol.negotiate("2025-03-26"), "2025-03-26")
        XCTAssertEqual(LegacyProtocol.negotiate("1999-01-01"), LegacyProtocol.latest)
        XCTAssertEqual(LegacyProtocol.negotiate(nil), LegacyProtocol.latest)
        XCTAssertEqual(LegacyProtocol.latest, "2025-11-25")
    }

    func testVersionGatesFollowRevisionDates() {
        XCTAssertFalse(LegacyProtocol.requiresHeaderAfterInitialize("2025-03-26"))
        XCTAssertTrue(LegacyProtocol.requiresHeaderAfterInitialize("2025-06-18"))
        XCTAssertTrue(LegacyProtocol.requiresHeaderAfterInitialize("2025-11-25"))
        XCTAssertTrue(LegacyProtocol.requiresHeaderAfterInitialize("2026-03-01"))

        XCTAssertFalse(LegacyProtocol.definesServerIcons("2025-06-18"))
        XCTAssertTrue(LegacyProtocol.definesServerIcons("2025-11-25"))
        XCTAssertTrue(LegacyProtocol.definesServerIcons("2026-03-01"))
    }

    func testMCPErrorEnvelopeMatchesTheSDKEncoding() throws {
        let data = JSONRPC.error(id: 1, MCPError.invalidParams("bad"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertEqual(error["message"] as? String, "Invalid params: bad")
        XCTAssertEqual((error["data"] as? [String: Any])?["detail"] as? String, "bad")
        XCTAssertEqual(json["id"] as? Int, 1)
    }

    private func captureLog(_ body: () -> Void) -> [String] {
        let capture = Log.Capture()
        Log.$capture.withValue(capture, operation: body)
        return capture.lines
    }
}
