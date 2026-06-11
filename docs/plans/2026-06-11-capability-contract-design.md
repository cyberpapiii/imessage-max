# Capability Contract Design Spike

> **Type:** Design spike — no production code changes.
> **Plan reference:** Plan 011, written at commit `de0641d`, 2026-06-11.
> **Drift check result:** `git diff --stat 90c65e1..HEAD --
> swift/Sources/iMessageMax/Tools/Diagnose.swift` — empty; no drift.

---

## 1. What `diagnose` knows today

### 1.1 Output shape

`Diagnose.swift:6–56` defines `DiagnoseResult` with three nested structs:

**`DatabaseStatus`** (`Diagnose.swift:7–12`)

| Field | Type | Source |
|---|---|---|
| `accessible` | Bool | `Database.checkAccess()` at `Database.swift:21` |
| `status` | String | `"accessible"` / `"permission_denied"` / `"database_not_found"` |
| `path` | String | `Database.defaultPath` (expands `~/Library/Messages/chat.db`) |
| `fix` | String? | Human-readable remediation text if inaccessible |

**`ContactsStatus`** (`Diagnose.swift:14–19`)

| Field | Type | Source |
|---|---|---|
| `authorized` | Bool | `ContactResolver.authorizationStatus()` at `ContactResolver.swift:21` |
| `status` | String | `"authorized"` / `"denied"` / `"restricted"` / `"not_determined"` / `"limited"` |
| `loaded` | Int? | `resolver.getStats().handleCount` (only when authorized and initialized) |
| `fix` | String? | Human-readable remediation text if unauthorized |

**`Capabilities`** (`Diagnose.swift:21–39`)

| Field | JSON key | Value today | Source |
|---|---|---|---|
| `sendTextToParticipant` | `send_text_to_participant` | `true` (hardcoded) | `Diagnose.swift:153` |
| `sendTextToChat` | `send_text_to_chat` | `true` (hardcoded) | `Diagnose.swift:154` |
| `sendFileToParticipant` | `send_file_to_participant` | `true` (hardcoded) | `Diagnose.swift:155` |
| `sendFileToChat` | `send_file_to_chat` | `true` (hardcoded) | `Diagnose.swift:156` |
| `replyToSupported` | `reply_to_supported` | `false` (hardcoded) | `Diagnose.swift:157` |
| `tapbackSupported` | `tapback_supported` | `false` (hardcoded) | `Diagnose.swift:158` |
| `editUnsendSupported` | `edit_unsend_supported` | `false` (hardcoded) | `Diagnose.swift:159` |

**Top-level fields:**

| Field | Source |
|---|---|
| `version` | `Version.current` |
| `process_id` | `ProcessInfo.processInfo.processIdentifier` |
| `status` | `"ready"` if `dbAccessible && contactsAuthorized`, else `"needs_setup"` (`Diagnose.swift:133–134`) |

### 1.2 Runtime checks performed

The `execute()` function (`Diagnose.swift:93–163`) runs two live probes:

1. **Full Disk Access** — `Database.checkAccess()` (`Database.swift:21`): attempts to open `chat.db` read-only via `sqlite3_open_v2(..., SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, ...)`. Returns `(ok: Bool, status: String)`.
2. **Contacts authorization** — `ContactResolver.authorizationStatus()` (`ContactResolver.swift:21`): calls `CNContactStore.authorizationStatus(for: .contacts)`. If authorized, also calls `resolver.initialize()` and records `handleCount`.

No other probes run. In particular:

- **No Automation permission check**: there is no probe confirming that `osascript` can drive Messages.app. Send capabilities today are assumed, not probed.
- **No version or OS check**: macOS version is not recorded.
- **No Messages.app availability check**: whether Messages.app is running or installed is not probed.

### 1.3 Gap list

The following items that R8 requires a capability contract to cover have **no probe today**:

| Gap | R8 category | Effect of omission |
|---|---|---|
| Automation permission for Messages.app | send modes | All send capabilities are optimistic guesses, not probed |
| `verified_send` method availability | send verification | Not reported; Slice 4 of the send-verification design intends to add `send_verification: "db_reread"` |
| Attachments offload state | attachment handling | Only surfaced at call time as `attachment_offloaded` error (`GetAttachment.swift:192–200`); not in diagnose |
| Live/freshness availability | freshness | No polling, streaming, or delta surface exists; not reported |
| Rich/private backend state | rich backend | No alternative backends configured; not reported |
| macOS version / Messages.app version | (context) | Relevant for per-OS capability caveats; not recorded |

