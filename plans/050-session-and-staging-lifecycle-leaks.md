# Plan 050: Close the session-cap race, stop the SDK Server on terminate, and clean staged attachments on every exit

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 61e75d9..HEAD -- swift/Sources/iMessageMax/Server/SessionManager.swift swift/Sources/iMessageMax/Server/HTTPTransport.swift swift/Sources/iMessageMax/Utilities/AppleScript.swift swift/Tests/iMessageMaxTests/SessionManagerTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MEDIUM
- **Depends on**: 044 (AsyncTimeout gate; the cleanup loop sleeps through it)
- **Category**: reliability / resource leaks
- **Planned at**: commit `61e75d9`, 2026-09-01

## Why this matters

Three leaks in long-running service paths:

1. **Session cap is checked, then awaited past.** `createSession` counts sessions, then awaits tool registration and `server.start()`, then inserts. Two concurrent `initialize` requests both pass the count check and both insert, so the cap the last perf PR raised is advisory under load. The perf PR's commit message ("a fleet of agents hit in seconds") describes exactly the workload where this matters.
2. **`terminateSession` never calls `server.stop()`.** The comment in `HTTPTransport.swift:647` says it does. The swift-sdk `Server` holds its transport's task and response continuations; without `stop()` those outlive the session until the process exits. Under the idle-cleanup loop this is a slow leak proportional to sessions created.
3. **Staged attachments leak on `.pending`/`.unknown`.** The attachment send copies files into `~/Pictures/imessage-max-staging/<uuid>/`, polls Messages for the transfer, and removes the directory only when the poll ends `.finished` or `.failed`. On `.pending` (timeout) or `.unknown` it returns a failure and leaves the directory. The 48-hour sweep catches it eventually, but a burst of timeouts fills Pictures with copies of the user's files in the meantime, which is both a disk and a privacy issue.

## Current state

### Session cap race

`swift/Sources/iMessageMax/Server/SessionManager.swift:112-178` (`createSession`), abridged to the load-bearing lines:

```swift
func createSession(...) async throws -> Session {
    // :115-121
    if sessions.count >= maxSessions {
        throw SessionError.capacityExceeded
    }
    let sessionId = UUID().uuidString
    let server = Server(name: ..., version: ..., capabilities: ...)
    await registry.registerAll(on: server)          // suspension point
    try await server.start(transport: transport)    // suspension point
    ...
    sessions[sessionId] = session                    // :176
    return session
}
```

`SessionManager` is an actor, so `sessions` is isolated, but the two `await`s between the check and the insert let another `createSession` interleave. The fix is to reserve the slot before the first `await` and release it on any failure path.

### Missing `server.stop()`

`SessionManager.swift:223-239` (`terminateSession`):

```swift
func terminateSession(_ sessionId: String) {
    guard let session = sessions[sessionId] else { return }
    session.task?.cancel()
    session.continuation?.finish()
    sessions.removeValue(forKey: sessionId)
}
```

`HTTPTransport.swift:647` (comment on the DELETE handler): "Terminate the session (this also stops its Server instance)". It does not. The `Session` type (read its declaration near the top of `SessionManager.swift`) holds the `server` reference; `Server.stop()` in swift-sdk 0.12.1 is `public func stop() async`.

`startCleanupTask` at `:262-268` loops `while !Task.isCancelled { await AsyncTimeout.sleep(...); await cleanupIdleSessions() }` and `cleanupIdleSessions` calls `terminateSession` per idle session, so fixing `terminateSession` fixes both the DELETE path and idle expiry.

### Staged attachment leak

`swift/Sources/iMessageMax/Utilities/AppleScript.swift:376-405` (transfer poll result handling), abridged:

```swift
switch transferState {
case .finished:
    removeStagedDirectory(stagingDirectory)
    return .success(...)
case .failed:
    removeStagedDirectory(stagingDirectory)
    return .failure(.transferFailed)
case .pending, .unknown:
    return .failure(.transferUnconfirmed)     // directory left behind
}
```

`removeStagedDirectory` (`:411-419`) refuses to delete anything outside `stagingRootDirectory()` (`:421-425`, `~/Pictures/imessage-max-staging`). `cleanupOldStagedFilesIfPossible` (`:427-446`) deletes subdirectories older than 48 hours and is called at the start of each attachment send.

