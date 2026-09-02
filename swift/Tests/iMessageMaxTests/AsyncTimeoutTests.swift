import XCTest
@testable import iMessageMax

final class AsyncTimeoutTests: XCTestCase {

    /// A task that is already cancelled when it enters sleep must still return.
    /// At 61e75d9 this hangs: the cancellation handler runs before the
    /// continuation is armed and marks the gate resumed with nothing to resume.
    func testSleepReturnsWhenTaskIsCancelledBeforeEntry() {
        let finished = expectation(description: "sleep returns after pre-cancellation")
        let task = Task.detached {
            // Wait until cancellation has been requested before sleeping.
            while !Task.isCancelled { await Task.yield() }
            await AsyncTimeout.sleep(.seconds(30))
            finished.fulfill()
        }
        task.cancel()
        wait(for: [finished], timeout: 2)
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

    /// A task cancelled before entering sleep must not leave a timer on the
    /// global queue: at 639529e arm() resumes but sleep() still calls
    /// asyncAfter, and the item is retained until its deadline.
    func testPreCancelledSleepDoesNotEnqueueTimer() {
        AsyncTimeout.enqueuedTimersForTesting = 0
        let finished = expectation(description: "sleep returns")
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            await AsyncTimeout.sleep(.seconds(300))
            finished.fulfill()
        }
        task.cancel()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(AsyncTimeout.enqueuedTimersForTesting, 0)
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
