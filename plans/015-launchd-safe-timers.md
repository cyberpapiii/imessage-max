# Plan 015: Eliminate Task.sleep from the send path (launchd task-allocator crash)

> **Executor instructions**: BASE CHECK FIRST — run
> `ls plans/015-launchd-safe-timers.md`. If missing:
> `git checkout -b advisor/015-launchd-safe-timers <PLANS_COMMIT>` (SHA in
> dispatch message) and re-check; otherwise
> `git checkout -b advisor/015-launchd-safe-timers`. Follow exactly; verify
> every step; in-scope files only; do not edit `plans/README.md`. Report:
> STATUS / STEPS / STOPPED BECAUSE / FILES CHANGED / NOTES.

## Status

- **Priority**: P0 (live crash in production: service aborted with
  `freed pointer was not the last allocation` and was respawned by launchd)
- **Effort**: S
- **Risk**: LOW-MED (concurrency primitive replacement; behavior must be
  identical, only the timer mechanism changes)
- **Depends on**: none
- **Category**: bug / reliability
- **Planned at**: dispatch-message SHA, 2026-06-11

## Why this matters

The repo documents a runtime pathology at `HTTPTransport.swift:513-515`:

> Use a Dispatch timer instead of Task.sleep here. On this launchd-run
> service, sleeping unstructured Swift tasks have repeatedly aborted in
> swift_task_dealloc when they wake around the timeout boundary.

Plans 012/014 introduced two NEW `Task.sleep` call sites on the send path —
`AsyncTimeout.withTimeout` (races elicitation against `Task.sleep`) and
`SendVerifier.verify` (poll interval) — without honoring that note. The first
time the no-confirm send path ran inside the launchd service, the process
aborted with the same allocator-family crash (`freed pointer was not the last
allocation`, observed 2026-06-11 in `~/Library/Logs/imessage-max.stderr.log`),
killing an in-flight client request. The fix: rebuild both sites on the
repo's proven Dispatch-timer pattern and write the rule down so it cannot be
missed again.

## Current state

- `swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift` — `withTimeout`
  implemented as a `withTaskGroup` race where one child does
  `try? await Task.sleep(for: timeout)`. MUST lose the sleeping task.
- `swift/Sources/iMessageMax/Tools/SendVerifier.swift:67` —
  `try await Task.sleep(for: pollInterval)` between poll attempts.
- The proven pattern to mirror: `HTTPTransport.storePendingRequest`
  (`HTTPTransport.swift:503-534`) — `DispatchWorkItem` +
  `DispatchQueue.global(qos: .utility).asyncAfter`, and
  `HTTPTransport.dispatchInterval(for:)` (lines 544-554) converting `Duration`
  → `DispatchTimeInterval` (copy that conversion; do not import HTTPTransport
  into Utilities).
- Pre-existing `Task.sleep` sites in `SessionManager.swift:231`,
  `SSEConnection.swift:109`, `GetAttachment.swift:370` are OUT of scope —
  they predate today, have run on launchd for weeks, and touching them risks
  regressions this plan cannot validate.
- `swift/Sources/iMessageMax/Tools/Send.swift` — `confirmationTimeout`
  default `.seconds(60)`.
- Tests: `ElicitationTimeoutTests.swift` (4 tests) pin `withTimeout` behavior;
  `SendVerifierTests.swift` has one multi-attempt polling test.

## Commands

| Purpose | Command | Expected |
|---------|---------|----------|
| Build | `cd swift && swift build` | exit 0 |
| All tests | `cd swift && swift test` | exit 0 (baseline 146) |

## Scope

**In scope**:
- `swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift` (reimplement; add a
  Dispatch-based `sleep`)
- `swift/Sources/iMessageMax/Tools/SendVerifier.swift` (swap the poll sleep)
- `swift/Sources/iMessageMax/Tools/Send.swift` (ONLY the `confirmationTimeout`
  default: `.seconds(60)` → `.seconds(25)` — snappier degradation for
  swallowed prompts, still ample for a real human dialog, far under the 300s
  transport timeout)
- `swift/Tests/iMessageMaxTests/ElicitationTimeoutTests.swift` (extend)
- `AGENTS.md` (add the rule under "Critical Implementation Details")

**Out of scope**: `HTTPTransport.swift` (already correct), `SessionManager`,
`SSEConnection`, `GetAttachment` sleeps (pre-existing, stable), everything
else.

## Git workflow

Branch `advisor/015-launchd-safe-timers`; lowercase conventional commits; no
push, no PR.

## Steps

### Step 1: Rebuild AsyncTimeout on Dispatch timers

Reimplement `AsyncTimeout` with NO `Task.sleep` anywhere:

