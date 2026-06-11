# Plan 012: Build verified sends (proof states) per the approved design

> **Executor instructions**: BASE CHECK FIRST — this plan and its spec must be
> in your worktree. Run `ls plans/012-verified-sends-build.md docs/plans/2026-06-11-send-verification-design.md`.
> If missing, your worktree snapshot is stale: run
> `git checkout -b advisor/012-verified-sends <PLANS_COMMIT>` (the coordinator
> supplies the SHA in the dispatch message) and re-check. Then follow this plan
> step by step; run every verification command; touch only in-scope files; on
> any STOP condition stop and report. Do not edit `plans/README.md`. Report
> format: STATUS / STEPS / STOPPED BECAUSE / FILES CHANGED / NOTES.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED (touches the only write path; mitigated by the seam + staged steps)
- **Depends on**: none (ScriptRunning seam and ChatSummaryQueries already merged)
- **Category**: direction (v2 trustworthy core, R1–R3)
- **Planned at**: the commit named in the dispatch message, 2026-06-11

## Why this matters

`send` currently returns `status: "sent"` on AppleScript transport success — an
overclaim (measured 2026-06-11: failed sends write chat.db rows with
`error = 22` while osascript exits 0). The approved design,
`docs/plans/2026-06-11-send-verification-design.md`, specifies post-send
verification by re-reading chat.db and an honest proof-state vocabulary. **That
design document is this plan's spec — read it in full before starting**,
especially §2 (verification query), §3 (measured findings), §4 (state machine,
Option D), §5.1 (slices). This plan implements its slices 1–4 with the
following maintainer decisions already made:

- **Option D** (§4.3): `"sent"` keeps meaning transport-accepted and is
  returned ONLY when verification cannot run (chat.db unreadable). When
  verification runs: `"confirmed"` / `"uncertain"` / `"mismatch"`.
- **Polling**: 5 attempts × 200ms (calibrated: row visibility measured ~26ms).
  Attempts/interval are injectable for tests.
- **Confirmation requires `m.error = 0`** (§3 finding 3) and text matching via
  `MessageTextExtractor` (§3 finding 2 — never raw `m.text` equality).
- **Scope**: text payloads only. File sends keep today's transfer-observation
  statuses untouched.

## Current state (verify before changing)

- `swift/Sources/iMessageMax/Utilities/AppleScript.swift` — `protocol
  ScriptRunning` + `LiveScriptRunner` ALREADY EXIST (the design's slice-2
  "introduce the seam" step is already done; skip that part).
- `swift/Sources/iMessageMax/Tools/Send.swift` — `actor SendTool` with
  `init(db:resolver:runner:)`; payload loop calls `runner.sendTextTo…` /
  `sendFileTo…`; `SendResponse` (Encodable, snake_case CodingKeys) with
  constructors `success`("sent")/`pending`/`cancelled`/`error`/`ambiguous`.
- `swift/Sources/iMessageMax/Tools/SendResolution.swift` — resolved targets
  carry `chatId` for chat sends and `handle` (+ optional `chatId`) for
  participant sends. Read the actual target enum before coding.
- `swift/Tests/iMessageMaxTests/SendToolExecuteTests.swift` — `StubScriptRunner`
  + 4 tests. Two of them pin `status == "sent"` on stub success; this plan
  CHANGES that contract deliberately (see Step 4) — editing those expectations
  is sanctioned HERE ONLY, per the approved design.
- `swift/Tests/iMessageMaxTests/ToolTestSupport.swift` — `ToolTestDatabase`
  message schema has NO `error` / `is_sent` columns; Step 1 adds them
  (additive, with defaults, so existing tests stay green).

## Commands

| Purpose | Command | Expected |
|---------|---------|----------|
| Build | `cd swift && swift build` | exit 0 |
| All tests | `cd swift && swift test` | exit 0 (baseline 126) |
| New unit tests | `cd swift && swift test --filter SendVerifierTests` | all pass |

## Scope

**In scope**:
- `swift/Sources/iMessageMax/Tools/SendVerifier.swift` (create)
- `swift/Sources/iMessageMax/Tools/Send.swift` (verification loop, new
  statuses/fields/constructors, tool description update per design §4)
- `swift/Tests/iMessageMaxTests/SendVerifierTests.swift` (create)
- `swift/Tests/iMessageMaxTests/SendToolExecuteTests.swift` (update
  expectations + add cases)
- `swift/Tests/iMessageMaxTests/ToolTestSupport.swift` (additive schema
  columns only: `error INTEGER DEFAULT 0`, `is_sent INTEGER DEFAULT 0`, and
  optional `error:`/`isSent:` params on `insertMessage` defaulting to 0)
- `swift/Tests/iMessageMaxTests/SendManualValidation.md` (add
  confirmed/uncertain/mismatch manual scenarios)

**Out of scope** (do NOT touch): `Diagnose.swift` (plan 013 owns it — do NOT
add `send_verification` to diagnose output even though design §5.1 slice 4
mentions it; 013 covers capability reporting), `AppleScript.swift` script
bodies, `ChatSummaryQueries.swift`, `SendResolution.swift` (read-only),
`HTTPTransport`, all list-tool files, `ListToolCharacterizationTests.swift`,
`UnreadCharacterizationTests.swift`.

## Git workflow

Branch `advisor/012-verified-sends`; commit per step, lowercase conventional
prefixes; no push, no PR.

## Steps

### Step 1: Fixture columns

