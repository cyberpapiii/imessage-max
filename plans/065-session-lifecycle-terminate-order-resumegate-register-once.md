# Plan 065: Session lifecycle — remove before stop, do not enqueue a dead sleep timer, and confirm register-once

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 639529e..HEAD -- swift/Sources/iMessageMax/Server/SessionManager.swift swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift swift/Sources/iMessageMax/Server/ToolRegistry.swift swift/Sources/iMessageMax/Server/HTTPTransport.swift swift/Tests/iMessageMaxTests/SessionManagerTests.swift swift/Tests/iMessageMaxTests/AsyncTimeoutTests.swift swift/Tests/iMessageMaxTests/ToolRegistryBindingTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MEDIUM (touches the HTTP session actor and the only sleep primitive the service is allowed to use)
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `639529e`, 2026-09-01

## Why this matters

Three items were raised together. One of them has already landed; the plan
says so rather than re-doing it.

1. **`terminateSession` removes the session last.** It cancels the server
   task, finishes the message continuation, races `server.stop()` against a
   2-second `AsyncTimeout.sleep`, and only then removes the entry from
   `sessions`. For up to 2 seconds a session that is already dead is still
   routable: `routeMessage` finds it, yields the client's bytes into a
   finished continuation (a no-op), and returns `true`. The HTTP layer
   treats `true` as "delivered" and waits for a response that will never
   come, so the client sees the full request timeout instead of the
   immediate `connectionClosed` it gets when `routeMessage` returns
   `false`. `validate` has the same window: it can hand a terminating
   session to a caller.
