# Plan 004: Contain attachment file access to allowed roots

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 57a2ff3..HEAD -- swift/Sources/iMessageMax/Tools/GetAttachment.swift swift/Sources/iMessageMax/Tools/ListAttachments.swift swift/Tests/iMessageMaxTests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW (additive guard; main risk is breaking the existing fixture-based tests, handled below)
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `57a2ff3`, 2026-06-11

## Why this matters

`get_attachment` reads whatever file path the `attachment.filename` column of chat.db points to, after tilde expansion, with no check that the path stays under the Messages attachment store. In normal operation Messages.app writes those paths, but the column is data, not code: a tampered or maliciously-synced chat.db row could point at `~/.ssh/id_ed25519` or any user-readable file, and `get_attachment` would happily return its bytes to the MCP client. This is defense-in-depth for a server whose whole job is brokering access to sensitive personal data: file reads should be contained to the directories attachments can legitimately live in.

## Current state

- `swift/Sources/iMessageMax/Tools/GetAttachment.swift` — the read path. Lines 166-179:

```swift
            guard let filename = attachment.filename else {
                return .error(
                    type: "attachment_unavailable",
                    message: "Attachment file path not available",
                    details: nil
                )
            }

            // Expand ~ in path
            let expandedPath = (filename as NSString).expandingTildeInPath
            let fileURL = URL(fileURLWithPath: expandedPath)

            // Check if file exists locally
            if !FileManager.default.fileExists(atPath: expandedPath) {
```

  The error-result convention in this file is `.error(type:message:details:)` — match it.
- `swift/Sources/iMessageMax/Tools/ListAttachments.swift` — line 421 expands paths from the same column to compute availability:

```swift
            let expandedPath = path.map { ($0 as NSString).expandingTildeInPath }
```

- **Critical test constraint**: `GetAttachmentToolTests` (in `swift/Tests/iMessageMaxTests/PlaceholderTests.swift:314`) inserts attachments whose `filename` points into `FileManager.default.temporaryDirectory` (via `makeFixtureImage()` in `ToolTestSupport.swift:205`). A hardcoded `~/Library/Messages` allowlist would break these tests. The containment root must therefore be injectable, defaulting to the real attachment locations.
- Real chat.db attachment paths live under `~/Library/Messages/Attachments/` (and occasionally other subdirectories of `~/Library/Messages/`).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| All tests | `cd swift && swift test` | exit 0, all pass |
| Focused | `cd swift && swift test --filter AttachmentPathContainmentTests` | all pass |
| Focused (existing) | `cd swift && swift test --filter GetAttachmentToolTests` | all pass |

## Scope

**In scope**:
- `swift/Sources/iMessageMax/Tools/GetAttachment.swift`
- `swift/Sources/iMessageMax/Tools/ListAttachments.swift`
- `swift/Sources/iMessageMax/Utilities/AttachmentPathPolicy.swift` (create)
- `swift/Tests/iMessageMaxTests/AttachmentPathContainmentTests.swift` (create)
- `swift/Tests/iMessageMaxTests/PlaceholderTests.swift` — ONLY if `GetAttachmentToolTests` needs to pass an explicit allowed root through the tool entry point; change nothing else in that file.
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- `Send.swift` / send-side file staging — sending a user-specified local file is intentional behavior (the user/agent names the file explicitly); do not add containment there.
- `Enrichment/` processors — they receive already-validated paths.
- `Database.swift`.

## Git workflow

- Branch: `advisor/004-attachment-path-containment`
- Commit style: lowercase conventional prefix, e.g. `fix: contain attachment reads to allowed roots`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Create the policy helper

New file `swift/Sources/iMessageMax/Utilities/AttachmentPathPolicy.swift`:

```swift
import Foundation

/// Validates that attachment paths from chat.db stay inside allowed roots.
/// chat.db content is data, not trusted input — a tampered row must not
/// turn get_attachment into an arbitrary file read.
enum AttachmentPathPolicy {
    static let defaultRoots: [String] = [
        ("~/Library/Messages" as NSString).expandingTildeInPath
    ]

    /// Returns the canonical path if it is inside one of the roots, else nil.
    static func validatedPath(_ rawPath: String, allowedRoots: [String] = defaultRoots) -> String? {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let canonical = URL(fileURLWithPath: expanded)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        for root in allowedRoots {
            let canonicalRoot = URL(fileURLWithPath: root)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
            if canonical == canonicalRoot || canonical.hasPrefix(canonicalRoot + "/") {
                return canonical
            }
        }
        return nil
    }
}
```

Notes that matter: the `+ "/"` suffix prevents `/Users/x/Library/MessagesEvil` matching root `/Users/x/Library/Messages`; `resolvingSymlinksInPath()` defeats symlink escapes for paths that exist (for nonexistent paths it is a no-op, which is fine — the read will fail anyway). On macOS, `/tmp` and `temporaryDirectory` resolve through `/private/...`; canonicalizing BOTH sides (path and root) keeps test roots working.