Add `error` and `is_sent` columns (INTEGER DEFAULT 0) to `ToolTestDatabase`'s
message schema and optional `insertMessage(error: Int = 0, isSent: Int = 0)`
params. **Verify**: `swift test` → 126 pass (purely additive).

### Step 2: `SendVerifier` (design §5.1 slice 1 — pure, no SendTool changes)

`swift/Sources/iMessageMax/Tools/SendVerifier.swift`: a struct/final class
taking `db: Database`, with injectable `maxAttempts: Int = 5`,
`pollInterval: Duration = .milliseconds(200)`. Method per design:

```swift
enum VerificationResult: Equatable {
    case confirmed(guid: String, dateNs: Int64)
    case mismatch(actualChatId: Int64, guid: String)
    case notFound
}
func verify(intendedChatId: Int64?, handle: String?, sendTime: Date,
            expectedText: String) async throws -> VerificationResult
```

Implement the design's §2.2 queries with the §3 corrections: window
`m.date >= AppleTime.fromDate(sendTime) - 2s skew`, `m.is_from_me = 1`,
**`m.error = 0`**, `associated_message_type = 0`; candidate text compared via
`MessageTextExtractor.extract(text:attributedBody:)` (trim whitespace; exact
match first, then `.caseInsensitive + .diacriticInsensitive` fallback per
§2.3). Primary query scopes to `intendedChatId` when present; the §2.2
fallback handle-scan runs when the primary finds nothing AND `handle` is
non-nil — a hit in a different chat returns `.mismatch`. Poll between
attempts with `Task.sleep`. Multiple matches → earliest date wins (§2.3).

Tests (`SendVerifierTests.swift`, ToolTestDatabase): confirmed on matching
row; **not confirmed when row has `error: 22`** (the measured failure mode);
notFound when no row within window; mismatch when row is in another chat
containing the handle; attributedBody-only row still matches (insert with
`text: nil` — if the fixture can't produce a parseable attributedBody blob,
test via the text column and note the gap); rows older than the window
ignored. Use `maxAttempts: 1` for fast tests; one test exercises multi-attempt
polling with `maxAttempts: 3, pollInterval: .milliseconds(50)`.

**Verify**: `swift test --filter SendVerifierTests` → ≥6 pass; full suite green.

### Step 3: Wire into `SendTool` (slices 2+3)

In the text-payload success path: capture `let sendTime = Date()` immediately
before the runner call (design §5.2 option 1). After `.success`, run the
verifier (inject a `SendVerifier` via init with a default; tests pass a
fast-poll instance). Map results to NEW constructors:

- `.confirmed` → `status: "confirmed"` + `verified_message_guid`,
  `verified_at` (ISO) fields
- `.notFound` → `status: "uncertain"` + message guiding a follow-up
  `get_messages` call (use design §4.2's wording)
- `.mismatch` → `status: "mismatch"` + `intended_chat` + `actual_chat_id`,
  never reported as success
- Verifier threw because DB unreadable → `status: "sent"` (Option D
  transport-only fallback; do NOT fail the send)

File payloads: unchanged statuses. Update the `send` tool description to
document the proof vocabulary (succinct — follow the repo's token-efficient
description style; design §4.2 agent-behavior lines are the source).

**Verify**: `swift build` exit 0. Existing `SendToolExecuteTests` WILL now
fail on the two `"sent"` assertions — expected; fix in Step 4.

### Step 4: Update + extend execute tests (sanctioned contract change)

Update `SendToolExecuteTests`: stub-success sends against the fixture (no row
appears) now expect `"uncertain"` (use a fast-poll verifier). Add:
`testStubSendWithMatchingRowConfirms` (pre-insert the expected outbound row
with `error: 0` after... NOTE: the row must satisfy the time window — insert
it with a date a few seconds in the future of test start, or inject the row
between send and verify via a stub runner side-effect closure; choose the
simpler and document it), asserting `"confirmed"` + guid field present;
`testFailedRowDoesNotConfirm` (stub success + pre-staged row with `error: 22`
→ `"uncertain"`); keep the routing/never-invoked invariants untouched.

**Verify**: `swift test --filter SendToolExecuteTests` → all pass; full suite
green (count > 126; report the number). Update `SendManualValidation.md` with
the three new manual scenarios.

## Done criteria

- [ ] `swift build` exit 0; `swift test` all pass (report final count)
- [ ] `grep -n '"confirmed"\|"uncertain"\|"mismatch"' swift/Sources/iMessageMax/Tools/Send.swift` → all three present
- [ ] `grep -n "error = 0\|error == 0\|m.error" swift/Sources/iMessageMax/Tools/SendVerifier.swift` → the error guard exists
- [ ] `Diagnose.swift` untouched (`git diff --stat <base>..HEAD` excludes it)
- [ ] Only in-scope files changed

## STOP conditions

- The resolved-target type in `SendResolution.swift` doesn't expose what
  `verify` needs (no chatId AND no handle for some target kind) — report the
  shape instead of guessing.
- Any test outside `SendToolExecuteTests` fails after Step 3 (means the change
  leaked beyond the sanctioned contract).
- You find yourself wanting to modify `Diagnose.swift` or the AppleScript
  bodies.

## Maintenance notes

- Plan 013 wires `verified_send` capability state independently; when both
  land, diagnose reports the capability and send delivers it.
- The eventual hard-rename of `"sent"` (§5.3) stays deferred — record nothing.
