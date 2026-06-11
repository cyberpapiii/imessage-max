# Plan 016: Narrow the send-confirmation gate to genuinely risky sends

> **Executor instructions**: BASE CHECK FIRST — run
> `ls plans/016-narrow-confirmation-gate.md`. If missing:
> `git checkout -b advisor/016-narrow-confirmation <PLANS_COMMIT>` (SHA in
> dispatch message) and re-check; otherwise
> `git checkout -b advisor/016-narrow-confirmation`. Follow exactly; verify
> every step; in-scope files only; do not edit `plans/README.md`. Report:
> STATUS / STEPS / STOPPED BECAUSE / FILES CHANGED / NOTES.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW-MED (send-safety policy change — deliberately narrow)
- **Depends on**: plan 015 merged (your base contains it)
- **Category**: bug / product
- **Planned at**: dispatch-message SHA, 2026-06-11

## Why this matters

`shouldConfirmSend` (Send.swift:458-468) gates four cases; three match the v2
requirements (R4: group sends, file sends, risky content — here: multiple
recipients, files, >500-char texts). The fourth — `if case .chat =
resolved.target { return true }` — gates EVERY chat-id-targeted send, even a
short text to a single known person. Group chats are ALREADY caught by
`deliveredTo.count > 1` (chat targets populate `deliveredTo` with all
participants — `SendResolution.resolveChatId`), so the rule's only marginal
effect is friction on the safest send shape, which happens to be the natural
first attempt of every fresh agent (find_chat → send by chat_id). Observed
2026-06-11: that friction drove a real client (Cursor) to bypass MCP entirely
and send via raw AppleScript — no gate, no verification. Removing the
redundant rule keeps every R4 gate intact while making the safe path work
first try, with delivery proof.

## Current state

- `swift/Sources/iMessageMax/Tools/Send.swift:458-468`:

```swift
    private func shouldConfirmSend(
        resolved: SendResolution.ResolvedTarget,
        text: String?,
        filePaths: [String]?
    ) -> Bool {
        if resolved.deliveredTo.count > 1 { return true }
        if filePaths?.isEmpty == false { return true }
        if let text, text.count > 500 { return true }
        if case .chat = resolved.target { return true }
        return false
    }
```

- Dependent test that WILL break:
  `ElicitationTimeoutTests.testHangingConfirmationYieldsPendingStatus` pins
  "chat-route 1:1 send without confirm + server nil → pending_confirmation".
  After this change a 1:1 chat send no longer gates — rewrite that test to use
  a gated scenario instead (group chat target: 2+ participants in the fixture
  chat → `deliveredTo.count > 1` → still pending). Same assertion, gated
  trigger.
- `SendToolExecuteTests` chat-route tests pass `confirm: true` — they remain
  valid unchanged (the parameter is still accepted; it just isn't required
  for 1:1).
- The `send` tool description (in `SendTool.register`, Send.swift ~228+) —
  check whether it states that chat-targeted sends require confirmation; if
  so, update the wording to: confirmation is required for group sends, file
  sends, and long texts.

## Commands

| Purpose | Command | Expected |
|---------|---------|----------|
| Build | `cd swift && swift build` | exit 0 |
| All tests | `cd swift && swift test` | exit 0 (baseline 148) |

## Scope

**In scope**:
- `swift/Sources/iMessageMax/Tools/Send.swift` (delete the one rule; possible
  description wording)
- `swift/Tests/iMessageMaxTests/ElicitationTimeoutTests.swift` (rewrite the
  one dependent test's trigger)
- `swift/Tests/iMessageMaxTests/SendToolExecuteTests.swift` (add tests below)

**Out of scope**: everything else. Do NOT touch the other three gate rules,
`confirmSendWithClientIfAvailable`, `AsyncTimeout`, `SendVerifier`,
`SendResolution`.

## Git workflow

Branch `advisor/016-narrow-confirmation`; lowercase conventional commits; no
push, no PR.

## Steps

### Step 1: Delete the rule

Remove `if case .chat = resolved.target { return true }` from
`shouldConfirmSend`. Add a one-line comment above the function noting the
policy: gates = multiple recipients, files, long texts (R4); 1:1 short texts
send directly and rely on post-send verification.

**Verify**: `swift build` → exit 0.

### Step 2: Fix the dependent test

Rewrite `testHangingConfirmationYieldsPendingStatus` to target a GROUP chat
(fixture chat with 2 handles joined) by chat_id, no confirm, `server: nil` →
assert `pending_confirmation` exactly as before.

**Verify**: `swift test --filter ElicitationTimeoutTests` → 6 pass.

### Step 3: Add policy tests to SendToolExecuteTests

1. `testOneToOneChatSendWithoutConfirmSends` — 1:1 chat target (DM fixture),
   NO confirm, stub runner with the staged-row side-effect (existing
   `onSend` hook) → status `confirmed`, stub invoked once via textToChat.
   This is the fresh-agent natural flow, now working.
2. `testGroupChatSendWithoutConfirmStillGates` — group chat target, NO
   confirm, `server: nil` → `pending_confirmation`, stub NOT invoked.
3. `testLongTextStillGates` — 1:1 target, 501-char text, no confirm,
   `server: nil` → `pending_confirmation`, stub NOT invoked.

**Verify**: `swift test --filter SendToolExecuteTests` → 12 pass
(9 existing + 3); full suite → 151 pass.

## Done criteria

- [ ] `swift build` exit 0; `swift test` → 151 pass
- [ ] `grep -n "case .chat = resolved.target" swift/Sources/iMessageMax/Tools/Send.swift` → no matches
- [ ] The other three gate rules unchanged (visible in `git diff`)
- [ ] Only in-scope files changed

## STOP conditions

- `deliveredTo` for chat targets turns out NOT to contain all participants
  (would mean group chats lose their gate when the rule is deleted) — verify
  in `SendResolution.resolveChatId` FIRST; if false, STOP.
- Any test outside the two named files fails.

## Maintenance notes

- If a future "ambiguous target" confirmation case is added (R4 mentions it),
  it belongs in `shouldConfirmSend` alongside these rules.
- Reviewer post-deploy gate: live no-confirm 1:1 send through the launchd
  service must return `confirmed` with a stable PID.
