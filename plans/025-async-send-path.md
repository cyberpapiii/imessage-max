# Plan 025: Move blocking send work off the Swift concurrency pool + fix pipe-drain deadlock

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report, do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat e3d14da..HEAD -- swift/Sources/iMessageMax/Utilities/AppleScript.swift swift/Sources/iMessageMax/Tools/Send.swift swift/Tests/iMessageMaxTests/SendToolExecuteTests.swift`
> Plans 021, 023, and 024 also touch these files and should land first. After
> they land the line numbers below will have shifted, match on the code
> shapes, not the numbers. If a *shape* is missing (e.g. the semaphore wait
> is gone), treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED (concurrency boundary change on the only write path)
- **Depends on**: 021, 024 (both edit the same files; this plan restructures
  around their changes and must preserve them, notably 024's
  `removeStagedDirectory` calls and 023's stderr clamp)
- **Category**: bug
- **Planned at**: commit `e3d14da`, 2026-08-07

## Why this matters

The whole send pipeline is synchronous blocking code called from an actor's
async context. `SendTool` (an actor) calls `LiveScriptRunner`, which calls
`AppleScriptRunner` statics that block the calling thread:
`semaphore.wait(timeout:)` for up to the script timeout while `osascript`
runs, and `Thread.sleep(forTimeInterval: 0.5)` in a poll loop for up to 15
more seconds for file transfers. Because the caller is Swift-concurrency
code, that thread is a **cooperative-pool thread**, a resource sized to the
CPU count that every actor and async task in the process shares. One slow
Messages.app interaction can pin a pool thread for ~45 seconds; in the
launchd HTTP service that means unrelated requests (list_chats, get_messages,
session handling) stall behind a send. This is the same class of
service-wide hazard as the Task.sleep crashes (plans 015/019), expressed as
starvation instead of a crash.

Separately, `execute` has a latent **pipe-drain deadlock**: it calls
`process.waitUntilExit()` (via the semaphore) *before* reading the stdout /
stderr pipes. A pipe buffer holds ~64KB; if osascript writes more (e.g. a
huge error cascade), the child blocks on write, never exits, the semaphore
times out, and the send is falsely reported as `.timeout`.

The fix has two parts, deliberately conservative: (1) make the
`ScriptRunning` boundary async and hop the blocking work onto a GCD
background thread, `Thread.sleep` and semaphores are *fine* on GCD threads
(GCD scales its thread pool; the repo's launchd crash pattern is about
`Task.sleep`, which this plan does not introduce); (2) drain the pipes
concurrently with the exit wait.

## Current state

### The boundary to make async

`swift/Sources/iMessageMax/Utilities/AppleScript.swift:4-32`:

```swift
/// Abstraction over the four send-execution functions used by SendTool.
/// The production implementation is LiveScriptRunner; tests inject a stub.
protocol ScriptRunning: Sendable {
    func sendTextToParticipant(handle: String, message: String) -> Result<Void, SendError>
    func sendFileToParticipant(handle: String, filePath: String) -> Result<Void, SendError>
    func sendTextToChat(guid: String, message: String) -> Result<Void, SendError>
    func sendFileToChat(guid: String, filePath: String) -> Result<Void, SendError>
}

/// Production implementation: forwards to AppleScriptRunner statics.
struct LiveScriptRunner: ScriptRunning {
    func sendTextToParticipant(handle: String, message: String) -> Result<Void, SendError> {
        AppleScriptRunner.sendTextToParticipant(handle: handle, message: message)
    }
    ... (three more identical forwards)
}
```

### The blocking sites (stay as-is, but move to a GCD thread)

`AppleScriptRunner.execute` (`AppleScript.swift:457-502` at `e3d14da`):

```swift
        do {
            try process.run()

            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                process.waitUntilExit()
                semaphore.signal()
            }

            let result = semaphore.wait(timeout: .now() + .seconds(timeoutSeconds))
            if result == .timedOut {
                process.terminate()
                return .failure(.timeout)
            }

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            ...
```

The transfer poll (`waitForTransferCompletion`, `:320-361`) blocks with
`Thread.sleep(forTimeInterval: pollInterval)` at `:351`, after this plan it
runs on a GCD thread where that is acceptable; do not rewrite it.

### The call sites that gain `await`

`swift/Sources/iMessageMax/Tools/Send.swift:330-350` (inside
`actor SendTool`; runner property at `:190`, injected at `:197`):

```swift
        let sendResults: [Result<Void, SendError>]
        switch resolved.target {
        case .participant(let handle, _):
            sendResults = payloads.map { payload in
                switch payload {
                case .text(let body):
                    return runner.sendTextToParticipant(handle: handle, message: body)
                case .file(let path):
                    return runner.sendFileToParticipant(handle: handle, filePath: path)
                }
            }
        case .chat(let guid, _):
            ... (same shape with sendTextToChat/sendFileToChat)
        }
