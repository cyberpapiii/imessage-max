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

    /// Every sleep must free its gate once it returns. At 33e20cb the gate
    /// held the work item and the work item captured the gate, so each
    /// sleep leaked a gate, a work item and a continuation canary.
    func testGateIsReleasedAfterSleepCompletes() async {
        let box = WeakBox()
        do {
            let gate = AsyncTimeout.ResumeGate()
            box.value = gate
            await AsyncTimeout.sleep(.milliseconds(10), gate: gate)
        }
        await waitForRelease(box)
        XCTAssertNil(box.value, "sleep leaked its ResumeGate")
    }

    /// A cancelled sleep must free its gate at cancellation, not at the
    /// original deadline: a cancelled asyncAfter item stays enqueued until
    /// then and keeps everything it captured alive.
    func testGateIsReleasedPromptlyWhenCancelled() async {
        let box = WeakBox()
        let task: Task<Void, Never>
        do {
            let gate = AsyncTimeout.ResumeGate()
            box.value = gate
            task = Task { await AsyncTimeout.sleep(.seconds(300), gate: gate) }
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await task.value
        await waitForRelease(box)
        XCTAssertNil(box.value, "cancelled sleep kept its ResumeGate until the deadline")
    }

    private final class WeakBox: @unchecked Sendable {
        weak var value: AnyObject?
    }

    /// Dispatch drops its reference to a timer handler just after it runs,
    /// so give it a moment before judging.
    private func waitForRelease(_ box: WeakBox) async {
        for _ in 0..<100 where box.value != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