The current `Capabilities` struct uses hardcoded booleans, not runtime states. Every send
capability returns `true` regardless of whether Automation permission is actually granted.
This violates R9 (prefer honest limitation over optimistic affordance).

---

## 2. Capability taxonomy

### 2.1 State vocabulary (R7)

| State | Meaning |
|---|---|
| `supported` | Feature works on this install; probe confirms it |
| `unsupported` | Feature does not exist in the safe local backend and will not be attempted |
| `degraded` | Feature exists but is impaired (e.g., DB accessible but read latency elevated, or offloaded attachments require extra round-trip) |
| `permission-gated` | Feature requires a macOS permission that is not granted; fix path available |
| `risky-private` | Feature works but carries elevated routing or privacy risk; requires explicit confirmation |
| `experimental` | Feature is available via an opt-in path; behavior may change |
| `unavailable` | Feature has no implementation in the current backend; not planned for this release |
| `unverified` | No runtime probe exists; state cannot be determined at diagnose time |

### 2.2 Full capability table

Each row includes: the proposed JSON key, the R8 category it satisfies, possible states, the probe that determines state (existing function or "needs new probe"), and the honest default per R9.

| Key | R8 Category | Possible States | Probe | Honest Default |
|---|---|---|---|---|
| `send_text_dm` | send modes | `supported` / `permission-gated` / `unverified` | needs new probe: `OSAutomationPermission.check()` | `unverified` (no automation probe today) |
| `send_text_group` | send modes | `supported` / `permission-gated` / `unverified` | same automation probe | `unverified` |
| `send_file_dm` | send modes | `supported` / `permission-gated` / `unverified` | same automation probe | `unverified` |
| `send_file_group` | send modes | `risky-private` / `permission-gated` / `unverified` | same automation probe; always risky per R4 | `risky-private` once probe confirms automation granted |
| `verified_send` | send verification | `supported` / `degraded` / `permission-gated` | `Database.checkAccess()` — DB readable required for re-read proof; `error = 0` check required (failed rows write immediately with `error = 22`; see send-verification design §3) | `supported` when DB accessible; `degraded` when DB readable but automation unverified |
| `attachments_read` | attachment handling | `supported` / `permission-gated` | `Database.checkAccess()` | `supported` when DB accessible |
| `attachments_offloaded` | attachment handling | `supported` | (no probe; attempted at call time per `GetAttachment.swift:188–200`) | `supported` with caveat note: offloaded files trigger async iCloud download; caller must retry |
| `reply_threading` | reply availability | `unsupported` | hardcoded: `Send.swift:207` returns `.error("reply_to is not yet implemented")` | `unsupported` |
| `tapbacks` | tapback availability | `unsupported` | no send tool exists for tapbacks | `unsupported` |
| `edit_unsend` | edit/unsend availability | `unsupported` | no send tool exists for edit or unsend | `unsupported` |
| `live_inbox` | live/freshness | `unavailable` | no streaming or delta surface in codebase | `unavailable` |
| `perm_full_disk` | permissions | `supported` / `permission-gated` / `degraded` | `Database.checkAccess()` at `Database.swift:21`; returns `"accessible"` / `"permission_denied"` / `"database_not_found"` | runtime-probed |
| `perm_contacts` | permissions | `supported` / `permission-gated` / `unverified` | `ContactResolver.authorizationStatus()` at `ContactResolver.swift:21`; returns `"authorized"` / `"denied"` / `"restricted"` / `"not_determined"` / `"limited"` | runtime-probed |
| `perm_automation` | permissions | `supported` / `unverified` | **needs new probe** (see §2.3); no check today | `unverified` |
| `rich_backend` | rich backend state | `unavailable` / `experimental` | static constant; no alternative backend implemented or opt-in exists | `unavailable` |

### 2.3 New probe needed: Automation permission

No function in the codebase probes whether `com.apple.messages.AppleEvents` permission is
granted. The send tools assume it is. A probe must be added to `Diagnose.swift` before the
`perm_automation`, `send_text_dm`, `send_text_group`, `send_file_dm`, and `send_file_group`
capabilities can report `supported` rather than `unverified`.

**Candidate implementation** (read-only; no side effects; no private framework):

```swift
static func checkAutomationPermission() -> (ok: Bool, status: String) {
    // AEDeterminePermissionToAutomateTarget is available since macOS 10.14.
    // It checks TCC for the target bundle without displaying a dialog.
    // Passing 0 (kAEDefaultTimeout) avoids blocking.
    guard let messagesTarget = NSAppleEventDescriptor(
        bundleIdentifier: "com.apple.MobileSMS"
    ) else {
        return (false, "messages_not_found")
    }
    let status = AEDeterminePermissionToAutomateTarget(
        messagesTarget.aeDesc,
        typeWildCard,
        typeWildCard,
        false  // do not prompt
    )
    switch status {
    case noErr:          return (true,  "authorized")
    case errAEEventNotPermitted: return (false, "denied")
    default:             return (false, "not_determined")
    }
}
```

