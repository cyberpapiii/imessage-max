import XCTest
@testable import iMessageMax

final class SessionManagerTests: XCTestCase {

    func testConcurrentCreatesRespectTheCap() async throws {
        let manager = SessionManager(
            database: Database(),
            resolver: ContactResolver(seedCache: [:]),
            maxSessions: 2
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
}
