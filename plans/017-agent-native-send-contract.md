# Plan 017: Agent-native send contract (remove the confirmation gate and elicitation)

> **Executor instructions**: BASE CHECK FIRST — run
> `ls plans/017-agent-native-send-contract.md` and confirm this file's title
> says "remove the confirmation gate" (v2 — if your copy says "narrow the
> gate", your snapshot predates the revision; checkout `<PLANS_COMMIT>` from
> the dispatch message). Branch `advisor/017-agent-native-send`. Follow
> exactly; verify every step; in-scope files only; do not edit
> `plans/README.md`. Report: STATUS / STEPS / STOPPED BECAUSE / FILES CHANGED
> / NOTES.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED (send-policy change, but strictly REMOVES code paths; every
  remaining path is already tested)
- **Depends on**: 015 merged (your base contains it)
- **Supersedes**: plan 016 (parked, never dispatched)
- **Category**: bug / product / reliability
- **Planned at**: 2026-06-11 (v2 — gate removed entirely, not narrowed;
  operator decision after the Codex/Claude joint diagnosis)

## Why this matters

Live debugging on 2026-06-11 ("Elicitation channel findings" in
`plans/README.md`) established that the interactive MCP elicitation
confirmation never completed a round trip in the operator's client stack —
it hung (pre-014), crashed the launchd service (014), and post-015 burns a
silent 25 seconds before degrading. The operator's decision goes further than
removing the popup: the confirmation *gate itself* comes out.

The reasoning, recorded so it is not re-litigated:

- **A boolean the calling agent sets is not a safety mechanism.** Observed
  live: a gated client was told "retry with confirm: true" and did so
  immediately, unprompted. Every agent learns to pass the flag within one
  session; the gate then filters nothing and only costs an extra round trip.
- **The human checkpoint already exists at the harness layer.** MCP clients
  show the user each tool call and its arguments before execution. Server-side
  confirmation duplicated that, badly.
- **The correct distinction is ambiguous vs risky, and ambiguity is already
  handled.** "Not sure where this goes" → `ambiguous` (refuses, lists
  candidates). Missing file → `failed`. Those stay. "Exact but it's a
  group/file/long text" is not the server's decision to second-guess — the
  user authorized it in conversation; `delivered_to` plus post-send
  verification report truthfully what happened.

The send contract after this plan:

1. Exact destination → send immediately, verify via chat.db →
   `confirmed` / `uncertain` / `mismatch` / `sent`.
2. Ambiguous destination → `ambiguous`, no send. Invalid input → `failed`,
   no send.
