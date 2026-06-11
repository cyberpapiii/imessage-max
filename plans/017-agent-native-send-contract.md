# Plan 017: Agent-native send contract (remove elicitation; narrow the gate)

> **Executor instructions**: BASE CHECK FIRST — run
> `ls plans/017-agent-native-send-contract.md`. If missing:
> `git checkout -b advisor/017-agent-native-send <PLANS_COMMIT>` (SHA in
> dispatch message) and re-check; otherwise
> `git checkout -b advisor/017-agent-native-send`. Follow exactly; verify
> every step; in-scope files only; do not edit `plans/README.md`. Report:
> STATUS / STEPS / STOPPED BECAUSE / FILES CHANGED / NOTES.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED (send-policy change, but strictly REMOVES code paths; every
  remaining path is already tested)
- **Depends on**: 015 merged (your base contains it)
- **Supersedes**: plan 016 (parked, never dispatched — this plan includes its
  gate change plus the elicitation removal the live debugging showed is the
  real fix)
- **Category**: bug / product / reliability
- **Planned at**: `4427cef`, 2026-06-11

## Why this matters

Live debugging on 2026-06-11 (documented in `plans/README.md` →
"Elicitation channel findings") established that the interactive MCP
elicitation confirmation has NEVER completed a round trip in the operator's
client stack: it hung (pre-014), crashed the launchd service (014's
Task.sleep timer), and now — post-015 — burns a silent 25 seconds before
degrading to `pending_confirmation`. Two unverified preconditions are
conflated in the current design: client elicitation capability is never
checked (SDK validates only in strict mode; we run default non-strict), and
server-originated requests are silently dropped when the session has no SSE
connection (`SSEConnection.broadcast` guard).

The operator's decision: the send tool must behave like a synchronous
command — an agent calls it, gets a truthful result, and moves on. Human
authorization happens in the conversation between the operator and the agent,
not in a popup the server tries to summon. Therefore: remove elicitation from
the send path entirely (not "optional" — optional broken paths still cost
tests, docs, and debugging time), drop the redundant blanket chat-id gate
rule, and make the remaining gate instant.

The send contract after this plan:

1. A short 1:1 text send (either route) sends immediately and verifies via
   chat.db → `confirmed` / `uncertain` / `mismatch` / `sent`.
2. Risky shapes — multiple recipients, file attachments, texts >500 chars —
   without `confirm: true` return `pending_confirmation` IMMEDIATELY (no
   wait, no popup attempt), with the exact retry instruction.
3. `confirm: true` remains the explicit acknowledgment flag and is accepted
   on any send.
4. No send path waits on anything interactive; no send path can hang or
   crash the service.

## Current state

- `swift/Sources/iMessageMax/Tools/Send.swift`:
  - `shouldConfirmSend` (~line 458): four rules; rule 4
    (`if case .chat = resolved.target { return true }`) gates EVERY chat-id
    send. Group chats are independently caught by `deliveredTo.count > 1`
    (chat targets populate `deliveredTo` with all participants —
    `SendResolution.resolveChatId`).
  - Gate block (~line 343): `switch await confirmSendWithClientIfAvailable(...)`
    with `.confirmed` / `.declined` / `.unavailable` arms.
  - `confirmSendWithClientIfAvailable` (~line 470): builds the prompt, calls
    `server.requestElicitation` inside `AsyncTimeout.withTimeout(confirmationTimeout)`.
  - `confirmationTimeout: Duration = .seconds(25)` stored property + init param
    (~lines 209, 217, 223).
  - `execute(args:server:)` (~line 275) and private `send(...server:)` thread a
    `server: Server?` whose ONLY use is elicitation.
  - `register` closure (~line 269): `try await tool.execute(args: args, server: server)`.
  - Input schema `confirm` description (~line 257): "Explicitly confirm risky
    sends when elicitation is unavailable" — stale after this change.
- `swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift`: `sleep` (used by
  `SendVerifier` — KEEP) and `withTimeout` (only caller is the elicitation
  path — DELETE).
