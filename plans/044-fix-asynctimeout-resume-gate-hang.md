# Plan 044: Fix the AsyncTimeout gate that never resumes when cancellation lands before arming

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 61e75d9..HEAD -- swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift swift/Tests/iMessageMaxTests/LaunchdSafetyTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (040 for CI)
- **Category**: bug
- **Planned at**: commit `61e75d9`, 2026-09-01

## Why this matters

`AsyncTimeout.sleep` is the only sanctioned sleep in the service (the launchd rule forbids `Task.sleep`). It is used by the SSE keep-alive loop, the session cleanup loop, and the send verifier's poll loop. Its cancellation gate has a state bug: if the awaiting task is already cancelled when `sleep` is entered, the cancellation handler runs before the continuation is stored, marks the gate "resumed" while holding no continuation, and the continuation that arrives a moment later is never resumed. The task hangs forever with a leaked checked continuation. In the SSE and session loops that means a cancelled task never finishes and its task group never completes; in the verifier it means a send that was cancelled mid-poll never returns.

## Current state

`swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift:10-26` (the public entry point):

```swift
static func sleep(_ duration: Duration) async {
    let gate = ResumeGate()
    await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let work = DispatchWorkItem {
                gate.resume(continuation)
            }
            gate.arm(work: work, continuation: continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + dispatchInterval(for: duration),
                execute: work
            )
        }
    } onCancel: {
        gate.cancelAndResume()
    }
}
```

`AsyncTimeout.swift:51-98` (the gate):

```swift
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var work: DispatchWorkItem?
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false
    private var cancelled = false

    func arm(work: DispatchWorkItem, continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        if cancelled || resumed {
            if !resumed {
                resumed = true
                continuation.resume()
            }
            return
        }
        self.work = work
        self.continuation = continuation
    }

    func resume(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        self.continuation = nil
        continuation.resume()
    }

    func cancelAndResume() {
        lock.lock()
        cancelled = true
        let item = work
        let cont = continuation
        let already = resumed
        if !already {
            resumed = true
            continuation = nil
        }
        lock.unlock()
        item?.cancel()
        if !already, let cont {
            cont.resume()
        }
    }
}
```

The bug, traced: `withTaskCancellationHandler` invokes `onCancel` **immediately** if the task is already cancelled on entry, before the operation body runs. So `cancelAndResume()` runs with `continuation == nil` and `resumed == false`. It sets `resumed = true` (line 89) and resumes nothing (`cont` is nil). Then the body runs, `arm` is called, sees `resumed == true`, skips the `if !resumed` resume at lines 63-66, and returns. The continuation is never resumed. The task is stuck at `await withCheckedContinuation` forever, and XCTest/Swift runtime reports `SWIFT TASK CONTINUATION MISUSE: leaked its continuation` only when the gate is deallocated, which it never is.

There is also a secondary path: `arm` runs, then the Dispatch timer fires `resume` at the same moment `cancelAndResume` runs. That one is handled correctly by `resumed` under the lock.

Callers (do not change): `Server/SSEConnection.swift:99`, `Server/SessionManager.swift:265`, `Tools/SendVerifier.swift:75`.

