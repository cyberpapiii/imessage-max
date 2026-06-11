# Plan 011: Design spike — capability contract from `diagnose` (v2 R6–R9)

> **Executor instructions**: This is a DESIGN SPIKE — the deliverable is a
> design document; production code must NOT change. Follow the steps, honor
> STOP conditions. Your reviewer maintains `plans/README.md` — do not edit it.
> Report format: STATUS / STEPS / STOPPED BECAUSE (if stopped) /
> FILES CHANGED / NOTES.
>
> **Drift check (run first)**: `git diff --stat 90c65e1..HEAD -- swift/Sources/iMessageMax/Tools/Diagnose.swift`
> Empty output expected.

## Status

- **Priority**: P2
- **Effort**: M (timeboxed — finish all sections at good-enough depth)
- **Risk**: LOW (doc only)
- **Depends on**: none
- **Category**: direction
- **Planned at**: commit `90c65e1`, 2026-06-11

## Why this matters

The v2 requirements (`docs/brainstorms/2026-05-17-imessage-max-v2-trustworthy-core-requirements.md`,
"Capability contract", R6–R9 — read the whole file) commit to evolving
`diagnose` from a health check into an **agent-readable capability contract**:
per-capability states (supported / unsupported / degraded / permission-gated /
risky-private / experimental / unavailable / unverified) covering send modes,
attachment handling, reply/tapback/edit/unsend availability, freshness,
permissions, and any rich backend state. The strategy doc (`STRATEGY.md`,
"Trustworthy Core" track) makes this a pillar: agents must not attempt
unavailable or risky actions silently (key flow F2). Today nothing in the
codebase expresses capability states — `diagnose` reports configuration health
only. This spike produces the design that a build plan can execute.

## Current state (verify by reading, cite file:line in the doc)

- `swift/Sources/iMessageMax/Tools/Diagnose.swift` — current health check:
  read it end to end; inventory exactly what it reports today (database access,
  Contacts authorization, Automation/send readiness, version, etc.).
- Permission probes that exist and could feed capability states:
  `Database.checkAccess()` (`Database/Database.swift:21`),
  `ContactResolver.authorizationStatus()` (`Contacts/ContactResolver.swift:21`),
  whatever Automation/send checks `Diagnose.swift` performs.
- Related, already designed: `docs/plans/2026-06-11-send-verification-design.md`
  (proof states for sends — the capability contract must be consistent with it;
  e.g. a `verified_send` capability whose state depends on chat.db readability).
- Existing per-feature reality worth encoding: reply threading is rejected by
  `send` (`reply_to` rejection — see `SendToolExecuteTests`/`PlaceholderTests`),
  tapbacks/edit/unsend are read-side only, attachments can be iCloud-offloaded
  (`get_attachment` returns `attachment_offloaded`).
- MCP surface conventions: tools return token-efficient JSON
  (`AGENTS.md` "Token-Efficient Response Design").

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Tree untouched check | `cd swift && swift build` | exit 0, optional |
| Final cleanliness | `git status --porcelain` | only the new design doc |

## Scope

**In scope** (create only):
- `docs/plans/2026-06-11-capability-contract-design.md`

**Out of scope**: ALL Swift source and test files; `Diagnose.swift` itself;
the brainstorm and STRATEGY.md (inputs, not outputs); `plans/README.md`.

## Git workflow

- Branch: `advisor/011-capability-contract-spike`
- One commit: `docs: add capability contract design spike`. No push, no PR.

## Steps

### Step 1: Inventory what `diagnose` knows today

Read `Diagnose.swift` fully. Document in the design doc: every check it runs,
its output shape, and which checks map naturally to capability states vs.
which capabilities have NO probe today (gap list).

### Step 2: Define the capability taxonomy

Against R7's state vocabulary (supported / unsupported / degraded /
permission-gated / risky-private / experimental / unavailable / unverified),
define: the capability list R8 requires (send modes incl. text/file × DM/group,
verified sends, attachments incl. offloaded handling, reply threading,
tapbacks, edit/unsend, live/freshness, permissions), and for EACH capability:
its possible states, the probe that determines the state (existing function or
"needs new probe"), and the honest default per R9 (prefer limitation over
optimistic affordance — e.g. reply threading = `unsupported`, not `planned`).

### Step 3: Design the contract surface

Decide and justify: extend `diagnose`'s response vs. a new tool vs. MCP
resource. Default recommendation to evaluate: extend `diagnose` with a
`capabilities` object (token-efficient keys), keeping backward-compatible
health fields. Include the exact proposed JSON response (full example), and
how an agent should consume it (one paragraph suitable for the tool
description, satisfying flow F2: check before attempting).

### Step 4: Build outline + open questions

Incremental slices with coarse effort, open maintainer questions (at minimum:
caching/staleness of probe results, whether capability states should appear in
`initialize` metadata too, and how `experimental` interacts with future rich
backends per the brainstorm's A4 actor), and what the spike did not investigate.

## Done criteria

- [ ] `docs/plans/2026-06-11-capability-contract-design.md` exists with all
      four sections; every cited `file:line` verified against real code
- [ ] `git status --porcelain` on your branch shows only the design doc
- [ ] The doc's capability table covers every item R8 names

## STOP conditions

- `Diagnose.swift` already contains a capability-state implementation (drift).
- The design would require writing to chat.db or private frameworks (violates
  R14 / the local trust model).

## Maintenance notes

- This doc + the send-verification design together specify the Trustworthy
  Core's agent-facing surface; the build plans should land send verification
  first (proof states feed the `verified_send` capability state).