```swift
import Foundation

enum AsyncTimeout {
    /// Dispatch-backed sleep. NEVER use Task.sleep in code that runs inside
    /// the launchd service — sleeping Swift tasks abort in this runtime
    /// (see HTTPTransport.swift storePendingRequest note).
    static func sleep(_ duration: Duration) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + dispatchInterval(for: duration)
            ) { cont.resume() }
        }
    }

    /// Runs `operation` with a deadline enforced by a Dispatch timer.
    /// Returns its value, or nil on deadline/throw. The operation task is
    /// cancelled on timeout; operations that ignore cancellation may linger —
    /// callers must treat nil as "no answer", not "declined".
    static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async -> T? {
        // once-only resume guarded by a lock; timer and operation race.
        ...
    }
}
```

Implementation requirements for `withTimeout`:
- A `withCheckedContinuation` resumed exactly once, guarded by `NSLock` (or
  `OSAllocatedUnfairLock`) + a `resumed` flag captured in a small final class.
- Timeout side: `DispatchWorkItem` scheduled via `asyncAfter` that claims the
  guard and resumes with nil.
- Operation side: ONE unstructured `Task { }` that awaits `try? operation()`,
  claims the guard, cancels the work item, resumes with the value.
- On timeout claim: also `task.cancel()` the operation task (store it first).
- Copy `dispatchInterval(for:)` from `HTTPTransport.swift:544-554` as a
  private helper.
- NO `Task.sleep`, NO `withTaskGroup` (the group's implicit await machinery is
  what interacted badly with the runtime).

**Verify**: `cd swift && swift build` → exit 0;
`grep -c "Task.sleep" swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift` → 0.

### Step 2: Swap SendVerifier's poll sleep

`SendVerifier.swift:67`: replace `try await Task.sleep(for: pollInterval)`
with `await AsyncTimeout.sleep(pollInterval)` (the throws in the signature doc
comment should be updated — Database errors only now). Update the doc comment
at line 49.

**Verify**: `cd swift && swift build` → exit 0;
`grep -rn "Task.sleep" swift/Sources/iMessageMax/Tools/` → no matches.

### Step 3: Lower the confirmation default

`Send.swift`: `confirmationTimeout: Duration = .seconds(60)` → `.seconds(25)`.

**Verify**: `grep -n "seconds(25)" swift/Sources/iMessageMax/Tools/Send.swift` → 1 hit.

### Step 4: Tests

Extend `ElicitationTimeoutTests.swift`:
- The existing 4 tests must pass UNCHANGED against the new implementation
  (they pin behavior, not mechanism).
- Add `testDispatchSleepCompletes` — `AsyncTimeout.sleep(.milliseconds(50))`
  returns; elapsed ≥ 40ms and < 2s.
- Add `testTimeoutCancelsOperationTask` — operation that loops
  `while !Task.isCancelled { await AsyncTimeout.sleep(.milliseconds(10)) }`
  then sets an atomic flag/expectation on exit; call withTimeout(50ms);
  assert nil returned AND the flag flips within ~1s (proves cancellation
  propagates).

**Verify**: `cd swift && swift test --filter ElicitationTimeoutTests` → 6
pass; full suite → 148 pass.

### Step 5: Write the rule down

`AGENTS.md`, under "## Critical Implementation Details", add a short
subsection:

```markdown
### No Task.sleep in the service runtime

Sleeping Swift tasks abort intermittently inside the launchd-run service
(`swift_task_dealloc` / "freed pointer was not the last allocation").
Use Dispatch timers instead: `AsyncTimeout.sleep` / `AsyncTimeout.withTimeout`
for tool code, or the `DispatchWorkItem` pattern in
`HTTPTransport.storePendingRequest`. This crashed production on 2026-06-11
(send-confirmation timeout path); do not reintroduce.
```

**Verify**: `grep -n "No Task.sleep" AGENTS.md` → 1 hit.

## Done criteria

- [ ] `swift build` exit 0; `swift test` → 148 pass
- [ ] `grep -rn "Task.sleep" swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift swift/Sources/iMessageMax/Tools/` → zero matches
- [ ] Only in-scope files changed

(The decisive validation — no crash on a live no-confirm send through the
launchd service — is performed by the reviewer post-deploy; tests cannot
reproduce the launchd runtime.)

## STOP conditions

- The once-only lock pattern fights Swift 6 concurrency checking in a way
  that needs `@unchecked Sendable` on anything OTHER than the small private
  guard class — report rather than sprinkle unchecked conformances.
- Any existing test fails.

## Maintenance notes

- If the pre-existing sleeps (`SessionManager`, `SSEConnection`,
  `GetAttachment`) ever correlate with a crash, migrate them to
  `AsyncTimeout.sleep` — they were deliberately left alone here.
- Reviewer post-deploy gate: live no-confirm `send` via the launchd service
  must return `pending_confirmation` in ~25s with a STABLE service PID.
