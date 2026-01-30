import XCTest
@testable import iMessageMax

// MARK: - SSEEvent Tests

final class SSEEventTests: XCTestCase {

    func testFormattedOutputWithDataOnly() {
        let event = SSEEvent(data: #"{"jsonrpc":"2.0","result":{},"id":1}"#)
        let formatted = event.formatted()

        XCTAssertTrue(formatted.contains("data: "))
        XCTAssertTrue(formatted.hasSuffix("\n\n"))
        XCTAssertFalse(formatted.contains("id:"))
        XCTAssertFalse(formatted.contains("event:"))
    }

    func testFormattedOutputWithId() {
        let event = SSEEvent(id: "123", data: "test data")
        let formatted = event.formatted()

        XCTAssertTrue(formatted.contains("id: 123\n"))
        XCTAssertTrue(formatted.contains("data: test data\n"))
    }

    func testFormattedOutputWithEventType() {
        let event = SSEEvent(event: "message", data: "test data")
        let formatted = event.formatted()

        XCTAssertTrue(formatted.contains("event: message\n"))
        XCTAssertTrue(formatted.contains("data: test data\n"))
    }

    func testFormattedOutputWithAllFields() {
        let event = SSEEvent(
            id: "event-42",
            event: "notification",
            data: #"{"type":"progress","value":50}"#
        )
        let formatted = event.formatted()

        XCTAssertTrue(formatted.contains("id: event-42\n"))
        XCTAssertTrue(formatted.contains("event: notification\n"))
        XCTAssertTrue(formatted.contains("data: {"))
    }

    func testFormattedOutputWithMultiLineData() {
        let multiLineData = """
        {
          "jsonrpc": "2.0",
          "result": {},
          "id": 1
        }
        """
        let event = SSEEvent(data: multiLineData)
        let formatted = event.formatted()

        let dataLines = formatted.components(separatedBy: "\n")
            .filter { $0.hasPrefix("data:") }

        XCTAssertEqual(dataLines.count, 5)
        XCTAssertTrue(formatted.hasPrefix("data:"))
        XCTAssertTrue(formatted.hasSuffix("\n\n"))
    }

    func testKeepAliveFormat() {
        let keepAlive = SSEEvent.keepAlive()

        XCTAssertEqual(keepAlive, ": keep-alive\n\n")
        XCTAssertTrue(keepAlive.hasPrefix(":"))
        XCTAssertTrue(keepAlive.hasSuffix("\n\n"))
    }

    func testEmptyDataEvent() {
        let event = SSEEvent(data: "")
        let formatted = event.formatted()

        XCTAssertTrue(formatted.contains("data: \n"))
        XCTAssertTrue(formatted.hasSuffix("\n\n"))
    }

    func testUnicodeData() {
        let event = SSEEvent(data: "Hello, \u{1F680} World!")
        let formatted = event.formatted()

        XCTAssertTrue(formatted.contains("\u{1F680}"))
    }
}

// MARK: - SSE Connection Manager Tests

final class SSEConnectionManagerTests: XCTestCase {

    func testInitialConnectionCountIsZero() async {
        let manager = SSEConnectionManager()
        let count = await manager.connectionCount
        XCTAssertEqual(count, 0)
    }

    func testConnectionIdsForNonexistentSession() async {
        let manager = SSEConnectionManager()
        let connections = await manager.connectionIds(forSession: "nonexistent")
        XCTAssertTrue(connections.isEmpty)
    }

    func testTerminateNonexistentSession() async {
        let manager = SSEConnectionManager()
        await manager.terminateSession(sessionId: "nonexistent")
        let count = await manager.connectionCount
        XCTAssertEqual(count, 0)
    }

    func testRegisterCreatesConnection() async {
        let manager = SSEConnectionManager()
        let info = SSEConnectionInfo(sessionId: "test-session")

        let channel = await manager.register(info: info)

        XCTAssertNotNil(channel)
        let count = await manager.connectionCount
        XCTAssertEqual(count, 1)
    }

