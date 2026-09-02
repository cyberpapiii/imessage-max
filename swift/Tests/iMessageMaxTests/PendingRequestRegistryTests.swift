import XCTest
import MCP
@testable import iMessageMax

final class PendingRequestRegistryTests: XCTestCase {

    func testStoreThenRemoveReturnsContinuationAndCancelsTimer() async throws {
        let registry = PendingRequestRegistry(timeout: .seconds(30))
        let expected = Data("ok".utf8)

        let waiter = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                Task {
                    let stored = await registry.store(
                        sessionId: "s1",
                        id: "1",
                        continuation: continuation
                    )
                    XCTAssertTrue(stored)
                }
            }
        }

        await AsyncTimeout.sleep(.milliseconds(20))
        let pending = await registry.remove(sessionId: "s1", id: "1")
        XCTAssertNotNil(pending)
        pending?.resume(returning: expected)

        let value = try await waiter.value
        XCTAssertEqual(value, expected)
        let count = await registry.count
        XCTAssertEqual(count, 0)
    }

    func testDuplicateIdIsRejected() async throws {
        let registry = PendingRequestRegistry(timeout: .seconds(30))

        let first = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                Task {
                    let stored = await registry.store(
                        sessionId: "s1",
                        id: "1",
                        continuation: continuation
                    )
                    XCTAssertTrue(stored)
                }
            }
        }

        await AsyncTimeout.sleep(.milliseconds(20))

        let second = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                Task {
                    let stored = await registry.store(
                        sessionId: "s1",
                        id: "1",
                        continuation: continuation
                    )
                    XCTAssertFalse(stored)
                    if !stored {
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }
        }

        do {
            _ = try await second.value
            XCTFail("duplicate store must not resume a second waiter")
        } catch is CancellationError {
            // First continuation still owns the slot; we discarded the second.
        }

        let pending = await registry.remove(sessionId: "s1", id: "1")
        XCTAssertNotNil(pending)
        pending?.resume(returning: Data())
        _ = try await first.value
    }

    func testTimeoutResumesWithRequestTimeoutError() async throws {
        let registry = PendingRequestRegistry(timeout: .milliseconds(50))

        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                Task {
                    let stored = await registry.store(
                        sessionId: "s1",
                        id: "1",
                        continuation: continuation
                    )
                    XCTAssertTrue(stored)
                }
            }
            XCTFail("expected timeout")
        } catch let error as MCPError {
            guard case .serverError(let code, let message) = error else {
                return XCTFail("expected serverError, got \(error)")
            }
            XCTAssertEqual(code, -32000)
            XCTAssertEqual(message, "Request timeout")
        }

        let count = await registry.count
        XCTAssertEqual(count, 0)
    }

    func testCleanupForSessionOnlyTouchesThatSession() async throws {
        let registry = PendingRequestRegistry(timeout: .seconds(30))

        let s1 = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                Task {
                    _ = await registry.store(sessionId: "s1", id: "1", continuation: continuation)
                }
            }
        }
        let s2 = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                Task {
                    _ = await registry.store(sessionId: "s2", id: "1", continuation: continuation)
                }
            }
        }

        await AsyncTimeout.sleep(.milliseconds(20))
        await registry.cleanup(for: "s1")

        do {
            _ = try await s1.value
            XCTFail("s1 should be terminated")
        } catch let error as MCPError {
            guard case .serverError(let code, let message) = error else {
                return XCTFail("expected serverError, got \(error)")
            }
            XCTAssertEqual(code, -32000)
            XCTAssertEqual(message, "Session terminated")
        }

        let pending = await registry.remove(sessionId: "s2", id: "1")
        XCTAssertNotNil(pending)
        pending?.resume(returning: Data("s2".utf8))
        let value = try await s2.value
        XCTAssertEqual(value, Data("s2".utf8))
    }

    func testRemoveAllResumesEverythingWithConnectionClosed() async throws {
        let registry = PendingRequestRegistry(timeout: .seconds(30))

        let a = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                Task {
                    _ = await registry.store(sessionId: "s1", id: "1", continuation: continuation)
                }
            }
        }
        let b = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                Task {
                    _ = await registry.store(sessionId: "s2", id: "2", continuation: continuation)
                }
            }
        }

        await AsyncTimeout.sleep(.milliseconds(20))
        await registry.removeAll()

        for task in [a, b] {
            do {
                _ = try await task.value
                XCTFail("expected connectionClosed")
            } catch let error as MCPError {
                guard case .connectionClosed = error else {
                    return XCTFail("expected connectionClosed, got \(error)")
                }
            }
        }

        let count = await registry.count
        XCTAssertEqual(count, 0)
    }
}
