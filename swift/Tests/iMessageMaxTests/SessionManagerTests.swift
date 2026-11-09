import XCTest
import MCP
import Synchronization
@testable import iMessageMax

final class SessionManagerTests: XCTestCase {

    func testConcurrentCreatesNeverExceedTheCap() async throws {
        let manager = SessionManager(
            catalog: makeTestCatalog(),
            configuration: .init(
                maxSessions: 2,
                cleanupInterval: .milliseconds(20)
            )
        )

        let outcomes = try await withThrowingTaskGroup(of: SessionCreationResult.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await manager.createSession()
                }
            }
            var results: [SessionCreationResult] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }

        var created: [SessionManager.MCPSessionState] = []
        var atCapacity = 0
        var startFailed = 0
        for outcome in outcomes {
            switch outcome {
            case .created(let session):
                created.append(session)
            case .atCapacity:
                atCapacity += 1
            case .startFailed:
                startFailed += 1
            }
        }

        let live = await manager.sessionCount
        for session in created {
            await manager.terminateSession(sessionId: session.id)
        }

        // At the cap a new session closes the least recently active one, so
        // more than two can be created, but never more than two are live.
        XCTAssertLessThanOrEqual(live, 2)
        XCTAssertGreaterThanOrEqual(created.count, 2)
        XCTAssertEqual(startFailed, 0, "successes=\(created.count) atCapacity=\(atCapacity)")
    }

    /// 088 #30: idle time came from the wall clock, so a clock change or an
    /// hour's sleep expired live sessions. It now comes from the injected
    /// uptime clock, and the wall clock plays no part.
    func testIdleTimeIsMeasuredOnTheInjectedUptimeClock() async {
        let clock = Mutex<TimeInterval>(50)
        let manager = SessionManager(
            catalog: makeTestCatalog(),
            configuration: .init(cleanupInterval: .seconds(60), sessionTimeout: 3600),
            now: { clock.withLock { $0 } }
        )
        guard case .created(let session) = await manager.createSession() else { return XCTFail("session") }

        clock.withLock { $0 += 3599 }
        let stillValid = await manager.validate(sessionId: session.id)
        XCTAssertTrue(stillValid)

        clock.withLock { $0 += 3599 }
        await manager.cleanupExpiredSessions()
        let survived = await manager.routeMessage(sessionId: session.id, data: Data())
        XCTAssertTrue(survived, "validate counted as activity")

        clock.withLock { $0 += 3601 }
        await manager.cleanupExpiredSessions()
        let expired = await manager.routeMessage(sessionId: session.id, data: Data())
        XCTAssertFalse(expired)
    }

    func testUptimeClockIsMonotonic() {
        let first = SessionManager.uptime()
        let second = SessionManager.uptime()
        XCTAssertGreaterThan(first, 0)
        XCTAssertGreaterThanOrEqual(second, first)
    }

    func testTerminateStopsServer() async {
        let manager = SessionManager(
            catalog: makeTestCatalog(),
            configuration: .init(
                maxSessions: 2,
                cleanupInterval: .milliseconds(20)
            )
        )

        let result = await manager.createSession()
        guard case .created(let session) = result else {
            return XCTFail("Session should be created, got \(result)")
        }

        await manager.terminateSession(sessionId: session.id)

        do {
            try await session.server.notify(
                Message<InitializedNotification>(
                    method: InitializedNotification.name,
                    params: Empty()
                )
            )
            XCTFail("Server.stop() should drop the transport so notify fails")
        } catch {
            // Expected. swift-sdk Server.stop() sets `connection` to nil, so send throws.
        }

        let count = await manager.sessionCount
        XCTAssertEqual(count, 0)
    }

    func testRouteMessageRefusesAfterTerminateReturns() async {
        let manager = SessionManager(
            catalog: makeTestCatalog(),
            configuration: .init(
                maxSessions: 2,
                cleanupInterval: .milliseconds(20)
            )
        )
        guard case .created(let session) = await manager.createSession() else {
            return XCTFail("session should be created")
        }

        await manager.terminateSession(sessionId: session.id)

        let routed = await manager.routeMessage(sessionId: session.id, data: Data("{}".utf8))
        XCTAssertFalse(routed)
        let ids = await manager.activeSessionIds()
        XCTAssertFalse(ids.contains(session.id))
    }

    func testTerminateSessionTwiceIsIdempotent() async {
        let manager = SessionManager(
            catalog: makeTestCatalog(),
            configuration: .init(
                maxSessions: 2,
                cleanupInterval: .milliseconds(20)
            )
        )
        guard case .created(let session) = await manager.createSession() else {
            return XCTFail("session should be created")
        }

        await manager.terminateSession(sessionId: session.id)
        await manager.terminateSession(sessionId: session.id)

        let count = await manager.sessionCount
        XCTAssertEqual(count, 0)
    }

    func testNotifyAllSessionsReachesEverySessionResponseHandler() async throws {
        let manager = SessionManager(
            catalog: makeTestCatalog(),
            configuration: .init(
                maxSessions: 4,
                cleanupInterval: .milliseconds(20)
            )
        )
        let (deliveries, delivery) = AsyncStream.makeStream(of: (String, Data).self)
        await manager.setResponseHandler { sessionId, data in
            delivery.yield((sessionId, data))
        }

        guard case .created(let first) = await manager.createSession() else {
            return XCTFail("first session")
        }
        guard case .created(let second) = await manager.createSession() else {
            return XCTFail("second session")
        }

        let delivered = await manager.notifyAllSessions(
            Message<NewMessagesNotification>(
                method: NewMessagesNotification.name,
                params: .init(max_rowid: 42)
            )
        )
        XCTAssertEqual(delivered, 2)

        var payloads: [(String, Data)] = []
        for await payload in deliveries {
            payloads.append(payload)
            if payloads.count == 2 { break }
        }
        XCTAssertEqual(Set(payloads.map(\.0)), Set([first.id, second.id]))
        for (_, data) in payloads {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["method"] as? String, "notifications/imessage/new_messages")
            XCTAssertNil(json["id"])
            let params = try XCTUnwrap(json["params"] as? [String: Any])
            XCTAssertEqual(params["max_rowid"] as? Int, 42)
        }

        await manager.terminateSession(sessionId: first.id)
        await manager.terminateSession(sessionId: second.id)
    }
}
