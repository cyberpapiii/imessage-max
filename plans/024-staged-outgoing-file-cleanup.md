# Plan 024: Delete staged outgoing-file copies at terminal transfer states

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report, do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat e3d14da..HEAD -- swift/Sources/iMessageMax/Utilities/AppleScript.swift swift/Tests/iMessageMaxTests/PlaceholderTests.swift`
> If either file changed since this plan was written, compare the "Current
> state" excerpts against the live code before proceeding; on a mismatch,
> treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: MED (deleting too early can break an in-flight Messages transfer, the terminal-state rules below are the whole point)
- **Depends on**: none. **Ordering**: plan 023 makes two one-line edits in
  this file (land 023 first); plan 025 makes the send path async (land this
  before 025 so 025 carries the cleanup calls through its restructuring).
- **Category**: security
- **Planned at**: commit `e3d14da`, 2026-08-07

## Why this matters

Every outgoing file send copies the user's file into a staging area under
`~/Pictures/imessage-max-staging/<UUID>/<name>` so Messages.app can read it
and so transfers can be tracked by name. Nothing deletes that copy when the
transfer finishes, cleanup happens only via a 48-hour age sweep that runs
*at the start of the next file send*. Consequences: every photo/document
sent through the tool sits in a duplicate plaintext copy for two days
minimum, indefinitely if no further file sends occur (the sweep never runs
again). That's silent retention of user content beyond its purpose, in a
location (`~/Pictures`) that other apps commonly index and back up. The fix:
delete each per-send staging directory as soon as its transfer reaches a
terminal state, keeping the 48h sweep as the backstop for the non-terminal
cases where deletion is unsafe.

## Current state

All in `swift/Sources/iMessageMax/Utilities/AppleScript.swift`
(`enum AppleScriptRunner`, static functions; blocking/synchronous by design
until plan 025).

The staged-file struct (`:87-91`):

```swift
    struct PreparedOutgoingFile {
        let fileURL: URL
        let trackingName: String
        let existingOutgoingTransferCount: Int
    }
```

The two send entry points, identical shape (`:189-208` participant,
`:211-231` chat), chat version:

```swift
    static func sendFileToChat(guid: String, filePath: String) -> Result<Void, SendError> {
        guard !guid.isEmpty else {
            return .failure(.invalidParams("Chat guid is required"))
        }
        let preparedFile: PreparedOutgoingFile
        do {
            preparedFile = try prepareTrackedOutgoingFile(sourcePath: filePath)
        } catch let error as SendError {
            return .failure(error)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }

        let handoff = run(
            script: sendFileToChatScript,
            arguments: [guid, preparedFile.fileURL.path],
            missingTargetError: .chatNotFound(guid)
        )
        guard case .success = handoff else { return handoff }
        return waitForTransferCompletion(preparedFile: preparedFile)
    }