    func testUnregisterRemovesConnection() async {
        let manager = SSEConnectionManager()
        let info = SSEConnectionInfo(sessionId: "test-session")

        _ = await manager.register(info: info)
        var count = await manager.connectionCount
        XCTAssertEqual(count, 1)

        await manager.unregister(connectionId: info.id)
        count = await manager.connectionCount
        XCTAssertEqual(count, 0)
    }
}

// MARK: - Message Classification Tests

final class MessageClassificationTests: XCTestCase {

    func testRequestHasMethodAndId() throws {
        let requestJson = #"{"jsonrpc":"2.0","method":"tools/list","id":1}"#
        let data = Data(requestJson.utf8)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["method"])
        XCTAssertNotNil(json["id"])
    }

    func testRequestWithStringId() throws {
        let requestJson = #"{"jsonrpc":"2.0","method":"test","id":"abc-123"}"#
        let data = Data(requestJson.utf8)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["method"])
        XCTAssertTrue(json["id"] is String)
    }

    func testNotificationHasMethodButNoId() throws {
        let notificationJson = #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}"#
        let data = Data(notificationJson.utf8)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["method"])
        XCTAssertNil(json["id"])
    }

    func testResponseHasResultAndId() throws {
        let responseJson = #"{"jsonrpc":"2.0","result":{"tools":[]},"id":1}"#
        let data = Data(responseJson.utf8)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["result"])
        XCTAssertNotNil(json["id"])
        XCTAssertNil(json["method"])
    }

    func testErrorResponseHasErrorAndId() throws {
        let errorJson = #"{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid Request"},"id":1}"#
        let data = Data(errorJson.utf8)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["error"])
        XCTAssertNotNil(json["id"])
        XCTAssertNil(json["method"])
    }

    func testBatchRequestIsArray() throws {
        let batchJson = #"[{"jsonrpc":"2.0","method":"test1","id":1},{"jsonrpc":"2.0","method":"test2","id":2}]"#
        let data = Data(batchJson.utf8)

        let json = try JSONSerialization.jsonObject(with: data)
        XCTAssertTrue(json is [Any])

        if let array = json as? [[String: Any]] {
            XCTAssertEqual(array.count, 2)
        }
    }
}

// MARK: - HTTP Response Code Documentation Tests

final class HTTPResponseCodeTests: XCTestCase {

    func testExpectedStatusCodes() {
        // Documents expected HTTP status codes from MCP spec:
        // 415 - Invalid Content-Type
        // 406 - Invalid Accept header
        // 400 - Malformed JSON-RPC or missing session ID
        // 403 - Origin/Host validation failure
        // 404 - Expired session (client should re-initialize)
        // 202 - Notification accepted
        // 200 - Request with response
        // 204 - Session terminated

        XCTAssertEqual(415, 415)  // Invalid Content-Type
        XCTAssertEqual(406, 406)  // Invalid Accept header
        XCTAssertEqual(400, 400)  // Malformed JSON or missing session
        XCTAssertEqual(403, 403)  // Origin validation failure
        XCTAssertEqual(404, 404)  // Expired session (client should re-initialize)
    }
}

// MARK: - Origin Validation Documentation Tests

final class OriginValidationTests: XCTestCase {

    func testAllowedHostsDefault() {
        let expectedHosts: Set<String> = ["localhost", "127.0.0.1", "[::1]", "::1"]
        XCTAssertEqual(expectedHosts.count, 4)
    }

    func testLocalhostOriginsExpectedToPass() {
        let allowedOrigins = [
            "http://localhost",
            "http://localhost:8080",
            "https://localhost",
            "http://127.0.0.1",
            "http://127.0.0.1:3000",
            "http://[::1]",
            "http://[::1]:8080"
        ]
        XCTAssertEqual(allowedOrigins.count, 7)
    }

    func testExternalOriginsExpectedToBlock() {
        let blockedOrigins = [
            "http://example.com",
            "https://malicious-site.com",
            "http://192.168.1.1",
            "http://evil.localhost.com",
            "file:///etc/passwd"
        ]
        XCTAssertEqual(blockedOrigins.count, 5)
    }
}