```

(`payloads.map` with a non-async closure, will need a `for` loop once the
calls are `await`ed.)

### The test stub

`swift/Tests/iMessageMaxTests/SendToolExecuteTests.swift:11-48`:
`final class StubScriptRunner: ScriptRunning, @unchecked Sendable` with the
four methods appending to `invocations`, running `onSend?()`, returning
`nextResult`. Tests construct `SendTool(..., runner: stub, ...)`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| Send tests | `cd swift && swift test --filter SendToolExecuteTests` | all pass |
| Runner tests | `cd swift && swift test --filter AppleScriptRunnerValidationTests` | all pass |
| Full suite | `cd swift && swift test` | exit 0, 0 failures |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Utilities/AppleScript.swift`
- `swift/Sources/iMessageMax/Tools/Send.swift` (the runner call sites and
  any signatures the `await` forces)
- `swift/Tests/iMessageMaxTests/SendToolExecuteTests.swift` (stub gains
  `async` keywords)
- `swift/Tests/iMessageMaxTests/PlaceholderTests.swift` (only if
  `AppleScriptRunnerValidationTests` or other classes call changed
  signatures)
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):
- Rewriting `waitForTransferCompletion` polling with AsyncTimeout or timers,
  the GCD hop makes `Thread.sleep` acceptable; a rewrite adds risk for no
  service-level gain.
- `SendVerifier`, already async and launchd-safe.
- Error strings (023), staged-file cleanup logic (024), preserve both
  verbatim through the restructuring.
- Introducing `Task.sleep` anywhere, plan 019's `LaunchdSafetyTests`
  tripwire will fail the build of any such attempt; that is by design.

## Git workflow

- Branch: `advisor/025-async-send-path`
- Conventional commits, e.g. `fix: hop blocking osascript work off the cooperative pool; drain pipes concurrently`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Fix the pipe-drain deadlock inside `execute`

In `AppleScriptRunner.execute`, start draining both pipes on background GCD
queues **before** waiting for exit, then join after:

```swift
        do {
            try process.run()

            // Drain pipes concurrently with the exit wait. Reading only after
            // exit deadlocks when the child fills a ~64KB pipe buffer: the
            // child blocks on write, never exits, and the wait times out.
            var stdoutData = Data()
            var stderrData = Data()
            let drainGroup = DispatchGroup()
            drainGroup.enter()
            DispatchQueue.global().async {
                stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                drainGroup.leave()
            }
            drainGroup.enter()
            DispatchQueue.global().async {
                stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                drainGroup.leave()
            }

            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                process.waitUntilExit()
                semaphore.signal()
            }

            let result = semaphore.wait(timeout: .now() + .seconds(timeoutSeconds))
            if result == .timedOut {
                process.terminate()
                return .failure(.timeout)
            }
            drainGroup.wait()

            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            ...
```

(If the compiler rejects the captured `var`s under strict concurrency, use a
small `final class` box with `@unchecked Sendable` or `DispatchQueue`-confined
storage, match whatever pattern compiles cleanly; the invariant is
"reads start before the wait, join after".)

**Verify**: `cd swift && swift build` → exit 0.

### Step 2: Make the `ScriptRunning` boundary async

1. Add `async` to all four protocol requirements:

```swift
protocol ScriptRunning: Sendable {
    func sendTextToParticipant(handle: String, message: String) async -> Result<Void, SendError>
    ...
}
```

2. In `LiveScriptRunner`, hop each call onto a GCD thread so the blocking
   internals never occupy a cooperative-pool thread. Add one private helper
   and route all four methods through it:

```swift
/// Production implementation: forwards to AppleScriptRunner statics.
/// The statics block their thread (process wait, transfer polling), so run
/// them on a GCD background thread — never on the cooperative pool.
struct LiveScriptRunner: ScriptRunning {
    private func onBackgroundThread(
        _ work: @escaping @Sendable () -> Result<Void, SendError>
    ) async -> Result<Void, SendError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    func sendTextToParticipant(handle: String, message: String) async -> Result<Void, SendError> {
        await onBackgroundThread { AppleScriptRunner.sendTextToParticipant(handle: handle, message: message) }
    }
    ... (three more, same shape)
}
```

