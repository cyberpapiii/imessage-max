# Plan 019: Purge the three remaining Task.sleep sites from the service runtime

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat e3d14da..HEAD -- swift/Sources/iMessageMax/Server/SessionManager.swift swift/Sources/iMessageMax/Server/SSEConnection.swift swift/Sources/iMessageMax/Tools/GetAttachment.swift swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P0
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `e3d14da`, 2026-08-07

## Why this matters

This repo has a documented production-crash pattern: **sleeping Swift tasks
abort intermittently inside the launchd-run service** (`swift_task_dealloc` /
"freed pointer was not the last allocation"). It crashed production on
2026-06-11 (see `AGENTS.md` "No Task.sleep in the service runtime" and plan
`plans/015-launchd-safe-timers.md`). Plan 015 removed `Task.sleep` from the
send path, but three sites survived — two of which are *permanently armed* in
the HTTP service: the session-cleanup loop wakes every 5 minutes for the
process lifetime, and every live SSE connection wakes every 30 seconds. Any
one of those wakeups can abort the whole launchd service, killing every
active session. The sanctioned replacement, `AsyncTimeout.sleep`, already
exists and is used by `SendVerifier.swift:67`.

## Current state

Files and their roles:

- `swift/Sources/iMessageMax/Server/SessionManager.swift` — per-session Server
  instances for the legacy HTTP lane; contains the 5-minute cleanup loop.
- `swift/Sources/iMessageMax/Server/SSEConnection.swift` — SSE channel/manager;
  contains the 30-second keep-alive loop.
- `swift/Sources/iMessageMax/Tools/GetAttachment.swift` — attachment tool;
  contains a 500ms polling loop waiting for an iCloud download.
- `swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift` — the sanctioned
  Dispatch-backed sleep. Do not modify it; just call it.

The three offending sites (verbatim, as of `e3d14da`):

`SessionManager.swift:228-235`:

```swift
    /// Starts the background cleanup task
    private func startCleanupTask() {
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))  // Run every 5 minutes
                await self?.cleanupExpiredSessions()
            }
        }
    }
```

`SSEConnection.swift:106-113` (inside the computed `stream` property's
`withTaskGroup`):

```swift
                    // Keep-alive task
                    group.addTask {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(30))
                            if Task.isCancelled { break }
                            continuation.yield(SSEEvent.keepAlive())
                        }
                    }
```

`GetAttachment.swift:368-374` (inside `tryDownloadFromiCloud`):

```swift
            // Wait briefly for small files
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if FileManager.default.fileExists(atPath: url.path) {
                    return true
                }
            }
```

The replacement API (`AsyncTimeout.swift:3-13`, do not change):

```swift
enum AsyncTimeout {
    /// Dispatch-backed sleep. NEVER sleep Swift tasks inside the launchd service
    /// (sleeping unstructured tasks abort in swift_task_dealloc at wakeup —
    /// see HTTPTransport.swift storePendingRequest for the known-good pattern.)
    static func sleep(_ duration: Duration) async {
```

Behavioral difference to be aware of: `Task.sleep` throws on task
cancellation (so a cancelled task wakes immediately); `AsyncTimeout.sleep`
is non-throwing and non-cancellable (a cancelled task wakes at the end of
the interval). All three call sites already check `Task.isCancelled` in
their loop condition, so the only change is that loop exit can lag by one
interval. That is acceptable and is the same trade plan 015 made.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| Tests | `cd swift && swift test` | exit 0, 174+ tests pass, 0 failures |
| Regression grep | `grep -rn "Task.sleep" swift/Sources/` | only the comment at `HTTPTransport.swift:657` (the words "Task.sleep" in a comment), no code calls |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Server/SessionManager.swift`
- `swift/Sources/iMessageMax/Server/SSEConnection.swift`
- `swift/Sources/iMessageMax/Tools/GetAttachment.swift`
- `swift/Tests/iMessageMaxTests/LaunchdSafetyTests.swift` (create)
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):
- `swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift` — the replacement
  primitive; it is correct as-is.
- `swift/Sources/iMessageMax/Server/HTTPTransport.swift` — its Dispatch-timer
  pattern is the known-good exemplar; other plans own its changes.
- Any restructuring of `SSEChannel.stream` (its computed-property design has a
  separate plan, 029). Only replace the sleep call here.
- `Thread.sleep` / semaphore usage in `AppleScript.swift` — separate plan (024).

## Git workflow

- Branch: `advisor/019-launchd-safe-timers-round-2`
- Commit style: conventional commits, e.g. `fix: replace remaining Task.sleep with AsyncTimeout.sleep (launchd allocator crash pattern)` (match `git log --oneline` style: `fix:`, `feat:`, `docs:`, `test:`)
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Replace the sleep in SessionManager

In `SessionManager.swift`, change line 231 from

```swift
                try? await Task.sleep(for: .seconds(300))  // Run every 5 minutes