**Verify**: `cd swift && swift build` → exit 0.

### Step 2: Enforce in GetAttachment

Find how `GetAttachment`'s execute entry point receives configuration (read `GetAttachment.swift` top-to-bottom first — registration is `GetAttachment.register(on: server, db: db)`). Add an `allowedRoots: [String] = AttachmentPathPolicy.defaultRoots` parameter to the execute function (threaded from `register` with the default), then replace lines 174-176:

```swift
            // Expand ~ in path and contain to allowed roots
            guard let expandedPath = AttachmentPathPolicy.validatedPath(filename, allowedRoots: allowedRoots) else {
                return .error(
                    type: "attachment_path_invalid",
                    message: "Attachment path is outside the Messages attachment store",
                    details: nil
                )
            }
            let fileURL = URL(fileURLWithPath: expandedPath)
```

Do not echo the offending path in the message (it's attacker-influenced data going back to a client).

**Verify**: `cd swift && swift build` → exit 0. `cd swift && swift test --filter GetAttachmentToolTests` — these will now FAIL (fixture paths are in tmp). Proceed to Step 3.

### Step 3: Thread the test root through existing tests

Update `GetAttachmentToolTests` in `PlaceholderTests.swift` to pass `allowedRoots: [FileManager.default.temporaryDirectory.path]` (or the fixture image's parent directory) into the execute call. Touch nothing else in those tests.

**Verify**: `cd swift && swift test --filter GetAttachmentToolTests` → all pass again.

### Step 4: Enforce availability in ListAttachments

At `ListAttachments.swift:421`, route through the policy the same way (thread `allowedRoots` from its entry point with the default). A path outside the roots should be treated exactly like a missing file (i.e. whatever the code does today when `fileExists` is false — typically `available: false`), NOT an error: list output must stay total.

**Verify**: `cd swift && swift build` → exit 0; `cd swift && swift test` → all pass.

### Step 5: Add containment tests

`swift/Tests/iMessageMaxTests/AttachmentPathContainmentTests.swift`:

1. `testPathInsideRootValidates` — temp-dir root, file inside → non-nil canonical path.
2. `testPathOutsideRootRejected` — root A, file in sibling dir B → nil.
3. `testPrefixCousinDirectoryRejected` — root `<tmp>/Messages`, path `<tmp>/MessagesEvil/f.txt` → nil.
4. `testDotDotEscapeRejected` — path `<root>/sub/../../outside.txt` → nil (standardization collapses it).
5. `testSymlinkEscapeRejected` — create real symlink inside root pointing outside; validated path must be nil. (Use `FileManager.createSymbolicLink`; skip with `XCTSkip` if sandboxing prevents it.)
6. `testGetAttachmentRejectsOutOfRootPath` — end-to-end: fixture DB row whose filename points outside the allowed root; execute `get_attachment`; assert error type `attachment_path_invalid` and that the message does NOT contain the path.

Model the end-to-end test on `GetAttachmentToolTests` (`PlaceholderTests.swift:314-383`).

**Verify**: `cd swift && swift test --filter AttachmentPathContainmentTests` → 6 pass (5 if the symlink test skips).

## Test plan

Covered in Steps 3 and 5. Full regression: `cd swift && swift test` → all pass.

## Done criteria

- [ ] `cd swift && swift build` exits 0
- [ ] `cd swift && swift test` exits 0, including new `AttachmentPathContainmentTests`
- [ ] `grep -n "expandingTildeInPath" swift/Sources/iMessageMax/Tools/GetAttachment.swift swift/Sources/iMessageMax/Tools/ListAttachments.swift` returns no direct uses (all routed through `AttachmentPathPolicy`)
- [ ] The rejection error message contains no file path (`grep -n "attachment_path_invalid" -A2 swift/Sources/iMessageMax/Tools/GetAttachment.swift` shows a static message)
- [ ] No files outside the in-scope list modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `GetAttachment`'s execute entry point cannot accept an extra parameter without changing the MCP-facing tool schema (the allowlist must be server-side config, never a client-supplied argument — if the only way to thread it is via the tool's input schema, STOP).
- Real-world attachment paths turn out to live outside `~/Library/Messages` (e.g. you find evidence in code/docs of paths under `~/Library/SMS` or similar) — report so the default roots can be decided deliberately.
- Existing tests besides `GetAttachmentToolTests` fail after Step 2.

## Maintenance notes

- If a future macOS version relocates the attachment store, `AttachmentPathPolicy.defaultRoots` is the single place to update.
- Reviewer should scrutinize: that `allowedRoots` is not exposed in any tool input schema, and the canonical-root prefix logic (`+ "/"`).
- Deferred: the same policy could wrap `Enrichment/` file access if those processors ever take paths from anywhere other than these two tools.