- `swift/Tests/iMessageMaxTests/ElicitationTimeoutTests.swift`: 6 tests —
  4 pin `withTimeout` mechanics, 1 pins `AsyncTimeout.sleep`, 1
  (`testHangingConfirmationYieldsPendingStatus`) pins "1:1 chat-route send
  without confirm + server nil → pending_confirmation" (a scenario this plan
  makes obsolete: 1:1 no longer gates).
- `swift/Tests/iMessageMaxTests/SendToolExecuteTests.swift`: chat-route tests
  pass `confirm: true` — they remain valid (the flag is still accepted).
- `AGENTS.md`: check for any description of the confirmation flow; the
  "No Task.sleep in the service runtime" section stays.

Record the full-suite baseline count before starting (`swift test`; expected
148) and report the before/after counts.

## Commands

| Purpose | Command | Expected |
|---------|---------|----------|
| Build | `cd swift && swift build` | exit 0 |
| All tests | `cd swift && swift test` | exit 0 |

## Scope

**In scope**:
- `swift/Sources/iMessageMax/Tools/Send.swift`
- `swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift`
- `swift/Tests/iMessageMaxTests/ElicitationTimeoutTests.swift`
- `swift/Tests/iMessageMaxTests/SendToolExecuteTests.swift`
- `AGENTS.md` (confirmation-flow wording only)

**Out of scope**: `SendVerifier` (and its bounded post-send polling — that is
DB observation, not human confirmation; untouched), `SendResolution`,
`HTTPTransport`, `SessionManager`, `SSEConnection`, `Diagnose`, the
attachment/file-transfer status checks, everything else.

## Git workflow

Branch `advisor/017-agent-native-send`; lowercase conventional commits; no
push, no PR.

## Steps

### Step 1: Narrow the gate

In `shouldConfirmSend`, delete `if case .chat = resolved.target { return true }`.
Add a one-line comment above the function: gates = multiple recipients, file
sends, texts >500 chars; 1:1 short texts send directly and rely on post-send
verification; human-popup confirmation is intentionally not implemented.

**Verify**: `swift build` → exit 0;
`grep -n "case .chat = resolved.target" swift/Sources/iMessageMax/Tools/Send.swift` → no matches.

### Step 2: Make the gate instant — remove elicitation

In `send(...)`, replace the gate block with:

```swift
        if shouldConfirmSend(resolved: resolved, text: text, filePaths: filePaths), !confirm {
            return .pending(
                "This send requires confirmation. Call send again with confirm: true after reviewing the destination and content.",
                deliveredTo: ..., chat: ...   // keep the existing arguments unchanged
            )
        }
```

(The exact `.pending(...)` arguments already exist in the current
`.unavailable` arm — reuse them verbatim.)

Then delete: `confirmSendWithClientIfAvailable` entirely, the
`ConfirmationOutcome` enum if it exists and is now unused, the
`confirmationTimeout` stored property and init parameter, and the
`server: Server?` parameter from both `execute` and the private `send`
(update the `register` closure to `try await tool.execute(args: args)`).
Remove any now-unused `import` only if the compiler confirms it is unused.

**Verify**: `swift build` → exit 0;
`grep -n "requestElicitation\|confirmationTimeout\|confirmSendWithClient" swift/Sources/iMessageMax/Tools/Send.swift` → no matches.

### Step 3: Delete the unused timeout helper

In `AsyncTimeout.swift`, delete `withTimeout` (and anything used only by it,
e.g. the resume-gate class if `sleep` does not need it). KEEP `sleep` and
`dispatchInterval(for:)` — `SendVerifier` depends on them, and the
no-Task.sleep rule still applies.

**Verify**: `swift build` → exit 0;
`grep -rn "withTimeout" swift/Sources/ swift/Tests/` → matches only in
`ElicitationTimeoutTests.swift` (fixed next step);
`grep -rn "Task.sleep" swift/Sources/iMessageMax/Utilities/ swift/Sources/iMessageMax/Tools/` → no matches.

### Step 4: Update the tool description

In `register`:
- `confirm` schema description → "Required for risky sends (group chats,
  file attachments, texts over 500 characters). Without it, those sends
  return pending_confirmation immediately; review and call again with
  confirm: true."