```

Staging (`:233-258`), note the sweep call at the top and the
per-send UUID directory:

```swift
    static func prepareTrackedOutgoingFile(
        sourcePath: String,
        existingOutgoingTransferStatuses: (String) throws -> [String] = queryOutgoingTransferStatuses
    ) throws -> PreparedOutgoingFile {
        cleanupOldStagedFilesIfPossible()
        ...
        let stagedDirectory = stagingRootDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stagedURL = stagedDirectory.appendingPathComponent(trackingName, isDirectory: false)
        ...
```

The completion wait (`:320-361`), abridged, terminal vs non-terminal
outcomes:

```swift
    private static func waitForTransferCompletion(preparedFile: PreparedOutgoingFile) -> Result<Void, SendError> {
        ...
        while Date() < deadline {
            do {
                ...
                switch observation {
                case .finished:
                    return .success(())                                    // terminal
                case .failed:
                    return .failure(.transferFailed(preparedFile.trackingName))  // terminal
                case .pending: ...
                case .unknown: ...
                }
            } catch let error as SendError {
                return .failure(error)                                     // status query failed — NOT terminal
            } catch {
                return .failure(.failed(error.localizedDescription))       // NOT terminal
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        if sawPending {
            return .failure(.transferPending(preparedFile.trackingName))   // NOT terminal
        }
        ...
        return .failure(.transferStatusUnknown(preparedFile.trackingName)) // NOT terminal
    }
```

The staging root and the 48h sweep (`:363-388`), keep both:

```swift
    private static func stagingRootDirectory() -> URL {
        let picturesDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)
        return picturesDirectory.appendingPathComponent("imessage-max-staging", isDirectory: true)
    }
```

Existing test exemplar,
`swift/Tests/iMessageMaxTests/PlaceholderTests.swift:162-184`
(`testPrepareTrackedOutgoingFileStagesInPicturesDirectoryWithOriginalName`,
in `class AppleScriptRunnerValidationTests`): stages a temp file through the
real staging root with a `defer` cleanup and an injected
`existingOutgoingTransferStatuses` closure. New tests follow this pattern.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| Targeted tests | `cd swift && swift test --filter AppleScriptRunnerValidationTests` | all pass |
| Full suite | `cd swift && swift test` | exit 0, 0 failures |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Utilities/AppleScript.swift`
- `swift/Tests/iMessageMaxTests/PlaceholderTests.swift` (add tests to `AppleScriptRunnerValidationTests`)
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):
- `Thread.sleep` / semaphore / async structure of this file, plan 025.
- Error-message contents (`.failed` clamping etc.), plan 023.
- The AppleScript script bodies (`sendFileToChatScript` etc.).
- `stagingRootDirectory()` location or the 48h sweep window, both stay.

## Git workflow

- Branch: `advisor/024-staged-outgoing-file-cleanup`
- Conventional commits, e.g. `fix: delete staged outgoing files at terminal transfer states`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add a guarded removal helper

In `AppleScriptRunner`, near the staging helpers (`:363`), add:

```swift
    /// Removes one per-send staging directory. Safe only at terminal
    /// transfer states (finished/failed) or before Messages was handed the
    /// file — never while a transfer may still be reading the copy.
    /// Guarded to the staging root so a bug can never delete anything else.
    static func removeStagedDirectory(for preparedFile: PreparedOutgoingFile) {
        let directory = preparedFile.fileURL.deletingLastPathComponent()
        let rootPath = stagingRootDirectory().standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        guard directoryPath.hasPrefix(rootPath + "/"), directoryPath != rootPath else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }
```

(`static`, not `private static`, so tests can call it directly.)

**Verify**: `cd swift && swift build` → exit 0.

### Step 2: Call it at every safe point

Deletion decision table, implement exactly this:

| Outcome | Where | Delete staged copy? |
|---|---|---|
| Handoff to Messages failed (`run` returned failure) | both senders | YES, Messages never got the path |
| `.finished` observed | `waitForTransferCompletion` | YES |
| `.failed` observed | `waitForTransferCompletion` | YES |
| Status query threw / timeout / `.pending` / `.unknown` at deadline | `waitForTransferCompletion` | **NO**, transfer may still be reading the file; 48h sweep is the backstop |
| Staging itself threw | both senders | nothing staged to delete (copy either failed or dir creation failed, a partial dir is swept later; do not add cleanup here) |

Concretely:

1. In `sendFileToParticipant` (`:207`) and `sendFileToChat` (`:229`), change

```swift
        guard case .success = handoff else { return handoff }
```

to

```swift
        guard case .success = handoff else {
            removeStagedDirectory(for: preparedFile)
            return handoff
        }
```

2. In `waitForTransferCompletion`, at the two terminal returns:

```swift
                case .finished:
                    removeStagedDirectory(for: preparedFile)
                    return .success(())
                case .failed:
                    removeStagedDirectory(for: preparedFile)
                    return .failure(.transferFailed(preparedFile.trackingName))
```

Do not add removal to any other return path in that function.

**Verify**: `cd swift && swift build` → exit 0;
`grep -c "removeStagedDirectory" swift/Sources/iMessageMax/Utilities/AppleScript.swift` → 5 (1 definition + 4 calls).

### Step 3: Tests

Add to `AppleScriptRunnerValidationTests` in `PlaceholderTests.swift`,
following the `:162-184` staging pattern (temp source file, injected status
closure, `defer` cleanup as a safety net):

1. `testRemoveStagedDirectoryDeletesOnlyItsOwnDirectory`, stage a file via
   `prepareTrackedOutgoingFile`, assert the staged file exists, call
   `AppleScriptRunner.removeStagedDirectory(for: prepared)`, assert the
   staged file and its UUID directory are gone **and** the staging root
   still exists.
2. `testRemoveStagedDirectoryRefusesPathsOutsideStagingRoot`, build a
   `PreparedOutgoingFile` by hand whose `fileURL` points at a file in a
   fresh temp directory *outside* the staging root; call
   `removeStagedDirectory`; assert the file still exists (the guard
   refused).

The transfer-completion call sites can't be unit-tested without osascript;
they are covered by the decision-table review and the manual validation
note below.

**Verify**: `cd swift && swift test --filter AppleScriptRunnerValidationTests` → all pass, 2 new tests.

### Step 4: Full suite

**Verify**: `cd swift && swift test` → exit 0, 0 failures.

## Test plan

Step 3 (2 new tests). Pattern exemplar: `PlaceholderTests.swift:162-184`.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` exits 0; 0 failures; ≥2 net-new tests
- [ ] `grep -c "removeStagedDirectory" swift/Sources/iMessageMax/Utilities/AppleScript.swift` = 5
- [ ] The `.pending`/`.unknown`/catch/timeout paths in `waitForTransferCompletion` contain NO removal call (read the diff to confirm)
- [ ] `cleanupOldStagedFilesIfPossible` still exists and is still called from `prepareTrackedOutgoingFile`
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Excerpts don't match live code (drift), especially if plan 025 landed
  first and the functions are now async/restructured.
- You are tempted to delete on `.pending`/`.unknown`/timeout "to be
  thorough", that breaks in-flight transfers; the asymmetry is deliberate.
- The staging root or `PreparedOutgoingFile` shape differs from the excerpts.

## Maintenance notes

- **Manual validation (operator action)**: after deploy, send a real file;
  confirm the message delivers AND
  `ls ~/Pictures/imessage-max-staging/` no longer contains that send's UUID
  directory. Add a row to
  `swift/Tests/iMessageMaxTests/SendManualValidation.md`.
- Plan 025 (async send path) restructures these functions, it must carry
  the four removal calls and the decision table forward unchanged; call this
  out in its review.
- If transfer tracking ever gains a post-timeout reconciliation (checking a
  pending transfer later), that path becomes a new safe deletion point.