Why the directory was kept on `.pending`: Messages may still be reading the file when the poll gives up, and deleting under it fails the transfer. That concern is real for a few seconds, not 48 hours.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | `Build complete!` |
| Focused | `cd swift && swift test --filter "SessionManagerTests|HTTPTransportIntegrationTests|AppleScriptRunnerValidationTests|LaunchdSafetyTests"` | 0 failures |
| Whole suite | `cd swift && swift test` | 0 failures |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Server/SessionManager.swift`
- `swift/Sources/iMessageMax/Server/HTTPTransport.swift` (comment at `:647` only)
- `swift/Sources/iMessageMax/Utilities/AppleScript.swift` (`:376-405` and `:427-446`)
- `swift/Tests/iMessageMaxTests/SessionManagerTests.swift` (create if absent)
- `swift/Tests/iMessageMaxTests/AppleScriptStagingTests.swift` (create)

**Out of scope** (do NOT touch, even though they look related):
- The overflow-drain workaround in `HTTPTransport.swift:750-772`.
- The osascript timeout branch at `AppleScript.swift:588-612` — plan 047.
- `classifySendStderr` — plan 049.
- Session limits/timeouts values themselves.

## Git workflow

- Branch: `advisor/050-lifecycle-leaks`
- Commits: `fix: reserve the session slot before awaiting so the cap holds under concurrency`; `fix: stop the SDK Server when a session is terminated`; `fix: remove staged attachments on every exit path with a grace delay`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Session cap under concurrency (test first)

In `SessionManagerTests.swift` add `testConcurrentCreatesRespectTheCap`: construct a `SessionManager` with `maxSessions: 2` (read the initializer; if the cap is a constant, this test needs an initializer parameter with the existing value as default, which is an allowed change in this file), then `withThrowingTaskGroup` launch 10 `createSession` calls, collect successes and `capacityExceeded` errors, assert successes == 2. Use whatever fake transport the existing HTTP tests use to construct sessions (`HTTPTransportIntegrationTests.swift` shows how sessions are made; if creating a real `Server` per session is too heavy for the test, that is acceptable at n=10).

**Verify**: the test fails at `61e75d9` with more than 2 successes (it may pass by luck; run it 5 times, it must fail at least once). If it never fails, STOP and report; the interleaving may be prevented by something this plan missed.

Fix: in `createSession`, replace the count check with a reservation:

```swift
guard reservedSlots + sessions.count < maxSessions else { throw SessionError.capacityExceeded }
reservedSlots += 1
defer { reservedSlots -= 1 }
```

with `private var reservedSlots = 0` on the actor. The `defer` runs at every exit, including throws, and the insert into `sessions` happens before the function returns, so the count is never under-reported.

**Verify**: the test passes 5 consecutive runs.

### Step 2: `server.stop()` on terminate

Change `terminateSession` to be `async` and call `await session.server.stop()` after cancelling the task and before removing from the dictionary. Update the callers (`cleanupIdleSessions`, the DELETE handler in `HTTPTransport.swift`, and any test) to `await`. If `Server.stop()` can hang on a wedged transport, wrap it with a 2-second bound using the pattern in `AsyncTimeout` (a task group racing `stop()` against `AsyncTimeout.sleep(.seconds(2))`); do not use `Task.sleep`.

Fix the comment at `HTTPTransport.swift:647` to describe what actually happens.

Add `testTerminateStopsServer` to `SessionManagerTests`: create a session, terminate it, then assert that sending on its transport fails or that the `Server` reports not running (check swift-sdk 0.12.1's `Server` for an observable: `isRunning`, or the transport's `isConnected`; if there is no observable, assert via a fake transport whose `disconnect()` records a call).

**Verify**: `swift test --filter "SessionManagerTests|HTTPTransportIntegrationTests|LaunchdSafetyTests"` → 0 failures.

### Step 3: Staged directory cleanup

In `AppleScript.swift:376-405` make `.pending` and `.unknown` schedule a delayed removal instead of nothing:

```swift
case .pending, .unknown:
    scheduleDeferredStagedRemoval(stagingDirectory, after: .seconds(30))
    return .failure(.transferUnconfirmed)
```

Implement `scheduleDeferredStagedRemoval` with `DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { removeStagedDirectory(dir) }`. This is Dispatch, not `Task.sleep`, so the launchd rule is satisfied. `removeStagedDirectory` already guards to the staging root.

Also tighten the sweep at `:427-446`: change the 48-hour cutoff to 1 hour. Any staged file older than an hour belongs to a send that is long finished or dead.

Add `AppleScriptStagingTests.swift` with `testRemoveStagedDirectoryRefusesPathsOutsideRoot` (call `removeStagedDirectory` on a scratch directory outside `~/Pictures/imessage-max-staging` and assert it still exists) and `testSweepRemovesDirectoriesOlderThanCutoff` (create a subdirectory under the real staging root, set its modification date to 2 hours ago with `FileManager.setAttributes`, run the sweep, assert it is gone; clean up in `tearDown`). These touch the operator's real staging root; keep everything under a test-specific subdirectory name prefixed `xctest-` and delete it in `tearDown`.

**Verify**: `swift test --filter AppleScriptStagingTests` → 2 tests, 0 failures; `ls ~/Pictures/imessage-max-staging` shows no `xctest-` leftovers.

### Step 4: Full suite

**Verify**: `cd swift && swift test` → 0 failures.

## Test plan

- `SessionManagerTests`: concurrent cap (+1), terminate stops server (+1).
- `AppleScriptStagingTests` (new, 2).
- Existing `HTTPTransportIntegrationTests` cover the DELETE path and must stay green.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` → 0 failures
- [ ] `grep -n "reservedSlots" swift/Sources/iMessageMax/Server/SessionManager.swift` → ≥ 3 matches
- [ ] `grep -n "server.stop()" swift/Sources/iMessageMax/Server/SessionManager.swift` → one match inside `terminateSession`
- [ ] `grep -n "this also stops its Server instance" swift/Sources/iMessageMax/Server/HTTPTransport.swift` → no matches (comment rewritten)
- [ ] `grep -n "scheduleDeferredStagedRemoval" swift/Sources/iMessageMax/Utilities/AppleScript.swift` → ≥ 2 matches
- [ ] `grep -rn "Task.sleep" swift/Sources` → no matches
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Step 1's test never fails at `61e75d9` across 5 runs.
- swift-sdk `Server.stop()` is not public or has different semantics (for example it also tears down a shared transport). Read `.build/checkouts/swift-sdk/Sources/MCP/Server/Server.swift` and report.
- The staging-root sweep test cannot run because the test process lacks write access to `~/Pictures` (sandboxed CI). Mark that test with `XCTSkip` on `ProcessInfo.processInfo.environment["CI"] != nil` and say so in the report.

## Maintenance notes

- The reservation counter is the pattern for any actor that checks a limit and then awaits before committing. Reviewers should look for check-await-insert sequences in actors.
- The 30-second deferred removal is a guess at how long Messages holds the file after a timed-out poll. If attachment sends start failing with "file not found" right after a `transferUnconfirmed`, raise it; do not remove the removal.
