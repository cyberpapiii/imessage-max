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

// MARK: - SSE Channel Tests

final class SSEChannelTests: XCTestCase {

    /// Keep-alive spacing long enough that no heartbeat can race the
    /// assertions in tests that only care about data events.
    private let quietKeepAlive: Duration = .seconds(600)

    func testEventsFlowAndCloseFinishes() async {
        let channel = SSEChannel(keepAliveInterval: quietKeepAlive)

        channel.send("event-one")
        channel.send("event-two")
        channel.close()

        var received: [String] = []
        for await event in channel.stream {
            received.append(event)
        }

        // Both events arrive in order, then close() ends the stream so the
        // for-await terminates rather than hanging.
        XCTAssertEqual(received, ["event-one", "event-two"])
    }

    func testKeepAlivesInterleave() async {
        let channel = SSEChannel(keepAliveInterval: .milliseconds(20))

        // Nothing is sent, so the first item to arrive must be a heartbeat.
        // Bounded: take exactly one item instead of looping.
        var iterator = channel.stream.makeAsyncIterator()
        let first = await iterator.next()

        XCTAssertEqual(first, SSEEvent.keepAlive())
    }

    func testStreamIsStoredAndNotRespawnedPerAccess() async {
        // Contract documentation, not a discriminating regression test: the
        // old computed property would also report nothing on a second pass
        // here, because it rebuilt its merger over an already-finished base
        // stream. What this pins is the consume-exactly-once semantics that
        // callers may now rely on — once exhausted, `stream` stays exhausted
        // and never replays or restarts a keep-alive loop.
        let channel = SSEChannel(keepAliveInterval: .milliseconds(50))

        channel.send("only-event")
        channel.close()

        var firstPass: [String] = []
        for await event in channel.stream {
            firstPass.append(event)
        }
        XCTAssertEqual(
            firstPass.filter { $0 != SSEEvent.keepAlive() },
            ["only-event"]
        )

        var secondIterator = channel.stream.makeAsyncIterator()
        let afterExhaustion = await secondIterator.next()
        XCTAssertNil(
            afterExhaustion,
            "A second access to `stream` must not respawn a merger or keep-alive loop"
        )
    }
}

// MARK: - Session Manager Lifecycle Tests

final class SessionManagerLifecycleTests: XCTestCase {

    func testCreateSessionAtCapacityReturnsAtCapacity() async {
        let manager = SessionManager(
            database: Database(),
            resolver: ContactResolver(seedCache: [:]),
            maxSessions: 1
        )

        let first = await manager.createSession()
        guard case .created = first else {
            return XCTFail("First session should be created, got \(first)")
        }

        // The cap is now full: the refusal must be distinguishable from a
        // startup failure so the caller can answer 503 rather than 500.
        let second = await manager.createSession()
        guard case .atCapacity = second else {
            return XCTFail("Second session should be refused as .atCapacity, got \(second)")
        }

        let count = await manager.sessionCount
        XCTAssertEqual(count, 1)
    }

    func testExpiredSessionIsCleanedUp() async {
        let manager = SessionManager(
            database: Database(),
            resolver: ContactResolver(seedCache: [:]),
            sessionTimeout: 0.01
        )

        let result = await manager.createSession()
        guard case .created(let session) = result else {
            return XCTFail("Session should be created, got \(result)")
        }

        let routedWhileLive = await manager.routeMessage(sessionId: session.id, data: Data())
        XCTAssertTrue(routedWhileLive, "A fresh session should accept messages")

        // Idle past the injected 10ms TTL, then run the reaper the 5-minute
        // timer loop would otherwise drive.
        await AsyncTimeout.sleep(.milliseconds(100))
        await manager.cleanupExpiredSessions()

        let routedAfterExpiry = await manager.routeMessage(sessionId: session.id, data: Data())
        XCTAssertFalse(routedAfterExpiry, "An expired session should be gone after cleanup")

        let count = await manager.sessionCount
        XCTAssertEqual(count, 0)
    }
}

// MARK: - JSON-RPC Id Canonicalization Tests

final class JsonRpcIdCanonicalizationTests: XCTestCase {

    func testIntAndStringIdsDoNotCollide() {
        // `1` and `"1"` are distinct legal JSON-RPC ids. Collapsing both to
        // "1" made the second concurrent request look like a duplicate.
        XCTAssertNotEqual(
            HTTPTransport.parseJsonRpcId(from: ["id": 1]),
            HTTPTransport.parseJsonRpcId(from: ["id": "1"])
        )
    }

    func testHugeDoubleIdDoesNotTrap() {
        // Reaching this assertion at all is the regression test: the old
        // implementation trapped and aborted the process on this input.
        let key = HTTPTransport.parseJsonRpcId(from: ["id": 1e300])
        XCTAssertTrue(key.hasPrefix("d:"), "Expected d: namespace, got \(key)")
    }

    func testFractionalDoubleIdDoesNotTrap() {
        let key = HTTPTransport.parseJsonRpcId(from: ["id": 1.5])
        XCTAssertEqual(key, "d:1.5")
    }

    func testIntegralDoubleMatchesIntId() {
        // JSON does not distinguish 2 from 2.0, so a client sending one and
        // receiving the other back must still correlate.
        XCTAssertEqual(
            HTTPTransport.parseJsonRpcId(from: ["id": 2.0]),
            HTTPTransport.parseJsonRpcId(from: ["id": 2])
        )
    }

    func testNullIdIsStable() {
        XCTAssertEqual(HTTPTransport.parseJsonRpcId(from: ["id": NSNull()]), "n:null")
    }

    func testMissingIdGeneratesUniqueKeys() {
        XCTAssertNotEqual(
            HTTPTransport.parseJsonRpcId(from: [:]),
            HTTPTransport.parseJsonRpcId(from: [:])
        )
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