This is a pure read-only TCC check; it never writes to chat.db and does not use private
frameworks. The Messages.app bundle identifier on macOS is `com.apple.MobileSMS`.

### 2.4 Derivation rules for send capabilities from probes

Once the automation probe exists, the derivation logic is:

```
let automation = checkAutomationPermission()
let db = Database.checkAccess()

send_text_dm:    automation.ok → supported | !automation.ok → permission-gated or unverified
send_text_group: same
send_file_dm:    same
send_file_group: automation.ok → risky-private (always, per R4) | else → permission-gated or unverified

verified_send:   db.ok && automation.ok → supported
                 db.ok && !automation.ok → degraded (can re-read but can't prove send succeeded)
                 !db.ok → permission-gated (send verification impossible without DB read)
```

### 2.5 Consistency with send-verification design

The `verified_send` capability must be consistent with the send-verification design's findings
(Section 3, measured 2026-06-11):

- **`error = 0` is mandatory in the confirmation query.** Failed sends write rows immediately
  with `error = 22` / `is_sent = 0`. Row existence alone is not proof. The `verified_send`
  capability being `supported` means the verification loop will check `m.error = 0`, not
  just row existence.
- **AppleScript `send` returns nothing at runtime** (measured, macOS 25.5.0). Guid-based
  matching is not available. The `verified_send` method is always `"db_reread"`.
- **Row visibility latency ~26ms.** A `supported` `verified_send` with a short polling budget
  (5 polls × 200ms) is sufficient for text sends.
- The `send_verification` detail field in the capability output aligns with what the
  send-verification design's Slice 4 calls "report `send_verification: "db_reread"`."

---

## 3. Contract surface design

### 3.1 Decision: extend `diagnose`, not a new tool

**Options considered:**

| Option | Pros | Cons |
|---|---|---|
| Extend `diagnose` response with `capabilities` object | Backward compatible (add fields, don't remove); agents already call `diagnose` for setup checks; single call satisfies F2 | Mixes health + capability in one call; larger response token count |
| New `capabilities` tool | Clean separation; can be called without health output | Agents must know to call a new tool; adds to tool count; violates AGENTS.md preference for fewer tools |
| MCP `resources` surface | Cacheable by clients; suits stable static data | Not all clients implement resources; poorer discoverability; diagnose is already the health/setup entry point |

**Decision: extend `diagnose`'s response.** Keep all existing health fields (`database`,
`contacts`, `status`, `version`, `process_id`) for backward compatibility. Replace the
current boolean `Capabilities` struct with a richer `capabilities` object using `state`
strings. Agents consuming the old boolean shape get a compile-time (schema) or runtime
(field type mismatch) signal that the schema evolved.

Token efficiency: each capability entry is `{ "state": "X" }` plus optional `"note"` and
`"fix"` keys. Short keys per AGENTS.md §188 "Token-Efficient Response Design".

### 3.2 Proposed JSON response (full example — healthy install)

```json
{
  "version": "1.5.0",
  "process_id": 12345,
  "status": "ready",
  "database": {
    "accessible": true,
    "status": "accessible",
    "path": "/Users/rob/Library/Messages/chat.db"
  },
  "contacts": {
    "authorized": true,
    "status": "authorized",
    "loaded": 487
  },
  "capabilities": {
    "send_text_dm":          { "state": "supported" },
    "send_text_group":       { "state": "supported" },
    "send_file_dm":          { "state": "supported" },
    "send_file_group":       {
      "state": "risky-private",
      "note": "Group file sends require confirm:true; routing cannot be verified before send"
    },
    "verified_send":         {
      "state": "supported",
      "detail": "db_reread"
    },
    "attachments_read":      { "state": "supported" },
    "attachments_offloaded": {
      "state": "supported",
      "note": "Offloaded files trigger iCloud download; retry get_attachment after a few seconds"
    },
    "reply_threading":       { "state": "unsupported" },
    "tapbacks":              { "state": "unsupported" },
    "edit_unsend":           { "state": "unsupported" },
    "live_inbox":            { "state": "unavailable" },
    "perm_full_disk":        { "state": "supported" },
    "perm_contacts":         { "state": "supported" },
    "perm_automation":       { "state": "supported" },
    "rich_backend":          { "state": "unavailable" }
  }
}
```