```

to

```swift
                await AsyncTimeout.sleep(.seconds(300))  // Run every 5 minutes
```

**Verify**: `cd swift && swift build` → exit 0.

### Step 2: Replace the sleep in SSEConnection

In `SSEConnection.swift`, change line 109 from

```swift
                            try? await Task.sleep(for: .seconds(30))
```

to

```swift
                            await AsyncTimeout.sleep(.seconds(30))
```

Keep the `if Task.isCancelled { break }` line that follows — it is now the
only cancellation exit for this loop and must stay.

**Verify**: `cd swift && swift build` → exit 0.

### Step 3: Replace the sleep in GetAttachment

In `GetAttachment.swift`, change line 370 from

```swift
                try? await Task.sleep(nanoseconds: 500_000_000)
```

to

```swift
                await AsyncTimeout.sleep(.milliseconds(500))
```

**Verify**: `cd swift && swift build` → exit 0.

### Step 4: Add a source-level regression tripwire test

Create `swift/Tests/iMessageMaxTests/LaunchdSafetyTests.swift`. It walks the
`Sources/` tree from the test file's own location and fails if any Swift
source calls `Task.sleep(`. Target shape:

```swift
import XCTest

final class LaunchdSafetyTests: XCTestCase {
    /// Task.sleep aborts intermittently inside the launchd-run service
    /// (see AGENTS.md "No Task.sleep in the service runtime"). Use
    /// AsyncTimeout.sleep or the Dispatch-timer pattern instead.
    func testNoTaskSleepInServiceSources() throws {
        let testsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()               // iMessageMaxTests
            .deletingLastPathComponent()               // Tests
        let sourcesDir = testsDir.deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: sourcesDir, includingPropertiesForKeys: nil)
        )
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let content = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in content.components(separatedBy: "\n").enumerated()
            where line.contains("Task.sleep(") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                offenders.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
        XCTAssertEqual(offenders, [], "Task.sleep is forbidden in the service runtime; use AsyncTimeout.sleep. Found: \(offenders)")
    }
}
```

Adjust the directory math if the path resolution fails — the invariant is
"scan every `.swift` file under `swift/Sources/`", however you get there.

**Verify**: `cd swift && swift test --filter LaunchdSafetyTests` → 1 test, 0 failures.

### Step 5: Full suite

**Verify**: `cd swift && swift test` → exit 0, 0 failures, total test count ≥ 175.

## Test plan

- New: `LaunchdSafetyTests.testNoTaskSleepInServiceSources` (step 4) — the
  regression tripwire that keeps this class of bug out permanently.
- Existing suites exercising the changed code paths must stay green:
  `HTTPTransportIntegrationTests`, `HTTPTransportTests` (SSE formatting),
  and the `GetAttachmentToolTests` class inside
  `swift/Tests/iMessageMaxTests/PlaceholderTests.swift`.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift build` exits 0
- [ ] `cd swift && swift test` exits 0 with 0 failures
- [ ] `grep -rn "Task.sleep(" swift/Sources/ | grep -v "^.*//"` → no matches in code (comment mentions are fine)
- [ ] `LaunchdSafetyTests` exists and passes
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The code at any of the three cited sites doesn't match the excerpts above.
- `AsyncTimeout.sleep` does not exist at
  `swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift` or has a different
  signature than `static func sleep(_ duration: Duration) async`.
- The tripwire test finds `Task.sleep(` call sites *other than* the three in
  this plan — that means new ones appeared since planning; report them.
- Any existing test fails after the swaps.

## Maintenance notes

- Deploying is an operator action: `cd swift && make install` after merge.
- The tripwire test makes the AGENTS.md rule self-enforcing. If a future
  legitimate use of `Task.sleep` ever appears (e.g. in a non-service CLI
  path), the test must be consciously amended — that friction is the point.
- Plan 029 restructures `SSEChannel.stream`; it must keep using
  `AsyncTimeout.sleep` for the keep-alive.
