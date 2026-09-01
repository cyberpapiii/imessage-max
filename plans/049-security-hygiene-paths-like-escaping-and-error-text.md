# Plan 049: Security hygiene — LIKE escaping, path leakage in errors, and the dead stderr scrub

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 61e75d9..HEAD -- swift/Sources/iMessageMax/Tools/GetMessagesInternals.swift swift/Sources/iMessageMax/Utilities/AppleScript.swift swift/Sources/iMessageMax/Tools/Diagnose.swift swift/Sources/iMessageMax/Utilities/ClientErrorMessages.swift swift/Tests/iMessageMaxTests/AppleScriptRunnerValidationTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: 041
- **Category**: security
- **Planned at**: commit `61e75d9`, 2026-09-01

## Why this matters

Three small leaks, all in code that already tries to do the right thing:

1. `get_messages` resolves a `chat_id` that is not numeric by `SELECT ROWID FROM chat WHERE guid LIKE '%<input>%'` without escaping `%` and `_`. A client passing `chat_id: "%"` matches every chat and gets the first row's messages; `_` wildcards let one character of a GUID be guessed at a time. The rest of the codebase already has `escapeLike` and uses `ESCAPE '\\'`; this is the one site that forgot.
2. `AppleScript.classifySendStderr` lowercases the stderr text and then checks for the literal `/Users/`, which can never match lowercased input. The scrub that is supposed to keep the operator's home directory path out of the client-visible error message is dead code, so a failed attachment send can echo `/Users/<name>/Pictures/imessage-max-staging/...` to the agent.
3. `diagnose` interpolates `error.localizedDescription` from the Contacts framework and the absolute database path into its response. Both routinely contain the operator's username. `ClientErrorMessages.sanitized(_:)` exists for exactly this and is not used there.

None of these crosses a trust boundary the server does not already grant (the client can read all messages anyway), but the product promise in `AGENTS.md` is that error text does not leak local paths, and the LIKE hole is a correctness bug with a security shape.

## Current state

### LIKE without escape

`swift/Sources/iMessageMax/Tools/GetMessagesInternals.swift:130-145` (`parseChatId`):

```swift
static func parseChatId(_ chatId: String, db: Database) throws -> Int? {
    if let id = Int(chatId) { return id }
    if chatId.hasPrefix("chat"), let id = Int(chatId.dropFirst(4)) { return id }
    // Fall back to a GUID substring match.
    let rows = try db.query("SELECT ROWID FROM chat WHERE guid LIKE ? LIMIT 1", ["%\(chatId)%"])
    return rows.first?["ROWID"] as? Int
}
```

(Exact text may differ slightly; the load-bearing facts are the `LIKE ?` without `ESCAPE` and the `"%\(chatId)%"` binding without `escapeLike`.) The other six chat-id parse sites (`GetChatDetails.swift:165`, `GetContext.swift:477`, `SendResolution.swift:49`, `GetUnread.swift:208`, `ListAttachments.swift:163`, `SearchInternals.swift:98`) do not fall back to `LIKE`; they parse the numeric form only. Plan 054 unifies all seven; this plan fixes the one hole now.