3. File transfers keep the bounded Messages.app observation states
   (`pending` when a transfer hasn't completed) — that is state observation,
   not human confirmation.
4. `confirm` stays in the input schema as an accepted, **inert** parameter
   (existing callers and harness-cached tool schemas must not break), marked
   deprecated in its description.
5. No send path waits on anything interactive; no send path can hang or
   crash the service. The tool returns synchronously, always.

## Current state

All in `swift/Sources/iMessageMax/Tools/Send.swift` unless noted:

- Gate block (lines 343-356): `if shouldConfirmSend(...), !confirm { switch
  await confirmSendWithClientIfAvailable(...) ... }` with `.confirmed` /
  `.declined` (→ `.cancelled`) / `.unavailable` (→ `.pending`) arms.
- `shouldConfirmSend` (~line 458): four rules (multi-recipient, files,
  >500-char text, any chat target).
- `confirmSendWithClientIfAvailable` (~line 470): builds prompt, calls
  `server.requestElicitation` inside `AsyncTimeout.withTimeout`.
- `confirmationTimeout: Duration = .seconds(25)` property + init param
  (~lines 209, 217, 223).
- `execute(args:server:)` (~line 275) and private `send(...server:)` thread
  `server: Server?` whose only use is elicitation; `register` closure
  (~line 269) passes it.
- `confirm` parsed at line 281, threaded to `send` (line 308).
- `SendResponse.cancelled` (~line 149): only caller is the gate's
  `.declined` arm — orphaned after this plan.
- `SendResponse.pending` (~line 132): TWO callers — the gate's
  `.unavailable` arm (deleted) and the attachment transfer-pending path
  (line 396, KEEP — out of scope).
- Input schema `confirm` description (line 257): stale elicitation wording.
- `swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift`: `sleep` (used by
  `SendVerifier` — KEEP) and `withTimeout` (only caller is elicitation —
  DELETE).
- `swift/Tests/iMessageMaxTests/ElicitationTimeoutTests.swift`: 6 tests —
  4 pin `withTimeout` mechanics (delete), 1 pins `AsyncTimeout.sleep` (keep),
  1 (`testHangingConfirmationYieldsPendingStatus`) pins the gate (obsolete —
  replace per Step 4).
- `swift/Tests/iMessageMaxTests/SendToolExecuteTests.swift`: chat-route tests
  pass `confirm: true` — they must STILL PASS unchanged (the flag is inert,
  not rejected).
- `AGENTS.md`: check for confirmation-flow description; the "No Task.sleep in
  the service runtime" section stays.

Record the full-suite baseline count before starting (`swift test`; expected
148) and report before/after counts.

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

**Out of scope**: `SendVerifier` and its bounded post-send polling, the
attachment transfer-pending path (`.pending` at ~line 396 and the
`.transferPending`/`.transferStatusUnknown` handling), `SendResolution`
(ambiguity handling already correct), `HTTPTransport`, `SessionManager`,
`SSEConnection`, `Diagnose`, everything else.

## Git workflow

Branch `advisor/017-agent-native-send`; lowercase conventional commits; no
push, no PR.

## Steps

### Step 1: Delete the gate and elicitation machinery

In `Send.swift` delete:
- The entire gate block (lines 343-356).
- `shouldConfirmSend`.
- `confirmSendWithClientIfAvailable` and its `ConfirmationOutcome`-style
  result enum if now unused.
- The `confirmationTimeout` stored property and init parameter.
- `SendResponse.cancelled` IF it has no remaining callers (verify with grep
  before deleting; also remove "cancelled" from the tool-description status
  list in that case).
- The `server: Server?` parameter from `execute` and the private `send`;
  update the `register` closure to `try await tool.execute(args: args)`.

KEEP: `confirm` parsing at the `execute` layer is deleted too — the
parameter stays in the SCHEMA (Step 3) but is no longer read. Add a one-line
comment where it was parsed... no: simplest is delete the parsing entirely;
the schema entry plus its description is the only remaining trace.

Add a short comment above the send dispatch (where the gate used to be):
sends are authorized by the user's request to the agent and by harness-level
tool approval; the server does not gate exact sends — ambiguity and
validation failures refuse above, and post-send verification reports the
truth below. Interactive confirmation (MCP elicitation) was removed
2026-06-11 after it proved unable to round-trip through real agent stacks —
see plans/README.md "Elicitation channel findings"; do not reintroduce
without session-level proof of a working channel.

**Verify**: `swift build` → exit 0;
`grep -n "requestElicitation\|confirmationTimeout\|confirmSendWithClient\|shouldConfirmSend" swift/Sources/iMessageMax/Tools/Send.swift` → no matches.

### Step 2: Delete the unused timeout helper

In `AsyncTimeout.swift`, delete `withTimeout` (and machinery used only by it,
e.g. the resume-gate class if `sleep` does not need it). KEEP `sleep` and
`dispatchInterval(for:)` — `SendVerifier` depends on them; the no-Task.sleep
rule still applies.

**Verify**: `swift build` → exit 0;
`grep -rn "withTimeout" swift/Sources/ swift/Tests/` → matches only in
`ElicitationTimeoutTests.swift` (fixed in Step 4);
`grep -rn "Task.sleep" swift/Sources/iMessageMax/Utilities/ swift/Sources/iMessageMax/Tools/` → no matches.

### Step 3: Update the tool schema and description

In `register`:
- `confirm` schema description → "Deprecated; accepted for compatibility and
  ignored. Sends do not require confirmation — destination ambiguity is
  refused with status 'ambiguous', and results are verified post-send."
- Tool description body: remove "File sends and failed/cancelled/ambiguous
  states are unchanged" line if `cancelled` was deleted (reword to cover
  remaining states); add one line: "Sends execute immediately when the
  destination is exact. Ambiguous destinations return status 'ambiguous'
  without sending. File transfers may return 'pending' while Messages.app
  completes the transfer."

