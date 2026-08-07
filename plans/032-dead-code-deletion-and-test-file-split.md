# Plan 032: Delete dead model/enrichment code; split PlaceholderTests.swift into per-class files

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report, do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat e3d14da..HEAD -- swift/Sources/iMessageMax/Models swift/Sources/iMessageMax/Enrichment swift/Tests/iMessageMaxTests/PlaceholderTests.swift`
> If any of these changed since this plan was written, re-run the Step 1
> reference checks yourself before deleting anything; a type that gained a
> caller since `e3d14da` is no longer dead.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW (deletions verified reference-free; test split is mechanical)
- **Depends on**: none. **Ordering caution**: plans 021/023/025/026 add tests
  to `SendToolExecuteTests.swift` and touch `AppleScriptRunnerValidationTests`
  (currently inside `PlaceholderTests.swift`). Land this plan either BEFORE
  all of them or AFTER all of them, interleaving invites merge pain. If some
  have landed and some haven't, prefer AFTER.
- **Category**: tech debt
- **Planned at**: commit `e3d14da`, 2026-08-07

## Why this matters

Two unrelated hygiene problems, one small plan:

1. **Dead speculative model code.** Early-scaffold `Codable` structs and two
   whole enrichment processors have zero call sites. They read like the real
   response shapes (a future contributor, or a code-assist model, will
   "helpfully" wire responses through `struct Message`/`struct Chat`, which
   are NOT what the tools actually emit; the real shapes live in
   `ResponsePrimitives.swift` and per-tool response structs). Dead code that
   impersonates live architecture is the expensive kind.
2. **`PlaceholderTests.swift` is a misnamed 565-line grab-bag** holding seven
   real test classes (send payloads, AppleScript runner validation, tool
   registry, attachment tool, resolver…). The name actively hides where
   tests live; several other plans keep needing to say "the class inside
   PlaceholderTests.swift".

## Current state, verified dead (zero references outside their own file)

Verification method used (re-run these; they are the ground truth):

```bash
cd swift
grep -rn "AudioProcessor\|VideoProcessor" Sources Tests --include="*.swift" -l
# → only their own two files
grep -rnE '(^|[^a-zA-Z._])Message[[:space:]]*\(|: Message([^a-zA-Z]|$)|\[Message\]' Sources Tests --include="*.swift" | grep -v "Models/Message.swift"
# → no hits (MessageRow/MessageInfo/ContextMessage etc. are different types)
grep -rnE '(^|[^a-zA-Z._])Chat[[:space:]]*\(|: Chat([^a-zA-Z]|$)|\[Chat\]' Sources Tests --include="*.swift" | grep -v "Models/Chat.swift"
# → only a doc-comment mention (GetContext.swift:121 "chatId: Chat ID")
grep -rn "AttachmentInfo\|MediaMetadata" Sources Tests --include="*.swift"
# → only their defining files
grep -rn "PeopleMap" Sources Tests --include="*.swift" | grep -v "Models/Participant.swift"
# → only buildPeopleMap (a FUNCTION in GetMessagesInternals.swift:167 that
#   returns plain dictionaries — it does NOT use the typealias)
```

**Delete entirely:**

- `swift/Sources/iMessageMax/Models/Message.swift` (31 lines: `struct Message`,
  `struct MediaMetadata` + nested `Dimensions`, all Codable scaffolds, never
  constructed or decoded anywhere)
- `swift/Sources/iMessageMax/Models/Chat.swift` (19 lines: `struct Chat` +
  nested `LastMessage`, same)
- `swift/Sources/iMessageMax/Models/Attachment.swift` (13 lines:
  `struct AttachmentInfo`, same)
- `swift/Sources/iMessageMax/Enrichment/AudioProcessor.swift` (40 lines)
- `swift/Sources/iMessageMax/Enrichment/VideoProcessor.swift` (62 lines)

**Delete one line only**, in `swift/Sources/iMessageMax/Models/Participant.swift`:

```swift
typealias PeopleMap = [String: Participant]
```

(line 12). `struct Participant` itself is **LIVE**, constructed in
`Models/ChatIdentity.swift:41` and `Utilities/ChatSummaryQueries.swift:64`,
used across many tools. Do not touch anything else in that file.

**Explicitly KEEP (live, verified):** `Models/AttachmentType.swift` (used by
GetMessages, GetAttachment, ListAttachments, preview formatters),
`Models/ChatIdentity.swift`, `Models/Reactions.swift`,
`Models/ResponsePrimitives.swift`, `Models/SendPayload.swift`,
`Enrichment/ImageProcessor.swift` (used by GetAttachment and GetMessages,
also the subject of separate plans; do not modify it here).

## Current state, the test grab-bag

`swift/Tests/iMessageMaxTests/PlaceholderTests.swift` (565 lines). Shared
imports at the top (`:1-7`):

```swift
import XCTest
import SQLite3
import MCP
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import iMessageMax
```

Classes and file-private helpers, with the exact helper→class usage map
(verified by grep, each helper is used by exactly one class):

| Lines | Contents | Helpers it uses |
|-------|----------|-----------------|
| 9-54 | `final class SendPayloadTests` | none |
| 56-105 | `final class SendResponseTests` | none |
| 107-229 | `final class AppleScriptRunnerValidationTests` | none |
| 231-302 | `final class ToolRegistryTests` | none |
| 304-373 | `final class GetAttachmentToolTests` | `makeAttachmentTestDatabase` (`:479`), `makeTestImage` (`:525`) |
| 375-393 | `final class SendToolExecutionTests` (single test) | `decodeToolErrorText` (`:557`) |
| 395-440 | `final class SendResolverTests` | `makeResolverTestDatabase` (`:442`) |

There is already a separate `SendToolExecuteTests.swift` (note the different
name: Execu**te** vs Execu**tion**) containing the `StubScriptRunner`-based
execute tests. The stray one-test `SendToolExecutionTests` class belongs in
there.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| Full suite | `cd swift && swift test` | exit 0, 0 failures |
| Test count | `cd swift && swift test 2>&1 | tail -5` | same total as baseline (deletions remove no tests) |

Before any change, record the baseline test count:
`cd swift && swift test 2>&1 | tail -5` (at plan time: 174 tests). The count
after this plan must be **identical**, this plan moves and deletes code, it
does not add or remove tests.

## Scope

**In scope** (the only files you may modify/delete/create):
- Delete: the 5 dead source files listed above
- Edit: `swift/Sources/iMessageMax/Models/Participant.swift` (remove line 12 only)
- Delete after split: `swift/Tests/iMessageMaxTests/PlaceholderTests.swift`
- Create: `SendPayloadTests.swift`, `SendResponseTests.swift`,
  `AppleScriptRunnerValidationTests.swift`, `ToolRegistryTests.swift`,
  `GetAttachmentToolTests.swift`, `SendResolverTests.swift` (all in
  `swift/Tests/iMessageMaxTests/`)
- Edit: `swift/Tests/iMessageMaxTests/SendToolExecuteTests.swift` (receives
  the `SendToolExecutionTests` content)
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):
- `ImageProcessor.swift`, live code, owned by the image-pipeline perf plan.
- Renaming, rewriting, or "improving" any moved test, this is a pure move.
  Byte-identical class bodies except where a helper's `private` placement
  forces nothing (file-private helpers move with their sole consumer and stay
  `private`).
- `buildPeopleMap` in `GetMessagesInternals.swift`, it never used the
  typealias; leave it alone.
- Any other `Models/` file beyond the listed deletions + the one
  `Participant.swift` line.

## Git workflow

- Branch: `advisor/032-dead-code-and-test-split`
- Two commits: `chore: delete dead model and enrichment scaffolds` then
  `test: split PlaceholderTests.swift into per-class files`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Re-verify deadness, then delete

Run every grep in the "verified dead" section. If ANY produces a hit outside
the defining file (doc comments don't count), STOP, that type is no longer
dead; report which.

Then: `git rm` the 5 files, and remove the `typealias PeopleMap` line (and
its preceding comment line if one exists directly above it) from
`Participant.swift`.

**Verify**: `cd swift && swift build` → exit 0 (the compiler is the real
deadness proof); `swift test` → same count as baseline, 0 failures. Commit.

### Step 2: Split the test file

For each of the six classes staying independent, create
`swift/Tests/iMessageMaxTests/<ClassName>.swift` containing:

1. Only the imports that file actually needs (start from the full 7-import
   block; the compiler will not flag unused imports, so trim by inspection:
   `CoreGraphics`/`ImageIO`/`UniformTypeIdentifiers` are only needed by
   `GetAttachmentToolTests`' `makeTestImage`; `SQLite3` only by files whose
   helpers call `sqlite3_*`, that is `GetAttachmentToolTests` and
   `SendResolverTests`; `MCP` wherever `Value`/tool types appear, check per
   class; `XCTest` + `@testable import iMessageMax` everywhere).
2. The class body, moved verbatim.
3. Its file-private helper(s) per the usage map above, moved verbatim,
   still `private`.

For `SendToolExecutionTests`: move the class (`:375-393`) and
`decodeToolErrorText` (`:557-`) into the existing
`SendToolExecuteTests.swift`. If that file already has an error-decoding
helper with a different name, use the existing one and drop the moved helper,
do not keep two. Keep the class name `SendToolExecutionTests` as-is
(renaming/merging classes is out of scope).

Delete `PlaceholderTests.swift` once empty.

**Verify**: `cd swift && swift build` → exit 0. If the build fails on a
missing symbol, a helper landed in the wrong file, fix placement, don't
widen access levels.

### Step 3: Full suite + count check

**Verify**: `cd swift && swift test` → exit 0, 0 failures, and the total
test count equals the Step-0 baseline exactly. Commit.

## Test plan

No new tests, the invariant IS the test plan: identical test count, zero
failures, before and after.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` exits 0; 0 failures; count == baseline
- [ ] `ls swift/Sources/iMessageMax/Enrichment/` → `ImageProcessor.swift` only
- [ ] `ls swift/Sources/iMessageMax/Models/` → no `Message.swift`, `Chat.swift`, `Attachment.swift`; the other six files present
- [ ] `grep -rn "PeopleMap" swift/Sources swift/Tests` → no matches (`buildPeopleMap` doesn't match, the grep is for the bare word; if it hits `buildPeopleMap`, that's fine, exclude it: the typealias itself must be gone from `Participant.swift`)
- [ ] `test ! -f swift/Tests/iMessageMaxTests/PlaceholderTests.swift`
- [ ] Six new per-class test files exist; `SendToolExecutionTests` lives in `SendToolExecuteTests.swift`
- [ ] `git status` clean of files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any deadness grep from Step 1 finds a real (non-comment) reference,
  the codebase moved; report the reference, delete nothing.
- The build breaks after deletion in a file this plan didn't list, the
  reference map was incomplete; report, revert the deletion commit.
- Test count changes at Step 3, a test was dropped or duplicated in the
  move; diff class-by-class against `git show HEAD~1:swift/Tests/iMessageMaxTests/PlaceholderTests.swift`.
- Another advisor plan (021/023/025/026) is mid-flight touching
  `SendToolExecuteTests.swift` or `AppleScriptRunnerValidationTests`, see
  the ordering caution in Status; report and sequence.

## Maintenance notes

- The corrected audit finding, for the record: `Participant` is live
  (ChatIdentity + ChatSummaryQueries construct it); only the `PeopleMap`
  typealias was dead. Earlier audit notes claiming Participant itself was
  dead are wrong, do not "finish the job" later by deleting it.
- If audio/video enrichment is ever actually wanted (duration/thumbnail for
  media attachments), the deleted processors are trivially recoverable from
  git history (`git log --diff-filter=D --summary`), but they were never
  wired to the attachment pipeline, so treat them as a starting sketch, not
  a drop-in.
- Plans 021/023/025/026 reference test classes by their PlaceholderTests
  location; after this plan lands, those references resolve to the new
  per-class files (same class names).
