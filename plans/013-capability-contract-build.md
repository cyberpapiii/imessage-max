# Plan 013: Build the capability contract in `diagnose` per the approved design

> **Executor instructions**: BASE CHECK FIRST — run
> `ls plans/013-capability-contract-build.md docs/plans/2026-06-11-capability-contract-design.md`.
> If missing, your worktree snapshot is stale: run
> `git checkout -b advisor/013-capability-contract <PLANS_COMMIT>` (SHA in the
> dispatch message) and re-check. Then follow this plan step by step; run every
> verification command; touch only in-scope files; on any STOP condition stop
> and report. Do not edit `plans/README.md`. Report format: STATUS / STEPS /
> STOPPED BECAUSE / FILES CHANGED / NOTES.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW-MED (diagnose output shape changes; existing tests may pin it)
- **Depends on**: none (runs parallel to plan 012; does NOT wait for it)
- **Category**: direction (v2 trustworthy core, R6–R9)
- **Planned at**: the commit named in the dispatch message, 2026-06-11

## Why this matters

`diagnose` hardcodes all four send-mode capabilities as `true` regardless of
Automation permission (`Diagnose.swift`, the `capabilities: .init(...)` block)
— the exact optimistic affordance the v2 requirements forbid (R9). The
approved design, `docs/plans/2026-06-11-capability-contract-design.md`, is
this plan's spec — **read it in full first**: §2.2 (the 15-capability table),
§2.3 (Automation probe), §2.4 (derivation rules), §3.2 (exact JSON), §3.4
(tool description text), §4.1 (slices). This plan implements its slices 1, 2,
and 4, plus the probe-derived parts of slice 3.

Decisions already made: implement `verified_send` purely from probes per the
§2.2 table (`supported` when DB accessible, `degraded` when DB readable but
automation unverified, `permission-gated` when DB inaccessible) — do NOT wait
for or reference plan 012's send changes.

## Current state (verify before changing)

- `swift/Sources/iMessageMax/Tools/Diagnose.swift` — `DiagnoseResult` with the
  boolean `Capabilities` struct (~lines 21–39), `execute()` (~93–163) ending in
  the hardcoded `capabilities: .init(sendTextToParticipant: true, ...)` block,
  tool description at ~line 70.
- Existing probes: `Database.checkAccess()` (`Database/Database.swift:21`),
  `ContactResolver.authorizationStatus()` (`Contacts/ContactResolver.swift:21`).
- No Automation probe exists anywhere.
- Tests that may pin diagnose output: `ResponseContractTests.swift`,
  `OverviewResponseTests.swift`, `ToolRegistryTests` (in
  `PlaceholderTests.swift` — asserts on tool descriptions). Check all three
  BEFORE changing shapes; updating their pinned shapes/descriptions to the new
  design is sanctioned, but only those assertions.

## Commands

| Purpose | Command | Expected |
|---------|---------|----------|
| Build | `cd swift && swift build` | exit 0 |
| All tests | `cd swift && swift test` | exit 0 (baseline 126) |
| New tests | `cd swift && swift test --filter CapabilityContractTests` | all pass |

## Scope

**In scope**:
- `swift/Sources/iMessageMax/Utilities/AutomationPermission.swift` (create)
- `swift/Sources/iMessageMax/Tools/Diagnose.swift`
- `swift/Tests/iMessageMaxTests/CapabilityContractTests.swift` (create)
- `ResponseContractTests.swift` / `OverviewResponseTests.swift` /
  `PlaceholderTests.swift` — ONLY assertions that pin the old capabilities
  shape or the old diagnose description

