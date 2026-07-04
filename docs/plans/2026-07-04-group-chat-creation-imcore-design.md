---
date: 2026-07-04
topic: group-chat-creation-imcore
status: design — pending implementation plan
---

# Group Chat Creation via Injected IMCore Helper

## Summary

Add the ability to create a new iMessage group chat and message an arbitrary
set of recipients that have no existing thread, entirely without UI automation.
This is delivered by injecting a helper dylib into `Messages.app` and calling
Apple's private **IMCore** framework directly — the same mechanism the
open-source BlueBubbles project uses.

As part of this work, **all** send operations (DMs, existing group sends,
file sends, and new-group creation) move onto the IMCore backend, which is more
capable and consistent than AppleScript. The existing AppleScript backend is
**retained but dormant**, selectable at runtime via a flag, so the server can
roll back to the SIP-independent path instantly if IMCore breaks.

## Problem Frame

`send` today can message any conversation that already exists (`chat_id` for
groups, handle for DMs) through the AppleScript backend, and reads are
verified against `chat.db`. The one thing it cannot do is **start a new group
chat** from a list of recipients. Apple removed AppleScript group creation at
Big Sur and ships no public API for it as of 2026; every product that offers
this (BlueBubbles, Sendblue, LoopMessage, etc.) does it either by calling
private IMCore inside `Messages.app` or by relaying through hosted Mac hardware.

The user has chosen the local private-IMCore path (a UI-free, seamless,
reliable mechanism) and has explicitly accepted its cost: the host Mac must run
with **SIP disabled** and **library validation disabled**, and the private
framework surface is inherently fragile across macOS releases.

### Relationship to v2 requirements

The v2 requirements doc
(`docs/brainstorms/2026-05-17-imessage-max-v2-trustworthy-core-requirements.md`)
anticipated this in actor **A4 — "Future rich backend maintainer: adds optional
BlueBubbles, imsg, or private-helper integrations later without changing the
core product promise."** This design realizes A4.

It does, however, **change the default posture** described in that doc's Problem
Frame, which lists "private frameworks by default: avoided" as a core safety
advantage. This design makes a private helper the **default send backend** on an
install that has opted into SIP-off. That trade is deliberate and is contained
by the fallback and capability-gating described below, but it is a real change
to the product's stated default and is called out here so it is not silent.

## Goals

- G1. `send` to N recipients with no existing thread creates the group and
  delivers the message, UI-free.
- G2. Existing-thread reuse: if a group with *exactly* those participants
  already exists, send into it rather than creating a duplicate.
- G3. All sends route through IMCore by default (single backend).
- G4. Instant, no-redeploy rollback to the AppleScript backend via a runtime
  flag; git revert as the ultimate backstop.
- G5. No new hang states — inability to create a group is reported as a
  structured `capability_unavailable`, consistent with the existing capability
  contract.
- G6. Verified-send semantics (proof states from
  `docs/plans/2026-06-11-send-verification-design.md`) apply unchanged to
  IMCore sends.

## Non-Goals

- Adding/removing participants from an existing group, renaming groups, or
  setting group photos (future IMCore features; not this slice).
- Tapbacks, typing indicators, edit/unsend (IMCore makes these *possible*
  later; out of scope now).
- Re-enabling SIP automatically or hiding the security cost from the user.
- Any hosted-relay / cloud path.

## Architecture

Five units, each with a single responsibility and a narrow interface.

### U1. `imessage-max-helper` dylib (new, Objective-C)

Injected code that runs **inside** `Messages` / `com.apple.MobileSMS`.

- On `+load`: verify it is loaded inside the Messages bundle; open a **Unix
  domain socket** to the server and register.
- Inbound command surface (JSON over the socket), IMCore-backed:
  - `create-chat(addresses[], service)` → `{chat_guid}` | structured error.
    Resolves each address to an `IMHandle` via
    `[[IMAccountController sharedInstance] activeIMessageAccount] imHandleWithID:]`
    (or the SMS account), then
    `[[IMChatRegistry sharedInstance] chatForIMHandles:]` for multi-recipient
    (group) or `chatForIMHandle:` for a single recipient, and returns
    `[chat guid]`.
  - `send-message(chat_guid, body, …)` → constructs an `IMMessage` and calls
    `[chat sendMessage:]`.
  - `send-attachment(chat_guid, path, …)` → IMCore attachment send.
- This dylib is the **entire** private-framework surface. Nothing else in the
  system links or calls IMCore.
- Method interception via ZKSwizzle where needed, matching the reference
  implementation.

### U2. `HelperBridge` (new, Swift, server side)

Client for the helper socket. Owns connection, request/response framing,
timeouts, and health.

- `func createGroupChat(addresses: [String], service: Service) -> Result<String, HelperError>`
- `func sendText(chatGuid: String, body: String) -> Result<Void, HelperError>`
- `func sendFile(chatGuid: String, path: String) -> Result<Void, HelperError>`
- `func probe() -> HelperStatus` — is the helper connected and responsive
  right now.

### U3. `MessagesLifecycle` (new, Swift)

Owns `Messages.app` so injection is deterministic.

- Launches Messages with `DYLD_INSERT_LIBRARIES=<dylib path>`.
- Monitors it; on socket-drop / process exit, relaunches and re-injects.
- Provides the signal `HelperBridge.probe()` reports on.
- Documented behavioral change: the launchd service now launches/relaunches a
  user-facing GUI app. Guardrails (backoff, "already running" detection) must
  avoid fighting the user over whether Messages is open.

### U4. `IMCoreScriptRunner` (new, Swift) — conforms to existing `ScriptRunning`

