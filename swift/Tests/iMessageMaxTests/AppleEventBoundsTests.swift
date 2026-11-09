import Foundation
import Synchronization
import XCTest
@testable import iMessageMax

/// A hung Messages and a burst of sends must cost bounded time and threads.
/// No test here sends anything or talks to Messages: the probes are fakes,
/// and the real osascript runs only `delay`.
final class AppleEventBoundsTests: XCTestCase {
    // MARK: Bounded probe

    func testNeverReturningProbeTimesOutAndHoldsOneThread() {
        let release = DispatchSemaphore(value: 0)
        let started = Mutex(0)
        let probe = BoundedProbe(timeout: .milliseconds(200)) {
            started.withLock { $0 += 1 }
            release.wait()
            return noErr
        }
        defer { release.signal() }

        let clock = ContinuousClock()
        let first = clock.measure { XCTAssertNil(probe.run()) }
        XCTAssertLessThan(first, .seconds(1))

        // Callers while the probe is stuck give up on time and start nothing.
        let results = Mutex<[OSStatus?]>([])
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let answer = probe.run()
            results.withLock { $0.append(answer) }
        }
        XCTAssertEqual(results.withLock { $0.count }, 8)
        XCTAssertTrue(results.withLock { $0.allSatisfy { $0 == nil } })
        XCTAssertEqual(started.withLock { $0 }, 1, "a hung probe must hold the only probe thread")
    }

    func testProbeAnswersAgainOnceTheStuckProbeReturns() throws {
        let release = DispatchSemaphore(value: 0)
        let calls = Mutex(0)
        let probe = BoundedProbe(timeout: .milliseconds(200)) {
            let call = calls.withLock { count in
                count += 1
                return count
            }
            if call == 1 { release.wait() }
            return OSStatus(call)
        }
        XCTAssertNil(probe.run())
        release.signal()

        let deadline = ContinuousClock.now + .seconds(5)
        var answer: OSStatus?
        while answer == nil, ContinuousClock.now < deadline {
            answer = probe.run()
        }
        XCTAssertEqual(answer, 2)
    }

    func testConcurrentQuickProbesAllAnswer() {
        let probe = BoundedProbe(timeout: .seconds(2)) { noErr }
        let answers = Mutex<[OSStatus?]>([])
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            let answer = probe.run()
            answers.withLock { $0.append(answer) }
        }
        XCTAssertEqual(answers.withLock { $0 }, Array(repeating: noErr, count: 32))
    }

    /// Only runs while Messages is already running, so the test can never
    /// start it: a probe that times out means it is hung, and the launcher
    /// gives up at once instead of waiting out its 10 s deadline.
    func testLauncherGivesUpAtOnceOnAHungRunningMessages() throws {
        try XCTSkipUnless(MessagesLauncher.isRunning, "needs Messages already running")
        let clock = ContinuousClock()
        var ready = true
        let elapsed = clock.measure {
            ready = MessagesLauncher.ensureRunningHidden(reason: "a test", timeout: 10, probe: { nil })
        }
        XCTAssertFalse(ready)
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    // MARK: Script gate

    func testGateBoundsConcurrentScriptsWithoutFalseTimeouts() async {
        let running = Mutex((now: 0, peak: 0))
        let gate = ScriptGate(slots: 4, waitLimit: .seconds(30)) { _, _ in
            running.withLock { state in
                state.now += 1
                state.peak = max(state.peak, state.now)
            }
            Thread.sleep(forTimeInterval: 0.05)
            running.withLock { $0.now -= 1 }
            return .success(Osascript.Output(stdout: "ok", stderr: "", terminationStatus: 0))
        }
        let outcomes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    await MessagesAccess.offPool {
                        if case .success = gate.run("", arguments: []) { return true }
                        return false
                    }
                }
            }
            return await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        XCTAssertEqual(outcomes.count, 64)
        XCTAssertTrue(outcomes.allSatisfy { $0 })
        XCTAssertLessThanOrEqual(running.withLock { $0.peak }, 4)
    }

    func testGateWaitLimitFailsWithoutRunning() {
        let release = DispatchSemaphore(value: 0)
        let runs = Mutex(0)
        let gate = ScriptGate(slots: 1, waitLimit: .milliseconds(100)) { _, _ in
            runs.withLock { $0 += 1 }
            release.wait()
            return .success(Osascript.Output(stdout: "", stderr: "", terminationStatus: 0))
        }
        let holder = Thread { _ = gate.run("", arguments: []) }
        holder.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while runs.withLock({ $0 }) == 0, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }

        let result = gate.run("", arguments: [])
        release.signal()
        guard case .failure(.messagesAppUnavailable) = result else {
            return XCTFail("expected a not-run failure, got \(result)")
        }
        XCTAssertEqual(runs.withLock { $0 }, 1)
    }

    /// The auditor's harness, scaled down: many real osascript runs at once,
    /// each a short `delay`. Unbounded, a burst like this exhausted GCD's
    /// threads and reported finished scripts as timeouts.
    func testRealOsascriptBurstHasNoFalseTimeouts() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/osascript"))
        let gate = ScriptGate(slots: 4, waitLimit: .seconds(120))
        let script = """
            on run argv
                delay 0.2
                return item 1 of argv
            end run
            """
        let outputs = await withTaskGroup(of: String.self) { group in
            for index in 0..<40 {
                group.addTask {
                    await MessagesAccess.offPool {
                        switch gate.run(script, arguments: ["\(index)"]) {
                        case .success(let output): return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                        case .failure(let error): return "failure: \(error)"
                        }
                    }
                }
            }
            return await group.reduce(into: [String]()) { $0.append($1) }
        }
        XCTAssertEqual(Set(outputs), Set((0..<40).map(String.init)), "every run must finish with its own output")
    }
}