**Verify**: `cd swift && swift build` → errors only at `Send.swift` call
sites and the test stub (expected; next steps).

### Step 3: Await at the call sites

In `Send.swift`, replace the two `payloads.map { ... }` blocks (`:330-350`
shape) with sequential loops, payload order must be preserved (a text
following a file must send after it):

```swift
        var sendResults: [Result<Void, SendError>] = []
        switch resolved.target {
        case .participant(let handle, _):
            for payload in payloads {
                switch payload {
                case .text(let body):
                    sendResults.append(await runner.sendTextToParticipant(handle: handle, message: body))
                case .file(let path):
                    sendResults.append(await runner.sendFileToParticipant(handle: handle, filePath: path))
                }
            }
        case .chat(let guid, _):
            ... (same shape)
        }
```

Everything downstream (`sendResults` handling) is unchanged. Fix any other
compile errors the `await` surfaces (the enclosing function is already
`async throws`).

**Verify**: `cd swift && swift build` → errors only in tests.

### Step 4: Update the stub and tests

In `SendToolExecuteTests.swift`, add `async` to the four `StubScriptRunner`
method signatures (bodies unchanged). Fix any test call sites the compiler
flags (tests already run in async contexts). If `PlaceholderTests.swift`
classes call the four `AppleScriptRunner.send*` statics directly, they are
**unchanged** (the statics stay synchronous, only the protocol/LiveScriptRunner
boundary went async), so no edits should be needed there; verify by building.

**Verify**: `cd swift && swift test` → exit 0, 0 failures.

### Step 5: Confirm preserved behaviors

Read your own diff and confirm:

- 024's `removeStagedDirectory` calls: all four still present, same
  positions (`grep -c "removeStagedDirectory" ...AppleScript.swift` = 5).
- 023's stderr clamp and `lastPathComponent` fileNotFound: unchanged.
- No `Task.sleep` introduced (`swift test --filter LaunchdSafetyTests` passes).

**Verify**: the three checks above.

## Test plan

No new test files, this plan is a concurrency-boundary refactor whose
behavior is locked by the existing `SendToolExecuteTests` (routing, failure
propagation, verification statuses) and `AppleScriptRunnerValidationTests`.
The pipe-drain fix is not practically unit-testable without spawning real
processes; if you want a cheap smoke test, a single test may run
`AppleScriptRunner.runScriptForTesting`-style execution of `/usr/bin/true`
via the existing test seams **only if** one already exists, do not add new
process-spawning machinery.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` exits 0; 0 failures
- [ ] `grep -n "async -> Result<Void, SendError>" swift/Sources/iMessageMax/Utilities/AppleScript.swift` → 4 protocol + 4 impl matches (8)
- [ ] `grep -n "readDataToEndOfFile" swift/Sources/iMessageMax/Utilities/AppleScript.swift` → both reads occur before the semaphore wait in `execute` (confirm by reading the function)
- [ ] `grep -rn "Task.sleep(" swift/Sources/` → no code matches (LaunchdSafetyTests green)
- [ ] `grep -c "removeStagedDirectory" swift/Sources/iMessageMax/Utilities/AppleScript.swift` = 5
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Plans 021/023/024 have not landed and their shapes are absent, land order
  matters; report rather than merging their work into this branch.
- Strict-concurrency errors push you toward marking types `@unchecked
  Sendable` beyond the one pipe-drain box, that's a design smell; report.
- Any existing send test changes *behavioral* expectations (not just
  signatures) to pass, the refactor must be behavior-preserving.
- You find additional cooperative-pool blocking in the send path not listed
  here (e.g. in `SendResolution`), report; it extends this plan's scope.

## Maintenance notes

- Review invariant: **nothing called from async contexts may block its
  thread** unless it has been hopped to GCD first. `LiveScriptRunner` is the
  single sanctioned hop point for the send path.
- If the send path is ever parallelized across payloads, the sequential
  `for` loop in Step 3 is the thing being deliberately given up, don't
  parallelize; Messages.app ordering matters.
- Manual validation (operator action): one real text send + one real file
  send after deploy; add rows to
  `swift/Tests/iMessageMaxTests/SendManualValidation.md`.