2. **`AsyncTimeout.sleep` enqueues its timer even when the task was already
   cancelled.** `ResumeGate.arm` resumes the continuation immediately in
   that case and returns without storing the work item, so nobody ever
   cancels it. The `DispatchWorkItem` sits on the global queue until its
   deadline, retaining the closure. For the session cleanup loop the
   deadline is 300 seconds. `AGENTS.md` ("No Task.sleep in the service
   runtime") already documents that leftover `asyncAfter` items are the
   thing to avoid; this is the one place the primitive itself leaves one.
3. **Register tools once per process, not per session.** This was the
   original third item. It landed at commit `d5968cf` ("perf: bind the tool
   catalog once instead of per session"), is guarded by
   `ToolRegistryBindingTests`, and is in `main` at `639529e`. This plan
   verifies it and adds nothing.

## Current state

### (a) terminateSession ordering

`swift/Sources/iMessageMax/Server/SessionManager.swift:241-268`:

```swift
func terminateSession(sessionId: String) async {
    guard let session = sessions[sessionId] else { return }

    // Cancel server task
    session.serverTask?.cancel()

    // Complete the message stream
    session.messageContinuation.finish()

    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            await session.server.stop()
        }
        group.addTask {
            await AsyncTimeout.sleep(.seconds(2))
        }
        await group.next()
        group.cancelAll()
    }

    // Remove from active sessions
    sessions.removeValue(forKey: sessionId)

    // Notify HTTPTransport to clean up SSE connections
    Task {
        await sessionTerminationHandler?(sessionId)
    }
}
```

`SessionManager` is an actor, and the `await` inside the task group is a
suspension point, so other actor methods run during the race.

`SessionManager.swift:196-204`:

```swift
func routeMessage(sessionId: String, data: Data) async -> Bool {
    guard let session = sessions[sessionId] else {
        return false
    }

    session.lastActivity = Date()
    session.messageContinuation.yield(data)
    return true
}
```

`SessionManager.swift:211-221` (`validate`) has the same
`guard let session = sessions[sessionId]` and returns the session.

`swift/Sources/iMessageMax/Server/HTTPTransport.swift:351-364` is the
consumer: when `routeMessage` returns `false` it resumes the pending request
with `MCPError.connectionClosed`; when `true` it waits for the response.

Existing tests: `SessionManagerTests.testTerminateStopsServer`
(`SessionManagerTests.swift:53-82`) creates a session, terminates it, then
asserts `session.server.notify` throws and `sessionCount == 0`. It does not
call `routeMessage` during termination.

### (b) ResumeGate leaves the work item enqueued

`swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift:11-27`:

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

`AsyncTimeout.swift:66-78`:

```swift
func arm(work: DispatchWorkItem, continuation: CheckedContinuation<Void, Never>) {
    state.withLock { _ in
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
}
```

When `cancelled` is already true on entry (the case
`testSleepReturnsWhenTaskIsCancelledBeforeEntry` exercises), `arm` resumes
and returns without storing `work`; `sleep` then unconditionally calls
`asyncAfter` with it. `cancelAndResume` (`:89-107`) cancels `self.work`,
which is nil here. The item fires at the deadline, calls `gate.resume`,
which hits `guard !resumed else { return }`. Harmless to correctness,
but the closure (and the gate) live until the deadline.

`AsyncTimeoutTests.swift` has three tests: pre-entry cancellation returns,
post-entry cancellation returns promptly, and the uncancelled path returns
after its duration. None observes whether a timer was enqueued.

Callers of `AsyncTimeout.sleep` in `swift/Sources`:
`SessionManager.terminateSession` (2 s) and `SessionManager.startCleanupTask`
(`cleanupInterval`, default 300 s), plus any tool code.

### (c) Register-once is already done

`swift/Sources/iMessageMax/Server/ToolRegistry.swift:29-43` at `639529e`:

```swift
private static func claimCatalogBinding(db: Database, resolver: ContactResolver) -> Bool {
    bound.withLock { state in
        if state.database === db && state.resolver === resolver {
            return true
        }
        state.database = db
        state.resolver = resolver
        return false
    }
}

static func registerAll(on server: Server, db: Database, resolver: ContactResolver) async {
    await server.registerToolHandlers()

    guard !claimCatalogBinding(db: db, resolver: resolver) else { return }
```

`git log --oneline -3 -- swift/Sources/iMessageMax/Server/ToolRegistry.swift`
shows `d5968cf perf: bind the tool catalog once instead of per session`.
`swift/Tests/iMessageMaxTests/ToolRegistryBindingTests.swift:29-44`
(`testSecondRegistrationWithTheSameDependenciesChangesNothing`) asserts the
catalog version does not move on a second `registerAll` with the same
`Database` and `ContactResolver` instances. `SessionManager.createSession`
(`:157`) calls `registerAll` with the manager's own `database` and
`resolver`, which are the same instances for every session, so the
per-session path is the no-op path.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `cd swift && swift build` | `Build complete!` |
| Focused (a) | `cd swift && swift test --filter SessionManagerTests` | 0 failures |
| Focused (b) | `cd swift && swift test --filter AsyncTimeoutTests` | 0 failures |
| Focused (c) | `cd swift && swift test --filter "ToolRegistryBindingTests\|ModernDispatcherTests"` | 0 failures |
| Launchd rule | `cd swift && swift test --filter LaunchdSafetyTests` | 0 failures |
| Whole suite | `cd swift && swift test` | 0 failures (baseline 370 at `639529e`) |
| HTTP smoke | `cd swift && swift test --filter HTTPTransportTests` | 0 failures |

## Scope

### In scope

- `swift/Sources/iMessageMax/Server/SessionManager.swift` (`terminateSession` only)
- `swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift` (`sleep` and `ResumeGate.arm`)
- `swift/Tests/iMessageMaxTests/SessionManagerTests.swift`
- `swift/Tests/iMessageMaxTests/AsyncTimeoutTests.swift`

### Out of scope

- `ToolRegistry.swift`, `ToolRegistryBindingTests.swift`: item (c) is
  verified, not changed. If the verification in Step 0 fails, that is a
  STOP, not a scope expansion.
- `HTTPTransport.swift`: the `routeMessage` consumer at `:351-364` is
  already correct once `routeMessage` returns `false` promptly.
- Replacing `asyncAfter` with `DispatchSourceTimer` in `AsyncTimeout.sleep`.
  `HTTPTransport.swift:799-807` explains the trade-off for request
  timeouts; the fix here is narrower (do not enqueue when already
  cancelled) and does not change the timer primitive.
- The 2-second stop bound, the cleanup interval, and `reclaimIdleSessions`.

## Git workflow

- Branch: `advisor/065-session-lifecycle` from current `main`.
- Test-first for (a) and (b): failing-test commit, then fix commit.
- Commit messages:
  - `test: routeMessage must refuse a session that is terminating`
  - `fix: remove the session from the table before stopping its server`
  - `test: AsyncTimeout.sleep must not enqueue a timer for a pre-cancelled task`
  - `fix: skip asyncAfter when ResumeGate.arm already resumed`
- The executor does not merge or push. Report the branch name.

Standing rules:

- Never `Task.sleep` in `swift/Sources`; `LaunchdSafetyTests` enforces it.
  Tests may use `Task.sleep` (`AsyncTimeoutTests.swift:26` already does).
- Never touch `.mcp.json`.
- Never commit secrets.

## Steps

### Step 0: Verify (c) is present

Run:

```
git log --oneline -1 -- swift/Sources/iMessageMax/Server/ToolRegistry.swift
grep -c "claimCatalogBinding" swift/Sources/iMessageMax/Server/ToolRegistry.swift
cd swift && swift test --filter ToolRegistryBindingTests
```

**Verify**: first line names `d5968cf` or a later commit; grep prints `2`;
tests report 2 executed, 0 failures. Record the three outputs in the
report under "(c) verified". Do not change any file for this step.

### Step 1: Failing test for terminate ordering (a)

The window is observable without a wedged transport: make `server.stop()`
slow is hard, but the ordering itself is testable by racing. Add to
`SessionManagerTests.swift`:

```swift
/// While terminateSession is awaiting server.stop(), the session must
/// already be gone from the table so routeMessage/validate refuse it.
/// At 639529e the entry is removed only after the stop race.
func testRouteMessageRefusesTerminatingSession() async throws {
    let manager = SessionManager(
        database: Database(),
        resolver: ContactResolver(seedCache: [:]),
        maxSessions: 2,
        cleanupInterval: .milliseconds(20)
    )
    guard case .created(let session) = await manager.createSession() else {
        return XCTFail("session should be created")
    }

    // Start termination, then immediately try to route on the same actor.
    // The actor processes terminateSession up to its first suspension
    // (the stop race) before routeMessage runs.
    let terminate = Task { await manager.terminateSession(sessionId: session.id) }
    await Task.yield()
    let routed = await manager.routeMessage(sessionId: session.id, data: Data("{}".utf8))
    await terminate.value

    XCTAssertFalse(routed, "a terminating session must not accept messages")
    let count = await manager.sessionCount
    XCTAssertEqual(count, 0)
}
```

If a single `Task.yield()` does not reliably let `terminateSession` reach
its suspension point before `routeMessage` is enqueued on the actor,
replace it with a short bounded spin: `for _ in 0..<10 { await Task.yield() }`.
Do not use `Task.sleep` in this test either; a yield loop is enough because
`routeMessage` cannot run until the actor suspends inside `terminateSession`.

**Verify**: `swift test --filter SessionManagerTests/testRouteMessageRefusesTerminatingSession`
fails with `routed == true` at least 3 runs out of 3 (`for i in 1 2 3; do swift test --filter SessionManagerTests/testRouteMessageRefusesTerminatingSession || true; done`).
If it passes at `639529e` even once, the yield is not landing inside the
window; adjust per the note above until it fails deterministically. Commit.

### Step 2: Fix terminate ordering (a)

Reorder `terminateSession` so the table entry is removed before any
suspension:

```swift
func terminateSession(sessionId: String) async {
    // Remove first: once termination starts, routeMessage and validate
    // must refuse this id even while server.stop() is still running.
    guard let session = sessions.removeValue(forKey: sessionId) else { return }

    session.serverTask?.cancel()
    session.messageContinuation.finish()

    await withTaskGroup(of: Void.self) { group in
        group.addTask { await session.server.stop() }
        group.addTask { await AsyncTimeout.sleep(.seconds(2)) }
        await group.next()
        group.cancelAll()
    }

    Task { await sessionTerminationHandler?(sessionId) }
}
```

Keep the existing doc comment above the function about the 2-second bound.
`sessionCount` now drops before `stop()` completes; check
`cleanupExpiredSessions` and `reclaimIdleSessions` (`:311-336`) still
iterate over a snapshot (`sessions.filter {...}.map(\.key)`) so removal
during iteration is safe. They do at `639529e`.

**Verify**: `swift test --filter SessionManagerTests` → 0 failures, 3 tests.
`swift test --filter HTTPTransportTests` → 0 failures. Commit.

### Step 3: Failing test for the enqueued timer (b)

`ResumeGate` is private, and Dispatch does not expose queue contents, so
observe the leak through the work item itself. Make the test measure that
a pre-cancelled sleep's work item runs (or is cancelled) promptly rather
than at the deadline. The cleanest observable is a hook: add an internal
test seam to `AsyncTimeout`:

```swift
/// Test seam: number of Dispatch timers enqueued by `sleep`. Only
/// incremented on the path that actually calls `asyncAfter`.
nonisolated(unsafe) static var enqueuedTimersForTesting = 0
```

(`Database.queryCountForTesting` is the precedent for this pattern.)
Increment it immediately before the `asyncAfter` call. Then add to
`AsyncTimeoutTests.swift`:

```swift
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
```

Because the counter is process-global and other tests call `sleep`, run
this test's filter alone when confirming the failure, and keep the
assertion on a value captured before/after within the test rather than an
absolute count if the suite is ever parallelized (it is serial in CI per
`build.yml`).

**Verify**: `swift test --filter AsyncTimeoutTests/testPreCancelledSleepDoesNotEnqueueTimer`
fails with `1 != 0`. Commit.

### Step 4: Fix (b)

Make `arm` report whether it stored the work item, and only enqueue when it
did:

```swift
/// Returns true when the gate now holds `work` and `continuation`, i.e. the
/// caller must schedule `work`. Returns false when cancellation already
/// resumed the continuation; the caller must not enqueue anything.
func arm(work: DispatchWorkItem, continuation: CheckedContinuation<Void, Never>) -> Bool {
    state.withLock { _ in
        if cancelled || resumed {
            if !resumed {
                resumed = true
                continuation.resume()
            }
            return false
        }
        self.work = work
        self.continuation = continuation
        return true
    }
}
```

and in `sleep`:

```swift
let work = DispatchWorkItem { gate.resume(continuation) }
guard gate.arm(work: work, continuation: continuation) else { return }
enqueuedTimersForTesting += 1
DispatchQueue.global(qos: .utility).asyncAfter(
    deadline: .now() + dispatchInterval(for: duration),
    execute: work
)
```

The `guard ... else { return }` returns from the `withCheckedContinuation`
body closure; the continuation was already resumed inside `arm`, which is
the invariant the type's doc comment states. Update that comment to
mention the return value.

**Verify**: `swift test --filter AsyncTimeoutTests` → 0 failures, 4 tests.
`swift test --filter LaunchdSafetyTests` → 0 failures. Commit.

### Step 5: Full suite

**Verify**: `cd swift && swift test` → 0 failures, ≥ 372 tests. Run it
twice; the session tests are timing-adjacent and must pass both times.

## Test plan

- `SessionManagerTests` +1 (`testRouteMessageRefusesTerminatingSession`).
- `AsyncTimeoutTests` +1 (`testPreCancelledSleepDoesNotEnqueueTimer`).
- `ToolRegistryBindingTests` unchanged, executed in Step 0 as verification.
- Whole suite green twice in a row.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` → 0 failures (two consecutive runs)
- [ ] `grep -n "sessions.removeValue(forKey: sessionId)" swift/Sources/iMessageMax/Server/SessionManager.swift` → one match, and it is on the `guard let session =` line of `terminateSession`
- [ ] `grep -n "guard gate.arm" swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift` → one match
- [ ] `grep -n "func arm(.*) -> Bool" swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift` → one match
- [ ] `grep -rn "Task.sleep(" swift/Sources/iMessageMax` → no matches
- [ ] `git diff --stat main..HEAD -- swift/Sources/iMessageMax/Server/ToolRegistry.swift` → empty
- [ ] Report contains the three Step 0 outputs
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Step 0 shows `claimCatalogBinding` absent or `ToolRegistryBindingTests`
  failing. Item (c) is then not landed and this plan's premise is wrong.
- Step 1's test cannot be made to fail deterministically at `639529e` after
  the yield-loop adjustment. Report what you tried; do not ship a flaky
  test.
- After Step 2, `HTTPTransportTests` or any SSE test fails, or
  `testTerminateStopsServer` fails. Reordering changed something the
  transport relied on; report the failing assertion.
- Step 3's counter seam requires touching more than the two lines described
  (declaration and increment). If `AsyncTimeout` cannot hold a
  `nonisolated(unsafe) static var` under the project's strict-concurrency
  settings, report the compiler error rather than weakening concurrency
  checking.

## Maintenance notes

- `terminateSession` must remove the entry before its first `await`. Any
  future step added above the `guard let session = sessions.removeValue`
  line must be synchronous.
- `ResumeGate.arm` returning `false` means "already resumed, do not
  schedule." Any new sleep primitive built on the gate must honor that.
- `enqueuedTimersForTesting` is a test seam, not telemetry. Do not read it
  from production code.
- Item (c): `SessionManager.createSession` may keep calling
  `ToolRegistry.registerAll`; it is a no-op for the manager's own
  dependencies. Do not "optimize" the call away, because the per-server
  `registerToolHandlers()` inside it is required for every `Server`.