**Out of scope** (do NOT touch): `Send.swift`, `SendVerifier.swift` (plan 012
owns the send path — your worktree may or may not contain it; either way leave
it alone), `SendResolution.swift`, `AppleScript.swift`, `Database.swift`,
`ContactResolver.swift` (call the probes, don't change them), all list tools.

## Git workflow

Branch `advisor/013-capability-contract`; commit per step, lowercase
conventional prefixes; no push, no PR.

## Steps

### Step 1: Automation probe (design §2.3, slice 1)

Create `Utilities/AutomationPermission.swift` implementing
`checkAutomationPermission()` exactly per the design §2.3 code sketch
(`AEDeterminePermissionToAutomateTarget` against `com.apple.MobileSMS`,
no-prompt). Import note: the function lives in ApplicationServices/AE — find
the working import (`import AppKit` usually suffices on macOS targets). Make
the probe injectable for tests: define
`typealias AutomationProbe = () -> (ok: Bool, status: String)` (or a small
protocol) so `Diagnose` can take it as a dependency defaulting to the real one
— CI runners report `not_determined`, so tests must inject.

**Verify**: `swift build` → exit 0.

### Step 2: State-based capabilities (slice 2 + probe-derived slice 3)

Replace the boolean `Capabilities` struct with the design's value type
(`state` + optional `note`/`fix`/`detail`) and derive all 15 §2.2 keys in
`execute()` per the §2.4 derivation rules — including `verified_send` from
`Database.checkAccess()` + the automation probe as stated above. Follow the
§3.2 JSON example exactly for key names and shape (snake_case, token-efficient,
backward-compatible health fields preserved per §3.3).

**Verify**: `swift build` → exit 0; run the suite; fix ONLY sanctioned pinned
assertions if they fail; suite green.

### Step 3: Tests

`CapabilityContractTests.swift` with injected probes (model setup on existing
diagnose-related tests):

1. All-healthy injection → send modes `supported`, `perm_*` supported,
   `verified_send` `supported`, `reply_threading`/`tapbacks`/`edit_unsend`
   `unsupported`, `live_inbox`/`rich_backend` `unavailable`.
2. Automation denied → four send modes `permission-gated`, `verified_send`
   `degraded`, `fix` text present.
3. Automation `not_determined` → send modes `unverified` (the honest default).
4. DB inaccessible → `verified_send` `permission-gated`,
   `attachments_read` `permission-gated`.
5. JSON contract: encode the response, assert the §3.2 key names exist and all
   15 capability keys are present.

**Verify**: `swift test --filter CapabilityContractTests` → 5 pass; full suite
green (report count).

### Step 4: Description + schema (slice 4)

Replace the diagnose tool description with the §3.4 agent-consumption
paragraph (trim to the repo's concise description style) and update the output
schema/comment for the new `capabilities` shape. Re-check `ToolRegistryTests`
description assertions.

**Verify**: full suite green.

## Done criteria

- [ ] `swift build` exit 0; `swift test` all pass (report final count)
- [ ] `grep -c "sendTextToParticipant: true" swift/Sources/iMessageMax/Tools/Diagnose.swift` → 0 (hardcoded booleans gone)
- [ ] All 15 §2.2 capability keys appear in `Diagnose.swift` (grep a sample: `send_text_dm`, `verified_send`, `perm_automation`, `rich_backend`)
- [ ] `Send.swift` untouched (`git diff --stat <base>..HEAD` excludes it)
- [ ] Only in-scope files changed

## STOP conditions

- `AEDeterminePermissionToAutomateTarget` does not compile on this toolchain
  after reasonable import attempts — report the exact errors; do not switch to
  a private API or a prompting check.
- A failing test outside the sanctioned pinned assertions.
- The §3.2 JSON conflicts with what `DiagnoseResult`'s existing Encodable
  machinery can express without restructuring beyond `Capabilities` — report
  the conflict rather than redesigning the response wholesale.

## Maintenance notes

- When plan 012 lands, no change here is required (verified_send is
  probe-derived); a later slice may enrich it with live verification stats.
- New capabilities (e.g. a future rich backend) get a row in §2.2 first, then
  a key here — keep doc and code in sync.