Repo rule: `swift/Tests/iMessageMaxTests/LaunchdSafetyTests.swift` greps `swift/Sources` for `Task.sleep` and fails if any appears. Do not introduce one, including in tests that run against source (tests may use `Task.sleep` themselves, the rule is about `Sources/`).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | `Build complete!` |
| Focused | `cd swift && swift test --filter "AsyncTimeoutTests|LaunchdSafetyTests|SendVerifierTests"` | 0 failures |
| Whole suite | `cd swift && swift test` | 0 failures |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift`
- `swift/Tests/iMessageMaxTests/AsyncTimeoutTests.swift` (create)

**Out of scope** (do NOT touch, even though they look related):
- The three callers. Their loops check `Task.isCancelled` after the sleep and are correct once the sleep returns.
- Replacing `NSLock` with `Synchronization.Mutex` — plan 048 does that across the codebase after the macOS floor moves to 15. Keep `NSLock` here.
- `dispatchInterval(for:)` — the saturation logic is correct and tested elsewhere.

## Git workflow

- Branch: `advisor/044-asynctimeout-gate`
- One commit, type `fix:`. Example: `fix: resume AsyncTimeout.sleep when cancellation precedes arming`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Write the failing test first

Create `swift/Tests/iMessageMaxTests/AsyncTimeoutTests.swift`:

```swift
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
```

**Verify**: `cd swift && swift test --filter AsyncTimeoutTests` → the first test **fails** (`sleep did not return within 2 s after pre-cancellation`); the other two pass. If the first test passes at `61e75d9`, STOP: the bug is not reproducing as planned.

### Step 2: Fix the gate

In `ResumeGate.cancelAndResume`, only mark the gate resumed when there is a continuation to resume. When there is none, leave `resumed == false` so that `arm` takes its "cancelled, resume immediately" path:

```swift
func cancelAndResume() {
    lock.lock()
    cancelled = true
    let item = work
    let cont = continuation
    let already = resumed
    // Only claim the resume if we actually hold the continuation. If arm()
    // has not run yet, leave `resumed` false so arm() resumes on arrival.
    if !already, cont != nil {
        resumed = true
        continuation = nil
    }
    lock.unlock()
    item?.cancel()
    if !already, let cont {
        cont.resume()
    }
}
```

`arm` is already correct for that case: with `cancelled == true` and `resumed == false` it resumes the incoming continuation immediately and returns.

Add a doc comment on the class stating the invariant in one sentence: "`resumed` is true only after a continuation has actually been resumed."

**Verify**: `cd swift && swift test --filter AsyncTimeoutTests` → `Executed 3 tests, with 0 failures`. Run it three more times to check for flakiness: `for i in 1 2 3; do swift test --filter AsyncTimeoutTests 2>&1 | grep "Executed"; done` → three lines each with `0 failures`.

### Step 3: Full suite and launchd rule

**Verify**: `cd swift && swift test` → 0 failures; `swift test --filter LaunchdSafetyTests` → 0 failures (the test file uses `Task.sleep` for its own timing, which is allowed under `Tests/`; confirm the rule only scans `Sources/` by reading `LaunchdSafetyTests.swift` before relying on this).

## Test plan

- `AsyncTimeoutTests` (3 methods): pre-cancelled entry (the bug), post-arm cancellation, and normal duration.
- Test-before-fix ordering is required: Step 1 must show the first test failing before Step 2.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test --filter AsyncTimeoutTests` → 3 tests, 0 failures, three consecutive runs
- [ ] `cd swift && swift test` → 0 failures
- [ ] `grep -n "if !already, cont != nil" swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift` → one match
- [ ] `grep -rn "Task.sleep" swift/Sources` → no matches
- [ ] `git status` shows only the two in-scope files modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Step 1's first test does not fail at `61e75d9` (bug not reproducing; the fix may still be right but the plan's evidence is wrong).
- After the fix, any run of `AsyncTimeoutTests` reports `SWIFT TASK CONTINUATION MISUSE` in the output.
- `SendVerifierTests` or `HTTPTransportIntegrationTests` change behaviour (they exercise the callers).
- You feel the need to restructure `sleep` around a different primitive. The gate fix is one condition; a rewrite is out of scope.

## Maintenance notes

- Invariant to preserve in review: exactly one of `arm`, `resume`, `cancelAndResume` resumes the continuation, and `resumed` flips to true only in the same critical section as the resume. Any future edit that sets `resumed = true` without resuming reintroduces this hang.
- Plan 048 replaces `NSLock` with `Synchronization.Mutex` here; the logic must be carried over unchanged.
- The SSE keep-alive comment at `SSEConnection.swift:94-96` says the sleep is "non-cancellable"; after this plan it is cancellable at any point. Plan 053 (docs/logging sweep) may reword that comment; do not do it here.
