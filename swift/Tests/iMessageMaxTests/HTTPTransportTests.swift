import Synchronization
import XCTest
@testable import iMessageMax

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

final class SSEConnectionManagerTests: XCTestCase {

    func testRegisterThenUnregister() async {
        let manager = SSEConnectionManager(keepAliveInterval: HTTPTransport.Configuration().sseKeepAliveInterval)
        let info = SSEConnectionInfo(sessionId: "test-session")

        _ = await manager.register(info: info)
        var count = await manager.connectionCount
        XCTAssertEqual(count, 1)
        let ids = await manager.connectionIds(forSession: "test-session")
        XCTAssertEqual(ids, [info.id])

        await manager.unregister(connectionId: info.id)
        count = await manager.connectionCount
        XCTAssertEqual(count, 0)
    }

    func testCloseAllEndsOpenStreamsAndLaterOnes() async {
        let manager = SSEConnectionManager(keepAliveInterval: .seconds(60))
        let open = await manager.register(info: SSEConnectionInfo(sessionId: "a"))
        await manager.closeAll()
        let late = await manager.register(info: SSEConnectionInfo(sessionId: "b"))

        for channel in [open, late] {
            var received = 0
            for await _ in channel.stream { received += 1 }
            XCTAssertEqual(received, 0)
        }
        let count = await manager.connectionCount
        XCTAssertEqual(count, 0)
    }
}

final class SSEChannelTests: XCTestCase {

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

