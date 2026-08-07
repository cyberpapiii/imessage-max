# Plan 039: Manual-validation refresh for the full send vocabulary, plus AppleScript error hygiene round 3

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report, do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 0ff6b8f..HEAD -- swift/Sources/iMessageMax/Utilities/AppleScript.swift swift/Sources/iMessageMax/Utilities/ClientErrorMessages.swift swift/Tests/iMessageMaxTests/SendManualValidation.md`
> Expected: empty. If `AppleScript.swift` has changed, re-run the
> `localizedDescription` grep in Step 4 and work from the line numbers it
> reports, not the ones written here.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW (one doc file, one additive helper, four one-line call-site swaps)
- **Depends on**: nothing
- **Category**: docs + tech debt
- **Planned at**: commit `0ff6b8f`, 2026-08-07

## Why this matters

Two pieces of deferred debt, both small, both from the same round of work.

**Part A, the manual-validation doc is three plans behind.**
`swift/Tests/iMessageMaxTests/SendManualValidation.md` is the human checklist
run against a real iMessage account before trusting a send change. Its
vocabulary section is still titled "Verified-Send Proof Vocabulary (Plan
012)" and covers only `confirmed` / `uncertain` / `mismatch`. Since then:

- Plan 021 added `failed_delivery`, chat.db recorded a delivery error; the
  message was **not** delivered. This is the single most consequential status
  in the vocabulary (an agent that misreads it tells the user a message was
  sent when it wasn't) and it has no manual check.
- Plan 026 added `partial_failure`, some payloads dispatched before a later
  one failed, with explicit "do not blind-retry" guidance. No manual check.
- Plan 024 added staged-file cleanup: outgoing attachments are copied into
  `~/Pictures/imessage-max-staging/<uuid>/` and the directory is removed
  after the transfer completes. Nothing in the checklist verifies staging
  actually gets cleaned up, so a leak would go unnoticed indefinitely.

The section numbering has also drifted out of order, sections appear as
1, 2, 3, 4, 5, 6, 9, 10, 11, 7, 8 down the page, because plan 012's additions
were numbered 9-11 and inserted above the pre-existing 7-8.

**Part B, four residual raw-error leaks in AppleScript.swift.**
Plan 006 and plan 023 routed client-facing error strings through
`ClientErrorMessages.sanitized`, which keeps filesystem paths in the server
log and out of client responses. Four sites in `AppleScript.swift` were never
converted and still return `error.localizedDescription` straight to the
client:

```
$ cd swift && grep -n "localizedDescription" Sources/iMessageMax/Utilities/AppleScript.swift
221:            return .failure(.failed(error.localizedDescription))
246:            return .failure(.failed(error.localizedDescription))
378:                return .failure(.failed(error.localizedDescription))
572:            return .failure(.failed(error.localizedDescription))
```

Lines 221 and 246 catch failures from `prepareTrackedOutgoingFile`, whose
`FileManager.createDirectory` / `copyItem` errors embed the staging path,
`/Users/<username>/Pictures/imessage-max-staging/<uuid>/...`. That is the same
class of leak plan 023 fixed for database paths: an internal absolute path,
containing the operator's username, handed to whatever client called `send`.
Line 572 leaks process-launch detail; line 378 leaks AppleScript query
internals.

## Current state

### The existing sanitizer (`swift/Sources/iMessageMax/Utilities/ClientErrorMessages.swift`)

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

**Read that last sentence of the doc comment carefully: "All other errors
pass through unchanged."** The four `AppleScript.swift` sites throw
`CocoaError`/`NSError`, not `DatabaseError`. Swapping them to
`ClientErrorMessages.sanitized(error)` would change **nothing**, the path
would still leak. That is why this plan adds a second helper rather than
reusing `sanitized`.

### The four call sites

`swift/Sources/iMessageMax/Utilities/AppleScript.swift:213-222` (and the
near-identical block at 238-247 for the chat-guid variant):

```swift
        let preparedFile: PreparedOutgoingFile
        do {
            preparedFile = try prepareTrackedOutgoingFile(sourcePath: filePath)
        } catch let error as SendError {
            return .failure(error)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
```

`swift/Sources/iMessageMax/Utilities/AppleScript.swift:373-379`, inside
`waitForTransferCompletion`:

```swift
            } catch let error as SendError {
                return .failure(error)
            } catch {
                return .failure(.failed(error.localizedDescription))
            }
