# Plan 023: Client error hygiene round 2, stop leaking paths and raw stderr

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report, do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat e3d14da..HEAD -- swift/Sources/iMessageMax/Database/Errors.swift swift/Sources/iMessageMax/Utilities/AppleScript.swift swift/Sources/iMessageMax/Utilities/ClientErrorMessages.swift swift/Sources/iMessageMax/Tools/GetAttachment.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW-MED (error-string changes can break tests that assert on messages)
- **Depends on**: none. **Ordering**: plan 021 also edits `Send.swift`; land
  021 first, then rebase this. Plan 024/025 edit `AppleScript.swift`; land
  this before them (this plan's edits are small and theirs are structural).
- **Category**: security
- **Planned at**: commit `e3d14da`, 2026-08-07

## Why this matters

A prior hygiene pass (plan 006) created `ClientErrorMessages` so tool errors
sent to MCP clients say *what to do* without echoing internal state. Round 2
closes the gaps that pass missed. MCP client responses end up in agent
context windows, transcripts, and third-party logs, so anything interpolated
into them should be treated as published:

1. **`DatabaseError` interpolates filesystem paths** into
   `errorDescription`, and ~14 tool catch-all handlers forward
   `error.localizedDescription` verbatim to the client. A permission failure
   leaks `/Users/<name>/Library/Messages/chat.db` (the local username) to
   every connected client.
2. **Raw `osascript` stderr** is forwarded on unrecognized send failures
   (`SendError.failed(stderr)` → "Send failed: \<stderr\>"). AppleScript
   error text can include local paths, staged filenames, and script
   internals, unbounded in length.
3. **The staged temp-file path is echoed** on file-not-found sends
   (`.fileNotFound(arguments.last ?? "")` reports the private staging path,
   not the file the caller asked to send).
4. **`get_attachment` returns the absolute attachment path** in the
   `details` of the iCloud-offload error, leaking the home directory,
   inconsistent with its own siblings, which pass `details: nil`.

## Current state

### The sanitized-message utility (extend this)

`swift/Sources/iMessageMax/Utilities/ClientErrorMessages.swift` (entire file):

```swift
enum ClientErrorMessages {
    static let databaseNotFound = "iMessage database not found. Run the diagnose tool for setup help."
    static let permissionDenied = "Cannot read the iMessage database (Full Disk Access may be missing). Run the diagnose tool."
    static let internalError = "Internal error. Check the server log for details."
}
```

### Leak 1, DatabaseError paths

`swift/Sources/iMessageMax/Database/Errors.swift` (entire file):

```swift
enum DatabaseError: LocalizedError {
    case permissionDenied(String)
    case notFound(String)
    case queryFailed(String)
    case invalidData(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let path):
            return "Permission denied accessing \(path). Grant Full Disk Access in System Settings."
        case .notFound(let path):
            return "Database not found at \(path). Ensure iMessage is set up."
        case .queryFailed(let msg):
            return "Query failed: \(msg)"
        case .invalidData(let msg):
            return "Invalid data: \(msg)"
        }
    }
}
```

The forwarding sites (all pass `error.localizedDescription` into a
client-visible error payload). Full list as of `e3d14da`, confirm with
`grep -rn "localizedDescription" swift/Sources --include="*.swift"`:

- `Tools/GetMessages.swift:198`
- `Tools/FindChat.swift:241`
- `Tools/GetContext.swift:479` and `:485`
- `Tools/GetActiveConversations.swift:129`
- `Tools/GetChatDetails.swift:147`
- `Tools/GetAttachment.swift:272` and `:279`
- `Tools/ListChats.swift:330`
- `Tools/Search.swift:438`
- `Tools/GetUnread.swift:133`
- `Tools/ListAttachments.swift:211`
- `Tools/SendResolution.swift:89`, `:142`, `:170`, `:197` (wrapped as
  `"Database error: \(...)"`)
- `Tools/Send.swift:357` and `:359` (these forward `SendError`, which is
  deliberately client-facing, see Step 2's routing rule)
- `Tools/Diagnose.swift:154`, **leave as-is** (see Scope)
- `Server/ModernProtocol.swift:225`, `Server/ServerExtensions.swift:239`,
  generic `"Error: \(...)"` wrappers around tool errors; **leave as-is**
  (tool-level sanitization below is what feeds them)

### Leak 2 + 3, send stderr and staged path

`swift/Sources/iMessageMax/Utilities/AppleScript.swift`. The stderr
interpretation block (`:420-451`):

```swift
                if stderr.contains("no such file") ||
                    stderr.contains("file") && stderr.contains("wasn’t found") ||
                    stderr.contains("file") && stderr.contains("wasn't found")
                {
                    return .failure(.fileNotFound(arguments.last ?? ""))
                }

                if stderr.contains("can't get participant") ||
                    stderr.contains("can't get chat") ||
                    stderr.contains("doesn't understand") ||
                    stderr.contains("invalid key form")
                {
                    return .failure(missingTargetError)
                }

                return .failure(.failed(stderr))
```

Context: `arguments.last` at this point is the **staged copy** of the
outgoing file (a private temp path created by `prepareOutgoingFile`,
`:237-258`), not the caller's original path. The `SendError` descriptions
(`:47-91`) render `.fileNotFound(path)` as `"Could not read file at '\(path)'."`
and `.failed(message)` as `"Send failed: \(message)"`.

There are also four catch sites converting thrown errors to
`.failed(error.localizedDescription)` at `AppleScript.swift:199`, `:221`,
`:348`, `:500`, these are process-launch failures (our own error text, no
untrusted stderr); leave them.

### Leak 4, attachment offload path

`swift/Sources/iMessageMax/Tools/GetAttachment.swift:189-196`:

```swift
                if let downloaded = await tryDownloadFromiCloud(url: fileURL) {
                    if !downloaded {
                        return .error(
                            type: "attachment_offloaded",
                            message: "Attachment is stored in iCloud and download was triggered. Try again in a few seconds.",
                            details: ["path": expandedPath]
                        )
                    }
```

(Sibling error returns in the same function all use `details: nil`, see
`:168-183`, `:198-203`.)

### Logging precedent

Stderr logging in this repo is
`FileHandle.standardError.write(Data("...".utf8))`, see `MCPServer.swift:46`
and `HTTPTransport.swift:259` for the shape.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| Full suite | `cd swift && swift test` | exit 0, 0 failures |
| Leak grep | `grep -rn "localizedDescription" swift/Sources/iMessageMax/Tools --include="*.swift"` | only `Diagnose.swift:154` and `Send.swift` SendError sites remain |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Utilities/ClientErrorMessages.swift`
- `swift/Sources/iMessageMax/Database/Errors.swift` (additive only)
- `swift/Sources/iMessageMax/Utilities/AppleScript.swift` (the two lines cited)
- `swift/Sources/iMessageMax/Tools/GetAttachment.swift` (the one `details` value + its two catch-alls)
- The tool catch-all sites listed under Leak 1 (one-line swaps)
- Test files that assert on the changed messages (adjust assertions; add new tests)
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):
- `Tools/Diagnose.swift:154`, diagnose is the *designated* diagnostic
  surface; its whole purpose is detail. Deliberately unchanged.
- `Server/ModernProtocol.swift:225` / `Server/ServerExtensions.swift:239`,
  generic wrappers; plan 030 owns ModernProtocol changes.
- `AppleScript.swift:199/:221/:348/:500` (our own launch-failure text) and
  all of its process/staging structure, plans 024/025 own that.
- `SendError.errorDescription` texts other than what Step 3 specifies.
- Log files/logging infrastructure beyond the one helper call.

## Git workflow

- Branch: `advisor/023-client-error-hygiene-round-2`
- Conventional commits, e.g. `fix: sanitize database paths and osascript stderr out of client errors`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add the sanitizer seam

In `ClientErrorMessages.swift`, add:

```swift
import Foundation

enum ClientErrorMessages {
    static let databaseNotFound = "iMessage database not found. Run the diagnose tool for setup help."
    static let permissionDenied = "Cannot read the iMessage database (Full Disk Access may be missing). Run the diagnose tool."
    static let internalError = "Internal error. Check the server log for details."

    /// Client-safe rendering of an arbitrary error. DatabaseError carries
    /// filesystem paths in its description (useful in logs, not for clients);
    /// map it to the fixed guidance strings and log the detailed form to
    /// stderr. All other errors pass through unchanged.
    static func sanitized(_ error: Error) -> String {
        guard let dbError = error as? DatabaseError else {
            return error.localizedDescription
        }
        FileHandle.standardError.write(
            Data("[imessage-max] database error: \(dbError.localizedDescription)\n".utf8)
        )
        switch dbError {
        case .permissionDenied: return permissionDenied
        case .notFound: return databaseNotFound
        case .queryFailed, .invalidData: return internalError
        }
    }
}
```

Do not change `Errors.swift`'s descriptions, they are the log-side detail.

**Verify**: `cd swift && swift build` → exit 0.

### Step 2: Route the tool catch-alls through it

At every Leak-1 site listed above **except** `Diagnose.swift:154` and
`Send.swift:357/:359`, replace `error.localizedDescription` with
`ClientErrorMessages.sanitized(error)`. For the `SendResolution.swift` sites,
replace the whole interpolation: `"Database error: \(error.localizedDescription)"`
→ `ClientErrorMessages.sanitized(error)` (the "Database error:" prefix added
no information beyond what the sanitized constants say).

`Send.swift:357/:359` forward `SendError`, whose descriptions are
deliberately client-facing; `sanitized` passes non-DatabaseError through
unchanged, so routing them through it is also correct, do so for uniformity
**only if** plan 021 has already landed (avoiding conflict churn); otherwise
leave those two lines alone and note it in the commit message.

**Verify**: `cd swift && swift build` → exit 0, then the leak grep from the
commands table.

### Step 3: Fix the send-path leaks

In `AppleScript.swift`:

1. Line 439: `return .failure(.fileNotFound(arguments.last ?? ""))` →

```swift
                    return .failure(.fileNotFound(
                        ((arguments.last ?? "") as NSString).lastPathComponent
                    ))
```

   The description then reads "Could not read file at 'IMG_0231.heic'.",
   the filename identifies the problem file without exposing the private
   staging directory.

2. Line 450: `return .failure(.failed(stderr))` →

```swift
                // Untrusted, unbounded osascript stderr: keep the first line,
                // clamped, so client errors stay informative but bounded.
                let firstLine = stderr.split(separator: "\n", maxSplits: 1)[0]
                return .failure(.failed(String(firstLine.prefix(300))))
```

   (Guard the empty-stderr case: `stderr.split` on an empty string yields an
   empty array, use `stderr.split(...).first ?? ""`.)

**Verify**: `cd swift && swift build` → exit 0.

### Step 4: Fix the attachment offload detail

`GetAttachment.swift:194`: `details: ["path": expandedPath]` →
`details: ["filename": fileURL.lastPathComponent]`. Also route the two
catch-alls at `:272`/`:279` through `ClientErrorMessages.sanitized(error)`
(they are in the Leak-1 list).

**Verify**: `cd swift && swift build` → exit 0.

### Step 5: Tests

Add `ClientErrorSanitizationTests.swift` in
`swift/Tests/iMessageMaxTests/` (plain XCTest, no fixture needed):

1. `sanitized(DatabaseError.permissionDenied("/Users/x/Library/Messages/chat.db"))`
   returns `ClientErrorMessages.permissionDenied` and does not contain `"/Users"`.
2. Same for `.notFound` → `databaseNotFound`; `.queryFailed("boom")` →
   `internalError`.
3. A non-DatabaseError (e.g. `SendError.timeout`) passes through with its
   own description.

For the AppleScript stderr clamp, check
`swift/Tests/iMessageMaxTests/PlaceholderTests.swift` class
`AppleScriptRunnerValidationTests` (starts `:107`) for how runner behavior
is tested; if the stderr-interpretation branch isn't reachable without a
real process run, unit-test the clamp logic only if it was extracted,
otherwise rely on the sanitizer tests and note it.

Then run the full suite; fix any existing test that asserted on the old
message strings **by updating the expected string to the new sanitized
value** (never by weakening the production change).

**Verify**: `cd swift && swift test` → exit 0, 0 failures, ≥3 net-new tests.

## Test plan

Step 5. Exemplar for message-assertion style:
`AttachmentPathContainmentTests.swift:126-132` (asserts an error message does
NOT contain a path, reuse that idiom).

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` exits 0; 0 failures; ≥3 net-new tests
- [ ] `grep -rn "localizedDescription" swift/Sources/iMessageMax/Tools --include="*.swift"` → only `Diagnose.swift` (and `Send.swift` if 021 hadn't landed)
- [ ] `grep -n "details: \[\"path\"" swift/Sources/iMessageMax/Tools/GetAttachment.swift` → no matches
- [ ] `grep -n ".failed(stderr)" swift/Sources/iMessageMax/Utilities/AppleScript.swift` → no matches
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Excerpts don't match live code (drift), or the Leak-1 site list has grown,
  new sites are in scope, but report the delta.
- Any test failure whose fix would require changing `SendError` semantics or
  `Diagnose` output.
- You are tempted to add a logging framework or change how the server logs,
  the single `FileHandle.standardError.write` in the sanitizer is the whole
  logging footprint of this plan.

## Maintenance notes

- Review invariant: **anything interpolated into a client-visible error is
  published**, new tools must route catch-alls through
  `ClientErrorMessages.sanitized` and never embed absolute paths.
- Plans 024/025 restructure `AppleScript.swift`; they must preserve the
  clamped-stderr and lastPathComponent behaviors added here (their plans say
  so, but verify in review).
- If a future debugging need arises for full stderr, the right place is the
  stderr log line (extend the sanitizer's logging), not the client payload.