- In the tool description body, add one line after the proof vocabulary:
  "Short 1:1 text sends do not require confirmation. Group sends, file sends,
  and long texts return pending_confirmation until confirm: true is passed."

**Verify**: `grep -n "elicitation" swift/Sources/iMessageMax/Tools/Send.swift`
→ no matches (case-insensitive: `grep -in`).

### Step 5: Tests

`ElicitationTimeoutTests.swift` — rename file and class to
`SendGateAndTimerTests` (or similar; executor's choice, keep it descriptive):
- DELETE the 4 `withTimeout` mechanics tests.
- KEEP `testDispatchSleepCompletes` unchanged.
- REWRITE `testHangingConfirmationYieldsPendingStatus` as
  `testGatedSendReturnsPendingImmediately`: GROUP chat target (fixture chat
  with 2+ handles joined), no confirm → assert status `pending_confirmation`
  AND elapsed < 2 seconds (this pins "instant", the core contract change),
  AND the stub runner was NOT invoked.

`SendToolExecuteTests.swift` — add:
1. `testOneToOneChatSendWithoutConfirmSends` — 1:1 DM fixture targeted by
   chat_id, NO confirm, stub runner with the staged-row side-effect (existing
   `onSend` hook) → status `confirmed`, stub invoked exactly once.
2. `testLongTextWithoutConfirmGatesInstantly` — 1:1 target, 501-char text, no
   confirm → `pending_confirmation`, stub NOT invoked, elapsed < 2s.
3. `testFileSendWithoutConfirmGates` — file path send, no confirm →
   `pending_confirmation`, stub NOT invoked.
4. `testConfirmTrueStillAcceptedOnOneToOne` — 1:1 chat_id send WITH
   confirm: true → `confirmed` (flag harmless on ungated sends).

**Verify**: `swift test` → exit 0; report final count vs baseline.

### Step 6: Docs

`AGENTS.md`: wherever the send confirmation flow is described, replace with
the new contract (gate = groups/files/long texts; instant
`pending_confirmation`; `confirm: true` as the explicit flag) and add one
sentence: "Interactive human-confirmation popups (MCP elicitation) are
intentionally not part of the send path: agent harnesses in use do not
reliably support server-initiated prompts, and a send tool must return
synchronously. Do not reintroduce without proof of a working round trip for
the current session."

**Verify**: `grep -in "elicitation" AGENTS.md` → only the intentional
"not supported" note (and the historical no-Task.sleep section if it mentions
it).

## Done criteria

- [ ] `swift build` exit 0; `swift test` all pass (report count; expect
      baseline − 4 deleted + 4 added ± renames)
- [ ] `grep -rn "requestElicitation" swift/Sources/iMessageMax/Tools/` → no matches
- [ ] `grep -rn "withTimeout" swift/Sources/ swift/Tests/` → no matches
- [ ] The three remaining gate rules unchanged (visible in `git diff`)
- [ ] Gated no-confirm sends return in < 2s in tests
- [ ] Only in-scope files changed

## STOP conditions

- `deliveredTo` for chat targets turns out NOT to contain all participants
  (group chats would lose their gate when rule 4 is deleted) — verify in
  `SendResolution.resolveChatId` FIRST; if false, STOP.
- `AsyncTimeout.sleep` turns out to share machinery with `withTimeout` that
  cannot be cleanly separated — report rather than restructure.
- Any test outside the two named test files fails.

## Maintenance notes

- Reviewer post-deploy gate (operator action): live no-confirm 1:1 chat_id
  send through the launchd service via plug must return `confirmed` with a
  stable PID and no entry in `~/Library/Logs/imessage-max.stderr.log`; a
  group-chat no-confirm send must return `pending_confirmation` in under a
  second.
- If MCP elicitation is ever revisited, it requires BOTH a strict/explicit
  client-capability check AND positive proof of a live server-to-client
  channel for the session — and even then as best-effort UX, never as the
  only path to a send. See "Elicitation channel findings" in
  `plans/README.md`.
