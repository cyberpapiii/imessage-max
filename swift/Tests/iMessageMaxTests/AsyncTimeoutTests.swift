import XCTest
@testable import iMessageMax

final class AsyncTimeoutTests: XCTestCase {

    func testSleepReturnsWhenTaskIsCancelledBeforeEntry() {
        let finished = expectation(description: "sleep returns after pre-cancellation")
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            await AsyncTimeout.sleep(.seconds(30))
            finished.fulfill()
        }
        task.cancel()
        wait(for: [finished], timeout: 2)
    }

    func testSleepReturnsPromptlyWhenCancelledAfterEntry() async {
        let start = ContinuousClock.now
        let gate = AsyncTimeout.ResumeGate()
        let task = Task { await AsyncTimeout.sleep(.seconds(30), gate: gate) }
        await waitForTimer(gate)
        task.cancel()
        await task.value
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testPreCancelledSleepDoesNotEnqueueTimer() {
        let gate = AsyncTimeout.ResumeGate()
        let finished = expectation(description: "sleep returns")
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            await AsyncTimeout.sleep(.seconds(300), gate: gate)
            finished.fulfill()
        }
        task.cancel()
        wait(for: [finished], timeout: 2)
        XCTAssertFalse(gate.startedTimer)
    }

    func testSleepReturnsAfterDuration() async {
        let start = ContinuousClock.now
        await AsyncTimeout.sleep(.milliseconds(100))
        let elapsed = ContinuousClock.now - start
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(90))
        XCTAssertLessThan(elapsed, .seconds(2))
    }

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

    func testGateIsReleasedPromptlyWhenCancelled() async {
        let box = WeakBox()
        let task: Task<Void, Never>
        do {
            let gate = AsyncTimeout.ResumeGate()
            box.value = gate
            task = Task { await AsyncTimeout.sleep(.seconds(300), gate: gate) }
            await waitForTimer(gate)
        }
        task.cancel()
        await task.value
        await waitForRelease(box)
        XCTAssertNil(box.value, "cancelled sleep kept its ResumeGate until the deadline")
    }

    private func waitForTimer(_ gate: AsyncTimeout.ResumeGate) async {
        while !gate.startedTimer {
            await Task.yield()
        }
    }

    private final class WeakBox: @unchecked Sendable {
        weak var value: AnyObject?
    }

    private func waitForRelease(_ box: WeakBox) async {
        for _ in 0..<100 where box.value != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