**Degraded example (no Full Disk Access):**

```json
{
  "status": "needs_setup",
  "database": {
    "accessible": false,
    "status": "permission_denied",
    "path": "/Users/rob/Library/Messages/chat.db",
    "fix": "Grant Full Disk Access: System Settings -> Privacy & Security -> Full Disk Access"
  },
  "capabilities": {
    "send_text_dm":    { "state": "supported" },
    "send_text_group": { "state": "supported" },
    "send_file_dm":    { "state": "supported" },
    "send_file_group": { "state": "risky-private", "note": "Group file sends require confirm:true" },
    "verified_send":   {
      "state": "permission-gated",
      "fix": "Grant Full Disk Access to enable DB re-read verification after sends"
    },
    "attachments_read": {
      "state": "permission-gated",
      "fix": "Grant Full Disk Access to read attachment content"
    },
    "attachments_offloaded": { "state": "permission-gated" },
    "reply_threading": { "state": "unsupported" },
    "tapbacks":        { "state": "unsupported" },
    "edit_unsend":     { "state": "unsupported" },
    "live_inbox":      { "state": "unavailable" },
    "perm_full_disk":  {
      "state": "permission-gated",
      "fix": "Grant Full Disk Access: System Settings -> Privacy & Security -> Full Disk Access"
    },
    "perm_contacts":   { "state": "supported" },
    "perm_automation": { "state": "supported" },
    "rich_backend":    { "state": "unavailable" }
  }
}
```

**Unverified example (no automation probe implemented yet — current default):**

Until the automation probe (§2.3) is implemented, all four send modes and
`perm_automation` show `unverified`:

```json
{
  "capabilities": {
    "send_text_dm":    { "state": "unverified", "note": "Automation permission not yet probed" },
    "send_text_group": { "state": "unverified", "note": "Automation permission not yet probed" },
    "send_file_dm":    { "state": "unverified", "note": "Automation permission not yet probed" },
    "send_file_group": { "state": "unverified", "note": "Automation permission not yet probed" },
    "perm_automation": { "state": "unverified", "note": "No runtime probe; add AEDeterminePermissionToAutomateTarget check" }
  }
}
```

### 3.3 Backward compatibility

The current `Capabilities` struct (`Diagnose.swift:21–39`) uses boolean fields. The proposed
schema replaces each field with a `{ "state": "..." }` object. This is a breaking change to
the `capabilities` key's schema.

Mitigation: emit the new `state`-based shape alongside the old booleans for one release by
adding a `capabilities_v1` (legacy boolean block) alongside the new `capabilities` block.
Alternatively, the maintainer may prefer a clean cut given that no external clients are
confirmed to parse the capability block. This is an open question (see §4.3).

### 3.4 Agent consumption paragraph (for the tool description)

> **Use `diagnose` before attempting any send, attachment, or live-inbox operation.** Check
> `capabilities.<key>.state` for each feature you plan to use. `"supported"` means the
> feature is available and probed on this install. `"unsupported"` means the feature does
> not exist — do not attempt it or expose it to the user as an option. `"permission-gated"`
> means a macOS permission must be granted before the feature can work; surface the `fix`
> field to the user. `"risky-private"` means the feature requires explicit confirmation
> (pass `confirm: true`). `"unverified"` means the capability state cannot be determined
> at diagnose time; treat it as potentially available but proceed cautiously. `"unavailable"`
> means no implementation exists in the current backend — do not attempt and do not mention
> to the user as a near-term option. The `database.accessible` field governs whether all
> read tools (`get_messages`, `list_chats`, `search`, etc.) will work. A `"needs_setup"`
> top-level `status` means at least one required permission is missing; resolve it before
> proceeding.

---

## 4. Build outline and open questions

### 4.1 Incremental build slices

**Slice 1: Add automation probe (~0.5 days)**

Add `checkAutomationPermission()` to a new `AutomationPermission.swift` (or inline into
`Diagnose.swift`) using `AEDeterminePermissionToAutomateTarget`. Unit-test with a mock TCC
response. No change to the JSON output shape yet.

**Slice 2: Replace the boolean `Capabilities` struct with state-based output (~1 day)**

Replace `DiagnoseResult.Capabilities` (`Diagnose.swift:21–39`) with a new `Capability`
value type: `struct Capability: Codable { let state: String; let note: String?; let fix:
String?; let detail: String? }`. Update `execute()` (`Diagnose.swift:93–163`) to derive
each capability from the probes rather than hardcoding. The 15 keys listed in §2.2 are
the complete initial set. Wire the automation probe from Slice 1 into the four send-mode
capabilities and `perm_automation`.

