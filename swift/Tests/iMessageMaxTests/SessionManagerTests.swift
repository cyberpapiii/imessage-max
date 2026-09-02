import XCTest
import MCP
import Synchronization
@testable import iMessageMax

final class SessionManagerTests: XCTestCase {

    func testConcurrentCreatesRespectTheCap() async throws {
        let manager = SessionManager(
            database: Database(),
            resolver: ContactResolver(seedCache: [:]),
            maxSessions: 2,
            cleanupInterval: .milliseconds(20)
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

        for session in created {
            await manager.terminateSession(sessionId: session.id)
        }

        XCTAssertEqual(
            created.count,
            2,
            "successes=\(created.count) atCapacity=\(atCapacity) startFailed=\(startFailed)"
        )
    }

    func testTerminateStopsServer() async {
        let manager = SessionManager(
            database: Database(),
            resolver: ContactResolver(seedCache: [:]),
            maxSessions: 2,
            cleanupInterval: .milliseconds(20)
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
            // Expected: swift-sdk Server.stop() nils `connection`, so send throws.
        }

        let count = await manager.sessionCount
        XCTAssertEqual(count, 0)
    }

    func testRouteMessageRefusesAfterTerminateReturns() async {
        let manager = SessionManager(
            database: Database(),
            resolver: ContactResolver(seedCache: [:]),
            maxSessions: 2,
            cleanupInterval: .milliseconds(20)
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
            database: Database(),
            resolver: ContactResolver(seedCache: [:]),
            maxSessions: 2,
            cleanupInterval: .milliseconds(20)
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
            database: Database(),
            resolver: ContactResolver(seedCache: [:]),
            maxSessions: 4,
            cleanupInterval: .milliseconds(20)
        )
        let collected = Mutex<[(String, Data)]>([])
        await manager.setResponseHandler { sessionId, data in
            collected.withLock { $0.append((sessionId, data)) }
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

        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline, collected.withLock({ $0.count }) < 2 {
            await AsyncTimeout.sleep(.milliseconds(20))
        }
        let payloads = collected.withLock { $0 }
        XCTAssertEqual(payloads.count, 2)
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

    func testTerminateUnknownIdIsANoOp() async {
        let manager = SessionManager(
            database: Database(),
            resolver: ContactResolver(seedCache: [:]),
            maxSessions: 2,
            cleanupInterval: .milliseconds(20)
        )

        await manager.terminateSession(sessionId: "missing")

        let count = await manager.sessionCount
        XCTAssertEqual(count, 0)
    }

    /// A detached `terminateSession` plus an immediate `activeSessionIds()`
    /// hop does not pin in-flight removal. The test task's actor hop wins
    /// the mailbox before terminate starts, so the id is still present even
    /// after `removeValue` moved above the first `await`. Yield-count races
    /// were already rejected as flaky. The three tests above pin the
    /// postcondition: after `terminateSession` returns, the id is gone and
    /// `routeMessage` refuses it.
}
