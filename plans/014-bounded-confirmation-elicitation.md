# Plan 014: Bound the send-confirmation elicitation wait

> **Executor instructions**: BASE CHECK FIRST — run
> `ls plans/014-bounded-confirmation-elicitation.md`. If missing, your worktree
> snapshot is stale: `git checkout -b advisor/014-bounded-elicitation <PLANS_COMMIT>`
> (SHA in dispatch message) and re-check; otherwise
> `git checkout -b advisor/014-bounded-elicitation`. Follow the plan exactly;
> run every verification; in-scope files only; STOP conditions honored; do not
> edit `plans/README.md`. Report: STATUS / STEPS / STOPPED BECAUSE /
> FILES CHANGED / NOTES.

## Status

- **Priority**: P1 (live failure observed in production via plug→Cursor)
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug / reliability
- **Planned at**: dispatch-message SHA, 2026-06-11

## Why this matters

Observed in production today: a client (Cursor, via the plug MCP multiplexer)
called `send` with a `chat_id` and no `confirm: true`. The confirmation gate
fired and the server called `server.requestElicitation(...)` —
`Send.swift:483`, inside `confirmSendWithClientIfAvailable` — which is an
**unbounded await**. Somewhere in the multiplexer chain the elicitation was
accepted but never answered, so the tool call hung until the client's own
300-second MCP timeout killed it. A trustworthy-core server must never hang a
tool call indefinitely: if confirmation can't be obtained within a bounded
window, the existing graceful path already exists (`.unavailable` → `pending`
status telling the agent to re-call with `confirm: true`) — we just need to
reach it on timeout.

## Current state

`swift/Sources/iMessageMax/Tools/Send.swift`:

- The gate (~line 340): `if shouldConfirmSend(...), !confirm { switch await
  confirmSendWithClientIfAvailable(...) { case .confirmed: break; case
  .declined: return .cancelled(...); case .unavailable: return .pending("This
  send requires confirmation. Call send again with confirm: true ...", ...) } }`
- `confirmSendWithClientIfAvailable` (~line 467): `guard let server else {
  return .unavailable }`, builds the prompt, then `try await
  server.requestElicitation(message:requestedSchema:mode:)` with **no
  timeout**; `catch { return .unavailable }`.
- `actor SendTool` init: `init(db:resolver:runner:verifier:)` (defaults for
  all but resolver).
- `server` is the MCP SDK `Server` type — not mockable in tests; the timeout
  logic must therefore live in a small testable helper, not be tested through
  a fake Server.

## Commands

| Purpose | Command | Expected |
|---------|---------|----------|
| Build | `cd swift && swift build` | exit 0 |
| All tests | `cd swift && swift test` | exit 0 (baseline 142) |
| Focused | `cd swift && swift test --filter ElicitationTimeoutTests` | all pass |

## Scope

**In scope**:
- `swift/Sources/iMessageMax/Tools/Send.swift`
- `swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift` (create)
- `swift/Tests/iMessageMaxTests/ElicitationTimeoutTests.swift` (create)

**Out of scope**: everything else — especially `SendVerifier.swift`,
`SendResolution.swift`, `Diagnose.swift`, the elicitation prompt wording, and
`shouldConfirmSend`'s rules (which sends require confirmation is policy, not
this bug).

## Git workflow

Branch `advisor/014-bounded-elicitation`; lowercase conventional commits; no
push, no PR.

## Steps

### Step 1: Generic bounded-await helper

Create `swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift`:

```swift
import Foundation

enum AsyncTimeout {
    /// Runs `operation` with a deadline. Returns its value, or nil if the
    /// deadline elapses first (the operation task is then cancelled — note
    /// that operations which ignore cancellation may linger in the
    /// background; callers must treat nil as "no answer", not "declined").
    static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                try? await operation()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
```

CAUTION on semantics: with this shape, an operation that THROWS quickly
returns nil (indistinguishable from timeout). That is acceptable HERE because
the caller maps both cases to `.unavailable` — document it in the doc comment.

**Verify**: `cd swift && swift build` → exit 0.

### Step 2: Wire into the confirmation path

In `SendTool`:
- Add `confirmationTimeout: Duration = .seconds(60)` as a stored property +
  init parameter (default keeps `register` call sites unchanged).
- In `confirmSendWithClientIfAvailable`, wrap the existing
  `server.requestElicitation(...)` call:

```swift
        let result = await AsyncTimeout.withTimeout(confirmationTimeout) {
            try await server.requestElicitation(
                message: ..., requestedSchema: ..., mode: .form
            )
        }
        guard let result else { return .unavailable }   // timeout or transport error
        guard result.action == .accept else { return .declined }
        return result.content?["confirm"]?.boolValue == true ? .confirmed : .declined
```

  (The old `do/catch → .unavailable` collapses into the nil branch.) Keep the
  prompt construction code untouched above the call.

**Verify**: `cd swift && swift build` → exit 0; `cd swift && swift test` →
142 pass (no behavior change for test paths — they pass `server: nil` or
`confirm: true`).

### Step 3: Tests

`swift/Tests/iMessageMaxTests/ElicitationTimeoutTests.swift`:

1. `testTimeoutReturnsNilWhenOperationHangs` — operation awaits
   `Task.sleep(for: .seconds(30))`; timeout `.milliseconds(50)`; expect nil;
   assert elapsed < 1s.
2. `testFastOperationWinsOverTimeout` — operation returns 42 immediately;
   timeout `.seconds(5)`; expect 42; assert elapsed < 1s.
3. `testThrowingOperationReturnsNil` — operation throws; expect nil.
4. `testHangingConfirmationYieldsPendingStatus` — end-to-end through
   `SendTool` IF feasible without a real `Server`: since `server` is nil in
   the test harness, the gate already short-circuits to `.unavailable` before
   the timeout code — so instead assert the EXISTING behavior still holds
   (chat-route send without `confirm` and `server: nil` → status
   `pending_confirmation` with the re-call guidance). This pins the graceful
   path the timeout now also routes to.

**Verify**: `cd swift && swift test --filter ElicitationTimeoutTests` → 4
pass; full suite green (report count).

## Done criteria

- [ ] `swift build` exit 0; `swift test` all pass (report count, expect 146)
- [ ] `grep -n "requestElicitation" swift/Sources/iMessageMax/Tools/Send.swift` shows the call inside the `AsyncTimeout.withTimeout` wrapper
- [ ] `grep -n "confirmationTimeout" swift/Sources/iMessageMax/Tools/Send.swift` shows the injectable property with `.seconds(60)` default
- [ ] Only in-scope files changed

## STOP conditions

- `requestElicitation`'s return type is not Sendable (the task-group helper
  won't compile) — report the exact type; do not work around with unchecked
  Sendable on SDK types.
- Any existing test fails after Step 2.

## Maintenance notes

- If the SDK later adds native elicitation timeouts, prefer that and delete
  the wrapper.
- The 60s default is a human-answer budget; clients that want snappier
  behavior should pass `confirm: true` explicitly (agents reviewing
  destination first is the intended trustworthy-core flow).