**Slice 3: Wire `verified_send` to send-verification delivery (~0.5 days)**

After the send-verification build plan lands its Slice 4 (which adds `send_verification:
"db_reread"` to the diagnose output), update `verified_send`'s state derivation to match:
`supported` when DB accessible, `degraded` when DB accessible but automation unverified,
`permission-gated` when DB inaccessible. Ensure the confirmation query includes `m.error =
0` as specified in the send-verification design (§3, measured findings).

**Slice 4: Update tool description and schema (~0.25 days)**

Replace the existing `diagnose` tool description (`Diagnose.swift:70`) with the agent
consumption paragraph from §3.4. Update the output schema (`OutputSchema.object`) to
document the new `capabilities` shape.

**Total coarse estimate: ~2.25 days.**

### 4.2 Caching and staleness

Capability states derived from `Database.checkAccess()` and `ContactResolver.authorizationStatus()`
are cheap to re-probe on every `diagnose` call (the existing tool already does this). The
automation probe (`AEDeterminePermissionToAutomateTarget`) is also fast and non-blocking
with `false` for the ask-permission flag.

However, permission grants can change between `diagnose` and the actual tool call (user
revokes permission in System Settings). The capability contract is a snapshot, not a live
guarantee. Agents should treat a capability-state `send_text_dm: supported` as "supported
at last diagnose time" and expect `failed` as a possible outcome from `send` if permissions
changed.

For long-running agent sessions, the maintainer should decide whether to add a
`diagnosed_at` ISO8601 timestamp to the response so agents can detect stale snapshots.

### 4.3 Open questions for maintainer

1. **Backward compatibility cut vs. alias.** The current boolean `capabilities` schema is
   a breaking change if any external client parses it. Is a `capabilities_v1` legacy alias
   needed for one release, or is a clean cut acceptable given the known client base?

2. **`initialize` metadata.** The MCP `initialize` response (`MCPServer.swift:10–16`) uses
   `Version.serverCapabilities` — an MCP-level capability advertisement, not the
   iMessage-Max capability contract. Should a summary of key capability states (e.g.,
   `perm_full_disk` and `perm_automation`) appear in `initialize` server info, so agents
   can skip a `diagnose` call on first connect? This adds coupling between server init and
   the probe logic.

3. **`experimental` state for future rich backends.** The brainstorm's A4 actor (future
   rich backend maintainer) would use `experimental` to gate opt-in paths. How should an
   experimental backend register its capability entries — static constants, environment
   variables, or a capability registry? This design does not specify the registration
   mechanism; it should be defined before any A4 work begins.

4. **`send_file_group` as `risky-private` vs. `supported`.** Currently file sends to groups
   are allowed with `confirm: true`. `risky-private` accurately describes the risk posture
   (routing cannot be pre-verified), but some agents may interpret it as "do not use." The
   `note` field should provide enough context. If the maintainer prefers `supported` with a
   separate `risk` field, that is an alternative encoding.

5. **`diagnosed_at` timestamp.** Adding an ISO8601 `diagnosed_at` field lets agents detect
   stale capability snapshots in long-running sessions. Optional but recommended for F2
   correctness.

### 4.4 What this spike did not investigate

- **`AEDeterminePermissionToAutomateTarget` availability on macOS Tahoe.** The API was
  introduced in macOS 10.14; behavior under Tahoe (macOS 25.x) has not been tested. The
  build plan should include a runtime guard.
- **Automation permission behavior on first run.** The first `diagnose` call before any
  send is attempted may return `not_determined`; the probe with `askUserIfNeeded: false`
  returns `not_determined`, not a dialog. The correct first-run UX needs a decision:
  show `unverified` and let the first send prompt, or add an explicit permission-request
  flow.
- **Capability contract in test fixtures.** The existing test suite does not exercise the
  `Capabilities` struct in `DiagnoseResult`. Build plans for Slices 1–2 should add
  `XCTest` coverage for each derivation rule.
- **SMS vs. iMessage send-mode distinction.** The `send_text_dm` capability does not
  currently distinguish whether the target handle is reachable via iMessage vs. SMS
  fallback. A future capability entry (`send_sms_fallback`) could surface this, but it
  requires a chat.db probe (checking `chat.service_name`) that this spike did not design.
- **`rich_backend` activation path.** How an operator would enable a future rich backend
  and how the capability contract detects it (env var, config file, compiled flag) is not
  specified here.
