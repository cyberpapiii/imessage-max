# Plan 009: Design spike — verified sends (proof states) for the v2 trustworthy core

> **Executor instructions**: This is a DESIGN SPIKE, not a build plan. The
> deliverable is a design document plus measured evidence — production code
> must NOT change. Follow the steps, run the verifications, and honor the
> STOP conditions. When done, update the status row for this plan in
> `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 57a2ff3..HEAD -- swift/Sources/iMessageMax/Tools/Send.swift swift/Sources/iMessageMax/Tools/SendResolution.swift swift/Sources/iMessageMax/Utilities/AppleScript.swift`
> If these files changed since this plan was written, read the diffs first —
> the "Current state" inventory below must be re-validated, not assumed.
>
> **Environment requirement**: Step 3 requires a real macOS machine with
> Messages.app signed in, Full Disk Access, Automation permission, and the
> operator's consent to send 3-5 test messages to a chat the operator
> designates (e.g. a note-to-self chat). If any of that is unavailable, do
> Steps 1, 2, 4, 5 and mark the latency table "NOT MEASURED — blocked on
> environment" rather than guessing numbers.

## Status

- **Priority**: P2
- **Effort**: M (coarse — spikes are bounded by timebox, not scope: stop after ~a day and write up what you have)
- **Risk**: LOW (no production code changes allowed)
- **Depends on**: none (plan 002's `ScriptRunning` seam is useful context but not required)
- **Category**: direction
- **Planned at**: commit `57a2ff3`, 2026-06-11

## Why this matters

The product strategy (`STRATEGY.md`, "Trustworthy Core" track) defines **verified send rate** as a key metric, and the v2 requirements document commits to it: sends must produce *proof states*, verified "by re-reading the intended target conversation when possible." Today the `send` tool returns `status: "sent"` purely on AppleScript transport success — it never confirms the message actually landed in the intended chat. The statuses scaffolding already exists (`sent`/`pending_confirmation`/`cancelled`/`failed`/`ambiguous`), so the gap is specifically: post-send verification by re-reading chat.db, and the honest states for when verification can't prove success. This spike de-risks that build by answering the empirical and design questions first.

## Current state

Requirements being designed for (from `docs/brainstorms/2026-05-17-imessage-max-v2-trustworthy-core-requirements.md`, "Trustworthy sends" — read the whole file before starting):

- R1. Send results must be expressed as proof states, not just transport success.
- R2. The first v2 release must verify sends by re-reading the intended target conversation when possible.
- R3. If verification cannot prove the send landed in the intended conversation, the result must be honestly reported as pending, uncertain, mismatch, failed, or cancelled rather than presented as confirmed.
- R4. Risky sends must remain gated by review or explicit confirmation (group sends, file sends, ambiguous targets).
- R5. The product must never silently convert an ambiguous group target into a direct-message target.

What exists in code today:

- `swift/Sources/iMessageMax/Tools/Send.swift` — `actor SendTool`; `SendResponse` (lines 20-105) with static constructors `success` (→ `"sent"`, line 41), `pending` (→ `"pending_confirmation"`), `cancelled`, `error` (→ `"failed"`), `ambiguous`. `success` is produced on AppleScript success with no DB re-read.
- `swift/Sources/iMessageMax/Tools/SendResolution.swift` — `SendResolver`: resolves recipient/chat targets; has chat-guid-exact targeting.
- `swift/Sources/iMessageMax/Utilities/AppleScript.swift` — `enum AppleScriptRunner` (line 50); JXA send functions; file sends already have a transfer-observation state machine (see `testTransferObservation*` in `swift/Tests/iMessageMaxTests/PlaceholderTests.swift:196-240` — finished/failed/pending/unknown).
- `swift/Sources/iMessageMax/Database/Database.swift` — read-only chat.db access; message rows have `guid`, `date` (Apple-epoch nanoseconds), `is_from_me`, `text`, `attributedBody`; `chat_message_join` links messages to chats.
- Existing related design history: `docs/plans/2026-03-13-chat-identity-and-send-refactor-plan.md` (read it — the proof-state design should not contradict decisions recorded there).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build (read-only exploration aid) | `cd swift && swift build` | exit 0 |
| Tests (must be untouched at the end) | `cd swift && swift test` | all pass, count unchanged |
| Inspect own chat.db (read-only) | `sqlite3 "file:$HOME/Library/Messages/chat.db?mode=ro" "SELECT ROWID, guid, date, is_from_me, text FROM message ORDER BY date DESC LIMIT 5;"` | recent rows (requires Full Disk Access for the terminal) |

## Scope

**In scope** (files you may create — nothing else):
- `docs/plans/2026-06-11-send-verification-design.md` (the deliverable; matches the repo's existing docs/plans naming convention)
- A throwaway measurement script under `/tmp/` (not committed)
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- ALL production Swift code and ALL test files. If the spike tempts you to "just prototype it in Send.swift" — no. Pseudocode goes in the design doc.
- `STRATEGY.md`, the brainstorm doc — inputs, not outputs.

## Git workflow

- Branch: `advisor/009-send-verification-spike`
- One commit with the design doc; style: `docs: add send verification design spike`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Inventory the send flow precisely

Read `Send.swift`, `SendResolution.swift`, and `AppleScript.swift` end to end. In the design doc's "Current flow" section, document: (a) the exact sequence from tool args to `osascript` invocation for text→participant, text→chat, file→participant, file→chat; (b) what AppleScript success actually proves for each (hypothesis: "Messages.app accepted the command", not "message delivered" — confirm against the JXA script bodies); (c) where the existing transfer-observation state machine for files begins and ends; (d) what `ChatReference`/`deliveredTo` are populated from.

**Verify**: the design doc's "Current flow" section exists and cites `file:line` for each of the four paths.

### Step 2: Design the verification query

Design (in the doc, with SQL) the re-read that answers: "did a message I just sent appear in the intended chat?" Inputs available at send time: target chat ROWID/guid (chat sends) or participant handle (DM sends), send wall-clock time, message text (or file transfer name). Address explicitly:

- Matching strategy: `is_from_me = 1`, `cmj.chat_id = ?`, `m.date >= <send_time - skew_margin>`, plus text equality — and the failure modes of text matching: Unicode normalization differences, Apple's storage of text in `attributedBody` vs `text` (cite `MessageTextExtractor`), emoji/whitespace mangling, two rapid identical sends.
- For DM sends resolved by handle: how to find which chat row the message landed in, and how to detect the *mismatch* case (landed in a different chat than intended — the R5 hazard).
- A `message.guid`-based alternative: investigate whether the JXA `send` command can return the sent message's id/guid (check Messages' scripting dictionary from the JXA side). If yes, matching by guid beats heuristics — record what you find even if negative.
- Polling design: how many re-read attempts, at what intervals, before degrading from `pending` to `uncertain`.

**Verify**: design doc contains the candidate SQL, the matching-ambiguity table, and a written answer (positive or negative, with evidence) on the JXA-returns-id question.

### Step 3: Measure chat.db write latency (environment-gated)

With operator consent and a designated test chat: send 3-5 messages via the existing tool or `osascript` directly, and poll the read-only sqlite3 query from the commands table, timestamping when each sent message becomes visible in chat.db. Use a throwaway script in `/tmp/`. Record: median and max visibility latency, and whether `date` on the row matches the send time or the visibility time. This number calibrates the polling design from Step 2.

**Verify**: a latency table with raw observations is in the design doc (or the explicit "NOT MEASURED — blocked on environment" marker plus what's needed to run it later).

### Step 4: Define the proof-state machine

In the doc, define the full state set against R1-R3. Required shape (adjust with reasoning if the evidence demands):

- `confirmed` — re-read found the message in the intended chat. (Today's `"sent"` overclaims; the doc must take a position on renaming vs. redefining `sent`, including MCP-client compatibility fallout — existing agents may dispatch on `"sent"`.)
- `pending` — transport accepted, verification still polling (file transfers reuse the existing transfer-observation states).
- `uncertain` — polling exhausted without proof; honest "probably sent, can't prove it".
- `mismatch` — found in a *different* chat than intended (R5 violation surfaced loudly).
- `failed`, `cancelled`, `ambiguous` — as today.

For each state: trigger condition, response fields (what evidence the agent gets, e.g. matched message guid + ts for `confirmed`), and the recommended agent behavior (one sentence each, suitable for the tool description).

**Verify**: every state has all three columns filled; the `sent`→`confirmed` compatibility question has a recommendation with trade-offs.

### Step 5: Write the build outline and open questions

Close the doc with: (a) an incremental build plan (suggested slices: 1. re-read query as a pure function + tests against the fixture DB; 2. verification loop behind the `ScriptRunning` seam from plan 002; 3. response/status migration with compatibility shims; 4. tool-description updates); (b) effort estimates per slice; (c) open questions that need the maintainer's decision (at minimum: the `sent` rename question, polling budget vs. tool-call latency, and whether `uncertain` should auto-suggest a follow-up `get_messages` call); (d) what this spike did NOT investigate.

**Verify**: design doc complete; `cd swift && swift test` → pass with the same test count as before the spike (proves no production/test code touched); `git status` shows only the new design doc.

## Test plan

Not applicable — no production code. The spike's "tests" are: the latency measurements (Step 3) and the verification that the working tree is clean of code changes.

## Done criteria

- [ ] `docs/plans/2026-06-11-send-verification-design.md` exists with all five sections (current flow, verification query, latency data or blocked-marker, proof-state machine, build outline + open questions)
- [ ] `git status` shows ONLY the design doc (and `plans/README.md`) as new/modified
- [ ] `cd swift && swift test` passes with unchanged test count
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The operator has not designated a test chat for Step 3 — do the other steps, mark Step 3 blocked; never send test messages to an undesignated recipient.
- You discover an existing partial implementation of post-send verification (the inventory in this plan says there is none at `57a2ff3`; if drift introduced one, the spike must build on it, not parallel it).
- The design requires writing to chat.db or private frameworks — both violate the product's stated trust model (`docs/brainstorms/...trustworthy-core...md` R14); the design must stay read-only + AppleScript.

## Maintenance notes

- The resulting design doc is input to a future build plan (or plans) — it should land in `docs/plans/` per repo convention, and the maintainer decides which slices to schedule.
- If plan 002 landed, its `ScriptRunning` protocol is where the verification loop's send-side hooks belong; note any shape changes the design needs from that seam.