The default backend. Implements the four `ScriptRunning` operations by
delegating to `HelperBridge`, plus exposes group creation to `SendResolution`.
Because it conforms to the existing `ScriptRunning` protocol
(`swift/Sources/iMessageMax/Utilities/AppleScript.swift`), it slots into the
current `send` path as a backend swap, not a rewrite.

### U5. `LiveScriptRunner` (existing) — retained as dormant fallback

The current AppleScript backend stays in the tree, unchanged, as a second
`ScriptRunning` conformer. A runtime flag selects which backend `send` uses.

## Backend Selection & Rollback

- A single config/env flag (e.g. `IMESSAGE_MAX_SEND_BACKEND=imcore|applescript`,
  default `imcore`) picks the active `ScriptRunning` conformer at server start.
- **Runtime rollback:** flip the flag, restart the service → back on AppleScript
  in seconds, no rebuild/re-sign. AppleScript send is SIP-independent, so it
  works even when the IMCore helper cannot (SIP re-enabled, symbol moved).
- **Source rollback:** git revert of the feature commits is the ultimate
  backstop; commits are structured so the IMCore units revert cleanly and the
  server returns to an AppleScript-only build.
- **Out of rollback scope (system state, not code):** SIP / library validation
  stay disabled until manually re-enabled; group chats already created remain
  created (real iMessage data).

## Data Flow — send to a new group

`send({to: [alice, bob, carol], text})`:

1. `SendResolution` queries `chat.db` for a thread whose participant set is
   *exactly* {alice, bob, carol}. If found → send into that `chat_id` via the
   active backend (G2 reuse). Done.
2. If none exists → `HelperBridge.createGroupChat([...])` → dylib resolves
   handles, `chatForIMHandles:`, returns `chat_guid`.
3. Server sends the message into `chat_guid` via the active backend.
4. **Verification** (unchanged plan-017 contract): re-read `chat.db` for the
   outbound row in the new chat with `error = 0` → return `confirmed` with the
   new `chat_id`; otherwise the existing pending/uncertain/failed proof states.

The private API only ever *creates the empty thread and dispatches sends*;
success is still adjudicated by reading `chat.db`.

## Capability Contract & Failure Semantics

- Before attempting creation or an IMCore send, `HelperBridge.probe()` gates it.
- **Helper live** → proceed.
- **Helper down / SIP enabled / symbol missing / injection failed** → return a
  structured `capability_unavailable` result that (a) names the capability, and
  (b) tells the human what to enable (SIP + library validation) — consistent
  with `docs/plans/2026-06-11-capability-contract-design.md` and the existing
  Automation-permission messaging. Never a hang.
- If backend flag is `applescript`, group creation reports
  `capability_unavailable` (AppleScript cannot create groups) while all other
  sends work — a coherent degraded state.

## Tool Surface Changes

- `send`'s `to` accepts multiple recipients (array, or comma-delimited string)
  in addition to the existing single `to` / `chat_id`. Multi-recipient with no
  existing thread triggers creation.
- No new tool. (Matches the project's 1–2-calls-per-intent goal: the agent says
  who + what; resolution decides reuse vs. create.)
- Response reuses existing `SendResponse` shapes, returning the new `chat_id`
  on `confirmed`.

## Testing

- **`HelperBridge`**: unit-tested against a stub socket server speaking the JSON
  protocol (mirrors `StubScriptRunner`, plan 002).
- **Protocol**: golden request/response tests for `create-chat`,
  `send-message`, `send-attachment`, and each structured error.
- **Backend routing**: `IMCoreScriptRunner` vs `LiveScriptRunner` selected by
  flag; assert `SendResolution` routes existing-thread vs new-group correctly
  under each.
- **Capability gating**: `probe()` down → `capability_unavailable`, no hang.
- **On-device integration** (SIP-off machine, documented checklist): real group
  creation + verified send; the IMCore/private layer cannot be unit-tested
  off-device.

## Distribution & Install (the real cost)

- New build artifact: the helper dylib, built and placed by `make install`
  alongside the server binary and code-signing step.
- New one-time user setup, documented in `AGENTS.md` / `README.md`:
  - Disable SIP: `csrutil disable` (Recovery Mode; Apple Silicon flow).
  - Disable library validation:
    `sudo defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation -bool true`
  - Without these, the helper reports `capability_unavailable`; if the backend
    flag is left at `imcore`, sends degrade — so install docs should pair the
    SIP steps with the backend expectation.
- **Honest security note (must ship in docs):** this lowers the machine's
  security posture system-wide and is inherently version-fragile against Apple.
  The containment architecture (single dylib surface + dormant AppleScript
  fallback) is what keeps a broken IMCore from taking down everyday sending.

## Risks

- R1. Apple moves/removes IMCore symbols on a macOS update → group creation and
  (if backend=imcore) all sends break. **Mitigation:** flag-flip to AppleScript
  fallback; dylib is the only thing needing repair.
- R2. Server-owned Messages lifecycle fights the user or loops on relaunch.
  **Mitigation:** backoff + "already running" detection + a kill switch.
- R3. Security posture: SIP-off is a standing system weakness. **Mitigation:**
  documented explicitly; opt-in; not enabled by the installer.
- R4. Injection env (`DYLD_INSERT_LIBRARIES`) stripped in some launch contexts.
  **Mitigation:** server owns the launch (U3), so it controls the environment.

## Open Questions (for the implementation plan)

- Exact socket protocol framing and versioning (so a newer server can detect an
  older dylib).
- Where the dylib lives on disk and how signing interacts with disabled library
  validation.
- Whether file-send verification (transfer-status polling) needs an IMCore
  equivalent or can continue to read `chat.db`/transfer state.