```

`swift/Sources/iMessageMax/Utilities/AppleScript.swift:564-573`, the tail of
the process runner:

```swift
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
```

Note the `catch let error as SendError { return .failure(error) }` clauses
above three of the four. Those are already client-safe, `SendError` carries
authored messages. **Do not touch them.** Only the bare `catch` arms change.

### Staging paths (`swift/Sources/iMessageMax/Utilities/AppleScript.swift:281-291, 397-412`)

```swift
    private static func stagingRootDirectory() -> URL {
        let picturesDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)
        return picturesDirectory.appendingPathComponent("imessage-max-staging", isDirectory: true)
    }
```

`removeStagedDirectory(for:)` deletes the per-send UUID directory, guarded so
it can only ever delete inside that root. This is what Part A's new check 14
verifies by hand.

### The status constructors (`swift/Sources/iMessageMax/Tools/Send.swift:130-180`)

```swift
    /// Row found in the intended chat with error ≠ 0 — delivery failed (verified).
    static func failedDelivery(guid: String, errorCode: Int, deliveredTo: [String], chat: ChatReference?) -> SendResponse {
        SendResponse(
            status: "failed_delivery",
            ...
            message: "Messages.app accepted the send but chat.db recorded a delivery failure (error \(errorCode)). The message was NOT delivered. Do not tell the user it was sent; check the destination can receive iMessages and consider resending.",
            ...
            verifiedMessageGuid: guid,
```

```swift
    /// Some payloads were dispatched to Messages.app before a later payload failed.
    static func partialFailure(
        sentDescriptions: [String], failedDescription: String, error: String,
        deliveredTo: [String], chat: ChatReference?
    ) -> SendResponse {
        SendResponse(
            status: "partial_failure",
            ...
            message: "PARTIAL SEND: \(sentDescriptions.joined(separator: ", ")) already dispatched to Messages.app (not verified) before \(failedDescription) failed. Do NOT resend the already-dispatched payload(s); retry only the failed one.",
```

Use these as the source of truth for what the doc's "Expected" bullets say.
Do not paraphrase the guidance loosely, the whole point of `failed_delivery`
is that an agent must not report success.

## Steps

### Part A, the manual-validation doc

#### Step 1, Renumber the existing sections into document order

In `swift/Tests/iMessageMaxTests/SendManualValidation.md`, the headings
currently read, top to bottom:

```
### 1. Send text to a 1:1 contact
### 2. Send text to an exact group chat
### 3. Send an attachment to a 1:1 contact
### 4. Send attachment plus text to an exact group chat
### 5. Missing attachment path
### 6. Unsupported reply-to
### 9. Confirmed delivery to a known 1:1 contact
### 10. Uncertain — send to address with no prior chat.db row
### 11. Mismatch — message lands in a different chat
### 7. Existing image attachment variants
### 8. Offloaded attachment
```

Renumber so the numbers ascend down the page: the three vocabulary checks
become 7, 8, 9 and the two attachment spot checks become 10, 11. Change the
numbers only, leave every heading's title text and every body paragraph
exactly as written.

Then grep the whole repo for cross-references to the old numbers and update
any that exist:

```bash
cd swift && grep -rn "SendManualValidation" --include="*.md" --include="*.swift" .. | grep -v "^\.\./swift/Tests/iMessageMaxTests/SendManualValidation.md"
```

If a hit references a specific check number, update it. If none do, note that.

**Verify**:

```bash
cd swift && grep -n '^### ' Tests/iMessageMaxTests/SendManualValidation.md
```

Expected: eleven headings, numbered 1 through 11 in ascending order.

#### Step 2, Retitle the vocabulary section and add the two missing statuses

Change the section heading

```
## Verified-Send Proof Vocabulary (Plan 012)
```

to

```
## Verified-Send Proof Vocabulary
```

and rewrite its two-line intro so it names the full current vocabulary rather
than plan 012's subset. The complete set of `status` values the `send` tool
can return, from `swift/Sources/iMessageMax/Tools/Send.swift`:
`confirmed`, `uncertain`, `mismatch`, `failed_delivery`, `partial_failure`,
`sent`, `pending_confirmation`, `ambiguous`, `failed`.

Then append two new checks at the end of that section (they become 10 and 11,
pushing the attachment spot checks to 12 and 13, re-apply Step 1's ascending
rule after inserting):

**`### N. Failed delivery, chat.db records a delivery error`**

How to provoke it: send to a handle that Messages.app will accept but cannot
deliver to, the reliable case is an iMessage-only send to a number with no
iMessage registration while SMS fallback is unavailable. Messages.app shows
the red "Not Delivered" badge and chat.db writes a non-zero `error` on the row.

Expected bullets:

- `status` is `failed_delivery`
- `verified_message_guid` is a non-empty string, the row **was** found
- `message` states the message was NOT delivered and names the error code
- The agent must not report this as a successful send
- Messages.app shows the send as not delivered

**`### N+1. Partial failure, multi-payload send fails partway`**

How to provoke it: call `send` with both `text` and `file_paths`, where the
text will dispatch fine and the attachment will not, for example a
a `file_paths` entry pointing at a file that exists at validation time but is
unreadable when the transfer starts, or an oversized file the transfer
rejects.

Expected bullets:

- `status` is `partial_failure`
- `message` begins `PARTIAL SEND:` and names which payload was dispatched and
  which failed
- `message` says explicitly not to resend the already-dispatched payload
- The text is visible in the conversation; the attachment is not
- Re-running the same call blind would duplicate the text, confirm the
  response makes that obvious

#### Step 3. Add the staging-cleanup check

Append a new check to the **Attachment Spot Checks** section:

**`### N. Staged outgoing file is cleaned up`**

Steps to write into the doc:

1. Before the send: `ls ~/Pictures/imessage-max-staging/ 2>/dev/null`, note
   what is there (an empty or missing directory is the normal state).
2. Send an attachment to a 1:1 contact and wait for the response.
3. After the response: `ls ~/Pictures/imessage-max-staging/` again.

Expected bullets:

- During the send, a UUID-named subdirectory exists containing a copy of the
  file under its original name
- After the send completes, that subdirectory is gone
- No accumulation across repeated sends, the directory count does not grow
- The original source file is untouched (the staging copy is a copy, never
  a move)

**Verify Part A**:

```bash
cd swift && grep -c 'failed_delivery\|partial_failure\|imessage-max-staging' Tests/iMessageMaxTests/SendManualValidation.md
```

Expected: at least `3`.

```bash
cd swift && grep -n '^### ' Tests/iMessageMaxTests/SendManualValidation.md
```

Expected: fourteen headings, numbered 1 through 14 ascending (11 originally,
plus 2 from Step 2 and 1 from Step 3).

```bash
cd swift && grep -c 'Plan 012' Tests/iMessageMaxTests/SendManualValidation.md
```

Expected: `0`.

Leave the `## Real-machine validation run, 2026-06-11` section at the bottom
untouched, it is a historical record of a run that happened, not a checklist.
Do **not** mark the new checks as passed; nobody has run them.

### Part B, error hygiene

#### Step 4. Add an internal-error helper to `ClientErrorMessages`

Append to `swift/Sources/iMessageMax/Utilities/ClientErrorMessages.swift`,
inside the existing `enum ClientErrorMessages`:

```swift
    /// Client-safe rendering of an error that may embed internal filesystem
    /// paths — staged-attachment directories, tool binaries, temp files.
    /// Unlike `sanitized`, this never passes the underlying description
    /// through: the detail goes to stderr for the operator and the client
    /// gets a fixed string plus the caller-supplied context.
    ///
    /// Use this at `catch` sites whose errors come from FileManager, Process,
    /// or AppleScript execution. Use `sanitized` when the error may be a
    /// `DatabaseError` and its guidance strings are what the client needs.
    static func internalDetail(_ error: Error, context: String) -> String {
        FileHandle.standardError.write(
            Data("[imessage-max] \(context): \(error.localizedDescription)\n".utf8)
        )
        return "\(context) failed. Check the server log for details."
    }
```

Do not modify `sanitized`, 19 call sites depend on its current behavior.

**Verify**:

```bash
cd swift && swift build 2>&1 | tail -5
```

#### Step 5, Convert the four call sites

Re-run the grep first and work from its live line numbers:

```bash
cd swift && grep -n "localizedDescription" Sources/iMessageMax/Utilities/AppleScript.swift
```

Replace each `return .failure(.failed(error.localizedDescription))` with a
call carrying a context string that names the operation:

| Site | Enclosing operation | `context` argument |
|---|---|---|
| ~221 | staging the outgoing file, handle variant | `"Preparing the attachment"` |
| ~246 | staging the outgoing file, chat-guid variant | `"Preparing the attachment"` |
| ~378 | polling for transfer completion | `"Checking attachment transfer status"` |
| ~572 | running the AppleScript process | `"Running AppleScript"` |

e.g.

```swift
        } catch {
            return .failure(.failed(ClientErrorMessages.internalDetail(error, context: "Preparing the attachment")))
        }
```

Leave every `catch let error as SendError { return .failure(error) }` clause
exactly as it is.

**Verify**:

```bash
cd swift && grep -c "localizedDescription" Sources/iMessageMax/Utilities/AppleScript.swift
```

Expected: `0`.

```bash
cd swift && grep -c "ClientErrorMessages.internalDetail" Sources/iMessageMax/Utilities/AppleScript.swift
```

Expected: `4`.

#### Step 6. Add tests for the new helper

Add to the existing suite
`swift/Tests/iMessageMaxTests/ClientErrorSanitizationTests.swift` (which
already covers `sanitized`; follow its structure and naming). Two tests:

1. `testInternalDetailNeverEchoesTheUnderlyingDescription`, build an
   `NSError` whose `localizedDescription` contains a distinctive fake path
   such as `/Users/testuser/Pictures/imessage-max-staging/abc/photo.jpg`,
   pass it through `internalDetail(_:context:)`, and assert the returned
   string does **not** contain `imessage-max-staging`, does not contain
   `/Users/`, and does contain the context string.
2. `testInternalDetailReturnsStableGuidance`, assert the returned string
   ends with `failed. Check the server log for details.` so the wording is
   pinned against accidental drift.

**Verify**:

```bash
cd swift && swift test --filter ClientErrorSanitizationTests 2>&1 | tail -10
```

Expected: all pass, count 2 higher than before.

### Step 7, Full suite

```bash
cd swift && swift build && swift test 2>&1 | tail -20
```

Expected: `Executed 235 tests, with 0 failures` (233 at `0ff6b8f` + 2 new).
If the baseline is not 233, report the actual numbers rather than adjusting
the plan's arithmetic to match.

## Done criteria

1. `cd swift && swift build`, exits 0, no new warnings.
2. `cd swift && swift test 2>&1 | grep -E 'Executed [0-9]+ tests' | tail -1`, `Executed 235 tests, with 0 failures`. (`tail -3` shows the swift-testing trailer, not the XCTest count, this package runs both.)
3. `cd swift && grep -c "localizedDescription" Sources/iMessageMax/Utilities/AppleScript.swift`, `0`.
4. `cd swift && grep -c "ClientErrorMessages.internalDetail" Sources/iMessageMax/Utilities/AppleScript.swift`, `4`.
5. `cd swift && grep -c "Plan 012" Tests/iMessageMaxTests/SendManualValidation.md`, `0`.
6. `cd swift && grep -n '^### ' Tests/iMessageMaxTests/SendManualValidation.md`, fourteen headings, numbered 1-14 ascending with no gaps or repeats.
7. `cd swift && grep -c "failed_delivery" Tests/iMessageMaxTests/SendManualValidation.md`, at least `1`.
8. `cd swift && grep -c "partial_failure" Tests/iMessageMaxTests/SendManualValidation.md`, at least `1`.
9. `cd swift && grep -c "imessage-max-staging" Tests/iMessageMaxTests/SendManualValidation.md`, at least `1`.
10. `git diff --stat`, exactly four files (see "Files in scope").

## Files in scope

- `swift/Tests/iMessageMaxTests/SendManualValidation.md`
- `swift/Sources/iMessageMax/Utilities/ClientErrorMessages.swift`, the new helper only
- `swift/Sources/iMessageMax/Utilities/AppleScript.swift`, the four bare `catch` arms only
- `swift/Tests/iMessageMaxTests/ClientErrorSanitizationTests.swift`, two new tests

## Files explicitly out of scope

- `swift/Sources/iMessageMax/Tools/Send.swift`, the status vocabulary is
  correct as shipped; this plan documents it, it does not change it.
- Every existing `ClientErrorMessages.sanitized` call site (19 of them across
  `Sources/iMessageMax/Tools/`). Do not "upgrade" them to `internalDetail`,
  they handle `DatabaseError` and need its guidance strings.
- `sanitized` itself.
- The `## Real-machine validation run, 2026-06-11` section of the doc.
- `swift/Tests/iMessageMaxTests/AppleScriptRunnerValidationTests.swift`.

## Test plan

Two new unit tests in
`swift/Tests/iMessageMaxTests/ClientErrorSanitizationTests.swift`, following
the structure of the tests already in that file. What they must actually
assert, a test that only checks the return value is non-empty does not
satisfy this plan:

| Test | Asserts |
|---|---|
| `testInternalDetailNeverEchoesTheUnderlyingDescription` | result excludes `imessage-max-staging`, excludes `/Users/`, includes the context string |
| `testInternalDetailReturnsStableGuidance` | result ends with `failed. Check the server log for details.` |

Part A has no automated test, it is a human checklist. Its verification is
the grep-based done criteria 5-9, which confirm the content exists; whether
the checks pass on real hardware is for the operator to run.

## STOP conditions

- Any existing test fails. Part B only changes the *text* of error strings on
  four failure paths; if a test asserts on one of those strings, report which
  and stop, the reviewer decides whether the test or the message is wrong.
- The `localizedDescription` grep in Step 4 returns a count other than 4, or
  returns lines whose surrounding code does not match the excerpts above.
- Any of the four sites turns out to be reachable on a success path rather
  than a `catch` arm.
- The `swift test` baseline at the start of your work is not 233.
- Cross-references to `SendManualValidation.md` check numbers exist in files
  outside `swift/Tests/` that you cannot update within scope.

## Maintenance note

The coupling to watch: **every new `status` value added to
`swift/Sources/iMessageMax/Tools/Send.swift` needs a matching check in
`SendManualValidation.md`.** That link has now been missed three times
(plans 021, 024, 026), which is why this plan exists at all. In review of any
future send change, if a new `SendResponse` constructor appears and the
manual-validation doc is untouched, that is the defect.

For Part B, the durable rule is the split between the two helpers:
`sanitized` for errors that may be `DatabaseError` and whose mapped guidance
the client needs; `internalDetail` for FileManager/Process/AppleScript errors
where the client needs nothing but the operator needs the log line. A new
`catch` arm in `AppleScript.swift` that reaches for `error.localizedDescription`
directly should not pass review, done criterion 3 pins that count at zero,
so it will also show up as a regression if anyone re-runs it.
