# Plan 022: Route get_messages media paths through AttachmentPathPolicy

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report, do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat e3d14da..HEAD -- swift/Sources/iMessageMax/Tools/GetMessages.swift swift/Sources/iMessageMax/Utilities/AttachmentPathPolicy.swift`
> If either file changed since this plan was written, compare the "Current
> state" excerpts against the live code before proceeding; on a mismatch,
> treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `e3d14da`, 2026-08-07

## Why this matters

A previous audit established a repo-wide invariant: **attachment paths read
from chat.db are data, not trusted input**, a tampered row must not turn a
read tool into an arbitrary file probe. `AttachmentPathPolicy` (see
`swift/Sources/iMessageMax/Utilities/AttachmentPathPolicy.swift`) enforces
that, and `get_attachment` (`GetAttachment.swift:177`) and
`list_attachments` (`ListAttachments.swift:424`) both route through it. But
`get_messages` was missed: its media-enrichment path takes `att.filename`
straight from the database, tilde-expands it, and hands it to
`ImageProcessor.getMetadata`, which opens the file. A crafted attachment row
(e.g. `~/.ssh/known_hosts` or any path readable by the FDA-granted process)
gets probed for existence/readability, and image files anywhere on disk leak
filename, byte size, and pixel dimensions into the tool response. Same class
of hole the earlier plan closed elsewhere; this closes the last gap.

## Current state

`swift/Sources/iMessageMax/Tools/GetMessages.swift`, the tool is
`actor GetMessagesTool` (line 122) with:

```swift
    init(db: Database, resolver: ContactResolver) {
```

(line 126). The offending block, inside the message-assembly loop in
`executeImpl` (`GetMessages.swift:324-354`):

```swift
            if let rowAttachments = attachmentsMap[row.id] {
                for att in rowAttachments {
                    let attType = getAttachmentType(mimeType: att.mimeType, uti: att.uti)

                    if attType == "image" && mediaCount < maxMedia,
                       let path = att.filename {
                        let expandedPath = (path as NSString).expandingTildeInPath
                        let processor = ImageProcessor()
                        if let metadata = processor.getMetadata(at: expandedPath) {
                            if media == nil { media = [] }
                            media?.append(GetMessagesResponse.MediaInfo(
                                type: "image",
                                id: "att\(att.id)",
                                filename: metadata.filename,
                                sizeBytes: metadata.sizeBytes,
                                sizeHuman: FormatUtils.fileSize(metadata.sizeBytes),
                                dimensions: .init(width: metadata.width, height: metadata.height)
                            ))
                            mediaCount += 1
                            continue
                        }
                    }

                    if attachments == nil { attachments = [] }
                    attachments?.append(GetMessagesResponse.AttachmentSummary(
                        type: attType,
                        filename: att.filename?.components(separatedBy: "/").last,
                        size: att.totalBytes
                    ))
                }
            }
```

Note the graceful degradation already built in: when `getMetadata` returns
nil, the attachment falls through to the plain `AttachmentSummary` (which
only surfaces the last path component and the size already stored in
chat.db, no filesystem access). An invalid path should take exactly that
same fall-through.

The policy to call (`AttachmentPathPolicy.swift:12`, do not modify it):

```swift
    static func validatedPath(_ rawPath: String, allowedRoots: [String] = defaultRoots) -> String? {
```

It tilde-expands, canonicalizes (symlinks resolved), and returns the
canonical path only if it is inside one of the roots
(default: `~/Library/Messages`), else nil.

The repo's exemplar for a *list-style* tool doing this (silent degradation,
injectable roots), `ListAttachments.swift:404-425`:

```swift
    func attachmentsForMessage(
        messageId: Int64,
        typeFilter: String?,
        allowedRoots: [String] = AttachmentPathPolicy.defaultRoots
    ) throws -> ... {
        ...
            // Route through policy: paths outside allowed roots are treated as unavailable,
            // identical to a missing file. List output stays total (no error thrown).
            let validatedPath = path.flatMap { AttachmentPathPolicy.validatedPath($0, allowedRoots: allowedRoots) }
```

Test infrastructure that already exists:

- `swift/Tests/iMessageMaxTests/ToolTestSupport.swift`, `ToolTestDatabase`
  with `insertAttachment(rowId:filename:mimeType:uti:)` (`:95`) and
  `joinMessageAttachment(messageId:attachmentId:)` (`:110`), plus
  `insertHandle`/`insertChat`/`insertMessage`/`joinChatMessage`.
- `swift/Tests/iMessageMaxTests/GetMessagesToolTests.swift`, tool tests
  using `makeGetMessagesFixture()` (defined at `:182` in the same file) and
  `GetMessagesTool(db: fixture.database(), resolver: makeSeededResolver())`.
- `swift/Tests/iMessageMaxTests/AttachmentPathContainmentTests.swift:92-134`,
  the end-to-end out-of-root test for `GetAttachment`; the new test should
  mirror its shape (temp allowed root + outside file + fixture row pointing
  outside).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| Targeted tests | `cd swift && swift test --filter GetMessagesToolTests` | all pass |
| Containment tests | `cd swift && swift test --filter AttachmentPathContainmentTests` | all pass |
| Full suite | `cd swift && swift test` | exit 0, 0 failures |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Tools/GetMessages.swift`
- `swift/Tests/iMessageMaxTests/AttachmentPathContainmentTests.swift` (add one test)
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):
- `swift/Sources/iMessageMax/Utilities/AttachmentPathPolicy.swift`, correct as-is.
- `swift/Sources/iMessageMax/Enrichment/ImageProcessor.swift`, the
  per-iteration `ImageProcessor()`/CIContext waste is a separate performance
  plan (Tier 3); do not restructure it here. (Hoisting the single
  `let processor = ImageProcessor()` out of the loop is permitted if it falls
  out naturally, but changing `ImageProcessor` itself is not.)
- `GetAttachment.swift` / `ListAttachments.swift`, already compliant.
- The `has: "image"` SQL filtering or attachment-type logic, unrelated.

## Git workflow

- Branch: `advisor/022-get-messages-path-containment`
- Conventional commits, e.g. `fix: route get_messages media paths through AttachmentPathPolicy`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Make the roots injectable

In `GetMessages.swift`, add a stored property and init parameter to
`GetMessagesTool` (line 122/126), defaulting to the policy roots so
production behavior needs no call-site changes:

```swift
    private let allowedRoots: [String]

    init(db: Database, resolver: ContactResolver, allowedRoots: [String] = AttachmentPathPolicy.defaultRoots) {
        ...
        self.allowedRoots = allowedRoots
    }
```

(Match the existing property/assignment style in that init.)

**Verify**: `cd swift && swift build` → exit 0. `grep -rn "GetMessagesTool(" swift/Sources | grep -v allowedRoots`, existing production call sites still compile via the default.

### Step 2: Validate before touching the filesystem

Replace the two lines at `GetMessages.swift:330-331`:

```swift
                        let expandedPath = (path as NSString).expandingTildeInPath
                        let processor = ImageProcessor()
```

with:

```swift
                        // chat.db paths are data, not trusted input — contain to allowed roots.
                        // Out-of-root paths degrade to the AttachmentSummary fallthrough below.
                        if let validatedPath = AttachmentPathPolicy.validatedPath(path, allowedRoots: allowedRoots) {
                            let processor = ImageProcessor()
```

and change `processor.getMetadata(at: expandedPath)` to
`processor.getMetadata(at: validatedPath)`, closing the new `if let` brace so
that a nil validation falls through to the `AttachmentSummary` block exactly
like a failed `getMetadata` does today. The resulting logic must be:
valid path AND metadata readable → `MediaInfo`; anything else →
`AttachmentSummary` with only `lastPathComponent` + stored byte size.

**Verify**: `cd swift && swift build` → exit 0.

### Step 3: Add the end-to-end containment test

In `swift/Tests/iMessageMaxTests/AttachmentPathContainmentTests.swift`, add
`testGetMessagesDoesNotProbeOutOfRootPaths`, mirroring
`testGetAttachmentRejectsOutOfRootPath` (`:92-134`) but for the list tool's
silent-degradation contract:

1. Create temp `allowedRoot` and `outsideDir`; write a real, valid image is
   unnecessary, write `outsideFile` (`secret.jpg`) with junk bytes (if
   `getMetadata` were reached it would fail anyway, so to prove the *path is
   never probed* the assertion must be on the response shape, not on file
   access: the attachment must appear under `attachments` as a summary with
   `filename == "secret.jpg"` and never under `media`).
2. Build a `ToolTestDatabase` with one chat + handle + message
   (`insertHandle`, `insertChat`, `joinChatHandle`, `insertMessage`,
   `joinChatMessage`, copy the minimal setup from `makeGetMessagesFixture()`
   at `GetMessagesToolTests.swift:182`), then
   `insertAttachment(rowId: 99, filename: outsideFile.path, mimeType: "image/jpeg", uti: "public.jpeg")`
   and `joinMessageAttachment(messageId: <that message>, attachmentId: 99)`.
3. Run `GetMessagesTool(db: fixture.database(), resolver: makeSeededResolver(), allowedRoots: [allowedRoot.path])`
   with `args: ["chat_id": .string("chat<id>")]`, decode with the helpers
   used in `GetMessagesToolTests.swift` (`decodeGetMessagesResponse` etc.
   they live in that file/ToolTestSupport; reuse, don't duplicate).
4. Assert: the message's `media` is absent/empty, `attachments` contains the
   summary entry, and the full outside path string appears **nowhere** in the
   encoded response (`XCTAssertFalse(rawJSON.contains(outsideFile.path))`).

For the positive case, add `testGetMessagesEnrichesInRootImage`: same setup
but the file inside `allowedRoot`, written as a real tiny PNG. Generate one
in-test (e.g. a 1×1 PNG via `CGImageDestination` or a hardcoded valid PNG
byte array); assert `media` contains an entry with correct dimensions. If
constructing a valid image in-test proves awkward within ~20 lines, skip the
positive test and note it in the PR/commit message, the negative test is
the one that matters.

**Verify**: `cd swift && swift test --filter AttachmentPathContainmentTests` → all pass (1–2 new tests).

### Step 4: Full suite

**Verify**: `cd swift && swift test` → exit 0, 0 failures. Existing
`GetMessagesToolTests` must be untouched and green (fixture attachments in
`makeGetMessagesFixture` may use paths outside the default root, if any
existing test asserted `media` enrichment on such a path it will now fail;
see STOP conditions).

## Test plan

Step 3: one negative (out-of-root row degrades to summary, path never
echoed) and optionally one positive (in-root image still enriches). Pattern
exemplar: `AttachmentPathContainmentTests.swift:92-134`.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` exits 0; 0 failures; ≥1 net-new test
- [ ] `grep -n "expandingTildeInPath" swift/Sources/iMessageMax/Tools/GetMessages.swift` → no matches (validation owns expansion now)
- [ ] `grep -n "AttachmentPathPolicy" swift/Sources/iMessageMax/Tools/GetMessages.swift` → ≥1 match
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The excerpts don't match the live code (drift).
- An existing `GetMessagesToolTests` case starts failing because its fixture
  relied on media enrichment of a temp-dir path. Do NOT weaken the policy to
  fix it; report, the likely correct fix is passing
  `allowedRoots: [FileManager.default.temporaryDirectory.path]` in that
  test's tool construction, but confirm with the reviewer first.
- You find other unvalidated `att.filename`/chat.db-path filesystem access
  in `GetMessages.swift` beyond the excerpt above, report it; it belongs in
  this plan's scope but was not found at planning time.

## Maintenance notes

- Invariant for review: **no filesystem call in any tool may take a chat.db
  path that hasn't passed `AttachmentPathPolicy.validatedPath`**. Compliant
  sites: `GetAttachment.swift:177`, `ListAttachments.swift:424`, and (after
  this plan) `GetMessages.swift`.
- The Tier 3 image-pipeline performance plan will touch this same loop
  (hoisting `ImageProcessor()` / sharing the CIContext); land this plan
  first so that plan rebases on the validated path.
