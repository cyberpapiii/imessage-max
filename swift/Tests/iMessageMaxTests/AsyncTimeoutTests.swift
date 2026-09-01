import XCTest
@testable import iMessageMax

final class AsyncTimeoutTests: XCTestCase {

    /// A task that is already cancelled when it enters sleep must still return.
    /// At 61e75d9 this hangs: the cancellation handler runs before the
    /// continuation is armed and marks the gate resumed with nothing to resume.
    func testSleepReturnsWhenTaskIsCancelledBeforeEntry() async throws {
        let task = Task {
            // Wait until cancellation has been requested before sleeping.
            while !Task.isCancelled { await Task.yield() }
            await AsyncTimeout.sleep(.seconds(30))
            return true
        }
        task.cancel()

        let finished = await withTaskGroup(of: Bool?.self) { group -> Bool? in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        XCTAssertEqual(finished, true, "sleep did not return within 2 s after pre-cancellation")
    }

    /// Cancellation after arming returns promptly (well before the 30 s timer).
    func testSleepReturnsPromptlyWhenCancelledAfterEntry() async {
        let start = ContinuousClock.now
        let task = Task { await AsyncTimeout.sleep(.seconds(30)) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await task.value
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    /// The normal path: an uncancelled sleep returns after its duration.
    func testSleepReturnsAfterDuration() async {
        let start = ContinuousClock.now
        await AsyncTimeout.sleep(.milliseconds(100))
        let elapsed = ContinuousClock.now - start
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(90))
        XCTAssertLessThan(elapsed, .seconds(2))
    }
}