`escapeLike`: `grep -rn "func escapeLike" swift/Sources` → one definition (read it for the exact signature; it escapes `\`, `%`, `_` and pairs with `ESCAPE '\\'`).

### Dead stderr scrub

`swift/Sources/iMessageMax/Utilities/AppleScript.swift:478-525` (`classifySendStderr`):

```swift
static func classifySendStderr(_ stderr: String) -> SendFailureReason {
    let lowered = stderr.lowercased()          // line 485
    ...
    if lowered.contains("/Users/") {           // line 519 — never true
        return .attachmentPathRejected
    }
```

The correct-case scrub at `:337-346` (`scrubLocalPaths` or similar; read the surrounding function) does handle `/Users/`, `/private/`, `/var/`, and `imessage-max-staging` on the *message* path. The classifier at `:519` is the one that decides the error *category*; because it never matches, a path-rejection error is classified as `.unknown` and its raw stderr goes through a different formatting branch. Confirm by reading which branch of the caller (around `:543-560`) formats `.unknown` and whether it applies the scrub. If the `.unknown` branch also scrubs, the impact is misclassification only; if not, it is a path leak. Either way the fix is the same.

Tests: `swift/Tests/iMessageMaxTests/AppleScriptRunnerValidationTests.swift:51,68,81,91,104` test `classifySendStderr`; none passes a `/Users/` string.

### diagnose leaks

`swift/Sources/iMessageMax/Tools/Diagnose.swift:114`: `let databasePath = Database.defaultPath` and `:295` `path: databasePath` puts the absolute path in the response. `:142`: `contactsFix` interpolates `error.localizedDescription`.

`swift/Sources/iMessageMax/Utilities/ClientErrorMessages.swift` provides `sanitized(_:)` (strips local paths) and `internalDetail(_:context:)`. Read both before using.

`diagnose` is the tool the operator runs to debug their own setup, so a path is *useful* there. The compromise: show the path with the home directory replaced by `~` (`(path as NSString).abbreviatingWithTildeInPath`), which keeps it actionable without the username.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | `Build complete!` |
| Focused | `cd swift && swift test --filter "GetMessagesToolTests|AppleScriptRunnerValidationTests|DiagnoseToolTests|ClientErrorMessagesTests"` | 0 failures |
| Whole suite | `cd swift && swift test` | 0 failures |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Tools/GetMessagesInternals.swift` (`parseChatId` only)
- `swift/Sources/iMessageMax/Utilities/AppleScript.swift` (`classifySendStderr` only)
- `swift/Sources/iMessageMax/Tools/Diagnose.swift` (lines 114, 142, 295 area)
- `swift/Tests/iMessageMaxTests/AppleScriptRunnerValidationTests.swift`, `GetMessagesToolTests.swift`, `DiagnoseToolTests.swift` (add tests; create `DiagnoseToolTests.swift` if absent)

**Out of scope** (do NOT touch, even though they look related):
- Unifying the seven chat-id parsers — plan 054.
- The staging-directory cleanup and transfer-poll paths in `AppleScript.swift:376-446` — plan 050.
- The Makefile `add-trusted-cert` target — by design, rejected finding.
- Outbound `file_paths` containment (restricting attachments to allowed directories) — recorded as an operator option in `plans/README.md`, not planned.

## Git workflow

- Branch: `advisor/049-security-hygiene`
- Commits: `fix: escape LIKE wildcards in the get_messages chat GUID fallback`; `fix: match /users/ after lowercasing in classifySendStderr`; `fix: keep the home directory out of diagnose output`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: LIKE escaping, test first

In `GetMessagesToolTests.swift` add `testChatIdWildcardDoesNotMatchEveryChat`: fixture with two chats whose GUIDs are `iMessage;-;+15550000001` and `iMessage;-;+15550000002`; call `get_messages` with `chat_id: "%"`. At `61e75d9` this returns messages from chat 1. Assert the response is the "chat not found" error (find the exact error code string in `GetMessages.swift`; it is likely `chat_not_found`). Add `testChatIdLiteralPercentInGuidStillMatches` with a chat GUID containing a literal `%` if the fixture allows (skip this one if `insertChat` validates GUIDs).

Fix `parseChatId`:

```swift
let rows = try db.query(
    "SELECT ROWID FROM chat WHERE guid LIKE ? ESCAPE '\\' LIMIT 1",
    ["%\(escapeLike(chatId))%"]
)
```

Use the real `escapeLike` signature. Also reject empty or wildcard-only input before querying: `guard !chatId.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }`.

**Verify**: new test fails before the fix, passes after; `swift test --filter GetMessagesToolTests` → 0 failures.

### Step 2: stderr classifier

In `AppleScriptRunnerValidationTests.swift` add `testHomeDirectoryPathInStderrClassifiesAsPathRejected` passing a string like `"execution error: Messages got an error: Can’t get file \"/Users/alice/Pictures/imessage-max-staging/x.jpg\". (-1728)"` and asserting `.attachmentPathRejected` (use the enum case name that line 519 actually returns). At `61e75d9` it returns the fallback case.

Fix line 519: `if lowered.contains("/users/")`. Read lines 478-525 once more for any other mixed-case literal compared against `lowered` (`/private/`, `/var/` are already lowercase; check for `Library`, `Pictures`, `Messages` in capitalized form and lowercase them too).

Then read the caller branch for the `.unknown` case (around `:543-560`) and confirm the scrub function from `:337-346` is applied to every branch that puts stderr text into the client-visible message. If a branch skips the scrub, apply it there too and add a test asserting the formatted failure message contains no `/Users/`.

**Verify**: `swift test --filter AppleScriptRunnerValidationTests` → 0 failures; the new test passes.

### Step 3: diagnose

`Diagnose.swift:114`: keep `databasePath` for the file checks, but where it is placed in the response (`:295`) use `(databasePath as NSString).abbreviatingWithTildeInPath`. `:142`: replace `error.localizedDescription` with `ClientErrorMessages.sanitized(error.localizedDescription)` (or `internalDetail`, whichever the file's doc comment says is for client-visible text).

Add `DiagnoseToolTests.testResponseDoesNotContainHomeDirectory` (create the file if absent; construct the tool the way other tool tests do): run `diagnose` and assert the JSON string does not contain `NSHomeDirectory()`. If `diagnose` cannot run without Full Disk Access in the test environment, assert on whatever partial response it returns; the assertion is about absence, so a permission-denied response is still a valid check.

**Verify**: `swift test --filter DiagnoseToolTests` → 0 failures.

### Step 4: Full suite

**Verify**: `cd swift && swift test` → 0 failures.

## Test plan

- `GetMessagesToolTests` +1 (wildcard chat_id), optional +1 (literal percent).
- `AppleScriptRunnerValidationTests` +1 (home path classifies correctly), optional +1 (formatted message scrubbed).
- `DiagnoseToolTests` +1 (no home directory in output).

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` → 0 failures
- [ ] `grep -n "LIKE ? LIMIT 1" swift/Sources/iMessageMax/Tools/GetMessagesInternals.swift` → no matches; `grep -n "ESCAPE '\\\\\\\\'" swift/Sources/iMessageMax/Tools/GetMessagesInternals.swift` → one match
- [ ] `grep -n 'contains("/Users/")' swift/Sources/iMessageMax/Utilities/AppleScript.swift` → no matches inside `classifySendStderr` (the correct-case scrub at ~`:337` may keep its own literal)
- [ ] `grep -n "abbreviatingWithTildeInPath" swift/Sources/iMessageMax/Tools/Diagnose.swift` → one match
- [ ] `grep -n "error.localizedDescription" swift/Sources/iMessageMax/Tools/Diagnose.swift` → no unsanitized match
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The `.unknown` branch in Step 2 turns out to bypass the scrub *and* fixing it requires restructuring the failure-formatting function beyond a one-line call. Report the structure.
- `diagnose` output is consumed by the Makefile `verify` or `status` targets in a way that parses the absolute path (`grep -n "path" swift/Makefile`). If so, keep the absolute path under a separate key and abbreviate only the human-facing one.

## Maintenance notes

- Every `LIKE ?` in `swift/Sources` must have `ESCAPE '\\'` and a bound value built with `escapeLike`. A reviewer can enforce this with `grep -rn "LIKE ?" swift/Sources | grep -v ESCAPE` → must be empty after this plan.
- `classifySendStderr` compares against a lowercased string; every literal in it must be lowercase. A test that feeds a mixed-case path is the guard.