        XCTAssertEqual(received, ["event-one", "event-two"])
    }

    func testKeepAlivesInterleave() async {
        let channel = SSEChannel(keepAliveInterval: .milliseconds(20))

        var iterator = channel.stream.makeAsyncIterator()
        let first = await iterator.next()

        XCTAssertEqual(first, SSEEvent.keepAlive())
    }

    func testStreamIsStoredAndNotRespawnedPerAccess() async {
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

final class SessionManagerLifecycleTests: XCTestCase {

    /// 088 #33: a full table refused every new client until a session had
    /// been idle 300 s, and said nothing. The least recently active session
    /// now makes room, with one log line.
    func testAtTheCapTheLeastRecentlyActiveSessionMakesRoom() async throws {
        let clock = Mutex<TimeInterval>(1_000)
        let manager = SessionManager(
            catalog: makeTestCatalog(),
            configuration: .init(maxSessions: 2, cleanupInterval: .seconds(60)),
            now: { clock.withLock { $0 } }
        )

        guard case .created(let older) = await manager.createSession() else { return XCTFail("first session") }
        clock.withLock { $0 += 10 }
        guard case .created(let idle) = await manager.createSession() else { return XCTFail("second session") }
        clock.withLock { $0 += 10 }
        await manager.touch(sessionId: older.id)
        clock.withLock { $0 += 5 }

        let capture = Log.Capture()
        let third = await Log.$capture.withValue(capture) { await manager.createSession() }
        guard case .created(let admitted) = third else {
            return XCTFail("A new client should get a session at the cap, got \(third)")
        }

        let live = Set(await manager.activeSessionIds())
        XCTAssertEqual(live, [older.id, admitted.id], "the session idle longest makes room")
        let evictedRouted = await manager.routeMessage(sessionId: idle.id, data: Data())
        XCTAssertFalse(evictedRouted, "its client gets 404 and starts a new session")
        XCTAssertEqual(capture.lines.count, 1, "\(capture.lines)")
        XCTAssertTrue(capture.lines.first?.contains("Session cap of 2 reached") == true, "\(capture.lines)")
        XCTAssertTrue(capture.lines.first?.contains(String(idle.id.prefix(8))) == true, "\(capture.lines)")
        XCTAssertTrue(capture.lines.first?.contains("idle 15 s") == true, "\(capture.lines)")

        for id in live { await manager.terminateSession(sessionId: id) }
    }

    /// Only slots held by sessions still being created cannot be freed.
    func testCreateSessionWhileEverySlotIsStillStartingReturnsAtCapacity() async {
        let started = DispatchSemaphore(value: 0)
        var configuration = HTTPTransport.Configuration(maxSessions: 1, cleanupInterval: .seconds(60))
        configuration.makeServer = { catalog in
            started.signal()
            await AsyncTimeout.sleep(.milliseconds(500))
            return await Version.makeServer(catalog: catalog)
        }
        let manager = SessionManager(catalog: makeTestCatalog(), configuration: configuration)

        let slow = Task { await manager.createSession() }
        await MessagesAccess.offPool { _ = started.wait(timeout: .now() + 5) }
        let second = await manager.createSession()
        guard case .atCapacity = second else {
            return XCTFail("A slot still starting cannot be reclaimed, got \(second)")
        }
        if case .created(let session) = await slow.value {
            await manager.terminateSession(sessionId: session.id)
        }
    }

    func testAbandonedSessionIsReclaimedToAdmitANewClient() async {
        let manager = SessionManager(
            catalog: makeTestCatalog(),
            configuration: .init(
                maxSessions: 1,
                reclaimableIdle: 0.05,
                cleanupInterval: .milliseconds(20)
            )
        )

        let first = await manager.createSession()
        guard case .created(let abandoned) = first else {
            return XCTFail("First session should be created, got \(first)")
        }

        await AsyncTimeout.sleep(.milliseconds(100))

        let second = await manager.createSession()
        guard case .created(let admitted) = second else {
            return XCTFail("An idle session should be reclaimed to admit a client, got \(second)")
        }
        XCTAssertNotEqual(admitted.id, abandoned.id)

        let count = await manager.sessionCount
        XCTAssertEqual(count, 1, "Reclaiming must not push the table over its cap")

        let routedToAbandoned = await manager.routeMessage(sessionId: abandoned.id, data: Data())
        XCTAssertFalse(
            routedToAbandoned,
            "The reclaimed session should be gone, so its client re-initialises"
        )
    }

    func testExpiredSessionIsCleanedUp() async {
        let manager = SessionManager(
            catalog: makeTestCatalog(),
            configuration: .init(
                cleanupInterval: .milliseconds(20),
                sessionTimeout: 0.01
            )
        )

        let result = await manager.createSession()
        guard case .created(let session) = result else {
            return XCTFail("Session should be created, got \(result)")
        }

        let routedWhileLive = await manager.routeMessage(sessionId: session.id, data: Data())
        XCTAssertTrue(routedWhileLive, "A fresh session should accept messages")

        await AsyncTimeout.sleep(.milliseconds(100))
        await manager.cleanupExpiredSessions()

        let routedAfterExpiry = await manager.routeMessage(sessionId: session.id, data: Data())
        XCTAssertFalse(routedAfterExpiry, "An expired session should be gone after cleanup")

        let count = await manager.sessionCount
        XCTAssertEqual(count, 0)
    }
}

final class JsonRpcIdCanonicalizationTests: XCTestCase {

    func testIntAndStringIdsDoNotCollide() {
        XCTAssertNotEqual(
            requestKey(["id": 1]),
            requestKey(["id": "1"])
        )
    }

    func testHugeDoubleIdDoesNotTrap() {
        let key = requestKey(["id": 1e300])
        XCTAssertNotNil(key)
        XCTAssertNotEqual(key, requestKey(["id": "1e300"]))
    }

    func testFractionalDoubleIdIsItsOwnKey() {
        let key = requestKey(["id": 1.5])
        XCTAssertNotNil(key)
        XCTAssertEqual(key, requestKey(["id": 1.5]))
        XCTAssertNotEqual(key, requestKey(["id": 1]))
        XCTAssertNotEqual(key, requestKey(["id": 2]))
        XCTAssertNotEqual(key, requestKey(["id": "1.5"]))
    }

    func testIntegralDoubleMatchesIntId() {
        // JSON does not distinguish 2 from 2.0, so a client sending one and
        // receiving the other back must still correlate.
        XCTAssertEqual(
            requestKey(["id": 2.0]),
            requestKey(["id": 2])
        )
    }

    func testNullIdIsStable() {
        XCTAssertNotNil(requestKey(["id": NSNull()]))
        XCTAssertEqual(requestKey(["id": NSNull()]), requestKey(["id": NSNull()]))
        XCTAssertNotEqual(requestKey(["id": NSNull()]), requestKey(["id": "null"]))
    }

    func testMissingOrNonScalarIdHasNoKey() {
        XCTAssertNil(requestKey([:]))
        XCTAssertNil(requestKey(["id": ["a": 1]]))
        XCTAssertNil(requestKey(["id": [1]]))
    }

    private func requestKey(_ object: [String: Any]) -> String? {
        JSONRPCMessage(object).requestKey
    }
}