**Verify**: `grep -in "elicitation" swift/Sources/iMessageMax/Tools/Send.swift`
→ no matches.

### Step 4: Tests

`ElicitationTimeoutTests.swift` — rename file and class to something like
`SendContractTests` (executor's choice, descriptive):
- DELETE the 4 `withTimeout` mechanics tests.
- KEEP `testDispatchSleepCompletes` unchanged.
- REPLACE `testHangingConfirmationYieldsPendingStatus` with
  `testGroupChatSendWithoutConfirmSendsImmediately`: group chat fixture (2+
  handles) targeted by chat_id, NO confirm, stub runner with staged-row
  side-effect → status `confirmed`, stub invoked, elapsed < 2s.

`SendToolExecuteTests.swift` — add:
1. `testOneToOneChatSendWithoutConfirmSends` — 1:1 DM fixture by chat_id, NO
   confirm, stub runner with staged-row side-effect (existing `onSend` hook)
   → `confirmed`, stub invoked exactly once.
2. `testLongTextSendsWithoutConfirm` — 1:1 target, 501-char text, no confirm
   → `confirmed`, stub invoked (long text no longer gates).
3. `testConfirmFlagIsInert` — same send with `confirm: true` AND with
   `confirm: false` explicitly → identical `confirmed` outcome both ways.
4. Existing `confirm: true` tests must pass UNCHANGED.

(Ambiguity refusal already has coverage from plan 002's characterization
tests — do not duplicate; verify they still pass.)

**Verify**: `swift test` → exit 0; report final count vs baseline.

### Step 5: Docs

`AGENTS.md`: wherever the send confirmation flow is described, replace with
the new contract (exact → send + verify; ambiguous → refuse; `confirm`
deprecated/inert; file-transfer pending states unchanged) and add:
"Interactive human-confirmation popups (MCP elicitation) and server-side send
gating are intentionally not part of the send path: authorization happens in
the user's conversation with the agent and in harness-level tool approval,
and a send tool must return synchronously. Do not reintroduce either without
operator sign-off and proof of a working elicitation round trip for the
current session."

**Verify**: `grep -in "elicitation" AGENTS.md` → only the intentional note
(plus the historical no-Task.sleep section if it mentions it).

## Done criteria

- [ ] `swift build` exit 0; `swift test` all pass (report count vs 148
      baseline)
- [ ] `grep -rn "requestElicitation\|shouldConfirmSend" swift/Sources/` → no matches
- [ ] `grep -rn "withTimeout" swift/Sources/ swift/Tests/` → no matches
- [ ] Attachment transfer-pending path untouched (visible in `git diff`:
      the `.pending` call at ~line 396 and `.transferPending` handling
      unchanged)
- [ ] `confirm` still present in the input schema (inert, deprecated wording)
- [ ] Only in-scope files changed

## STOP conditions

- `SendResponse.cancelled` or `SendResponse.pending` turns out to have
  callers outside the gate and the attachment path — report before deleting
  anything.
- `AsyncTimeout.sleep` shares machinery with `withTimeout` that cannot be
  cleanly separated — report rather than restructure.
- Any test outside the two named test files fails (except tests that
  EXPLICITLY pinned gate behavior — list them in the report if found).

## Maintenance notes

- Reviewer post-deploy gate (operator action): through plug against the live
  launchd service — (a) no-confirm 1:1 chat_id send → `confirmed`, stable
  PID; (b) no-confirm GROUP chat send → `confirmed`, stable PID, message
  lands in the right thread; (c) `confirm: true` send → identical behavior.
- If send gating is ever revisited, the bar is: it must add safety an
  agent-set boolean cannot defeat, and it must not block on any interactive
  channel. See "Elicitation channel findings" in `plans/README.md`.
