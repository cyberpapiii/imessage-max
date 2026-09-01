# Plan 046: Stop trapping on duplicate handles in participant dictionaries

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 61e75d9..HEAD -- swift/Sources/iMessageMax/Utilities/IdentityDisplayFormatter.swift swift/Sources/iMessageMax/Utilities/PreviewResolvers.swift swift/Sources/iMessageMax/Utilities/ChatSummaryQueries.swift swift/Tests/iMessageMaxTests/ChatSummaryQueriesTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `61e75d9`, 2026-09-01

## Why this matters

`Dictionary(uniqueKeysWithValues:)` traps at runtime when two keys are equal. Two call sites build participant dictionaries keyed by handle string from data that chat.db does not guarantee to be unique: the `chat_handle_join` table can contain the same handle twice for one chat (this happens after iCloud sync merges, and when the same person is joined via both an SMS and an iMessage handle that normalize to the same string). The participant query in `ChatSummaryQueries.participantsByChat` has no `DISTINCT`, so one duplicate row in one group chat crashes `list_chats`, `get_active_conversations`, and any preview path for every client, on every call, until the operator hand-edits their database.

## Current state

`swift/Sources/iMessageMax/Utilities/IdentityDisplayFormatter.swift:33`:

```swift
let nameByHandle = Dictionary(uniqueKeysWithValues: zip(allParticipants.map(\.handle), allNames))
```

`swift/Sources/iMessageMax/Utilities/PreviewResolvers.swift:88`:

```swift
let participantsByHandle = Dictionary(uniqueKeysWithValues: participants.map { ($0.handle, $0) })
```

(Inside a function that at `:60-64` returns early when `participants.count <= 4`, so only groups of five or more reach the trap.)

`swift/Sources/iMessageMax/Utilities/ChatSummaryQueries.swift:28-60` (`participantsByChat(db:chatIds:resolver:)`) runs an `IN`-clause query over `chat_handle_join JOIN handle` with no `DISTINCT` and no de-duplication of the resulting `[Participant]` per chat, then resolves the unique handle set through the contact resolver. The `Participant` struct is at `:9-13`:

```swift
struct Participant {
    let handle: String
    let name: String?
    let service: String
}
```

Other participant-shaped structs exist (`Models/ChatIdentity.swift:25-35`, `GetUnread.swift:544`, `SendResolution.swift:4`, `ResponsePrimitives.swift:31`); plan 054 unifies them. Do not touch them here.

Repo search for the trap-prone initializer: `grep -rn "uniqueKeysWithValues" swift/Sources` returns exactly the two sites above at `61e75d9`. There are already safe usages elsewhere using `Dictionary(_:uniquingKeysWith:)`; for example `grep -rn "uniquingKeysWith" swift/Sources` shows the pattern to copy.

Test fixture: `swift/Tests/iMessageMaxTests/ChatSummaryQueriesTests.swift` exercises `participantsByChat` with a `ToolTestDatabase`. `ToolTestSupport.swift` provides `joinChatHandle(chatId:handleId:)`; calling it twice with the same pair inserts two join rows (the fixture schema has no unique constraint on `chat_handle_join`, matching the real database).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | `Build complete!` |
| Focused | `cd swift && swift test --filter "ChatSummaryQueriesTests|IdentityDisplayFormatterTests|PreviewResolverTests|ListChatsToolTests"` | 0 failures |
| Whole suite | `cd swift && swift test` | 0 failures |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Utilities/IdentityDisplayFormatter.swift`
- `swift/Sources/iMessageMax/Utilities/PreviewResolvers.swift`
- `swift/Sources/iMessageMax/Utilities/ChatSummaryQueries.swift`
- `swift/Tests/iMessageMaxTests/ChatSummaryQueriesTests.swift`

**Out of scope** (do NOT touch, even though they look related):
- The other ten participant query sites (`FindChat.swift:342,480`, `GetChatDetails.swift:203`, `GetContext.swift:499`, `GetUnread.swift:504`, `SendResolution.swift:266`, `ListAttachments.swift:550`, `SearchInternals.swift:571,663`, `GetMessagesInternals.swift:172,210`). None of them builds a `uniqueKeysWithValues` dictionary; plan 051/054 consolidates them. Adding `DISTINCT` to them is tempting but out of scope.
- Unifying the participant structs — plan 054.

## Git workflow

- Branch: `advisor/046-duplicate-handles`
- One commit, type `fix:`. Example: `fix: tolerate duplicate chat_handle_join rows in participant dictionaries`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Reproduce with a test

In `ChatSummaryQueriesTests.swift` add `testDuplicateJoinRowsYieldOneParticipantPerHandle`: one chat, one handle, call `joinChatHandle` twice for the same pair, call `participantsByChat` for that chat, assert the returned participants for the chat have count 1.

Add a second test that reaches the formatter: `testDisplayNameWithDuplicateParticipantsDoesNotTrap` — build a chat with handles `["+15550000001", "+15550000001", "+15550000002"]` joined (duplicate first), then call whatever public entry in `IdentityDisplayFormatter` builds the group display string (read the file; the function that contains line 33). Assert it returns without trapping. If `IdentityDisplayFormatter` cannot be driven from `ChatSummaryQueriesTests` cleanly, create `IdentityDisplayFormatterDuplicateTests.swift` instead and list it in your final report as an added file.

**Verify**: `cd swift && swift test --filter "ChatSummaryQueriesTests"` → the first new test fails (count 2), the second crashes the test process with `Fatal error: Duplicate values for key`. If neither reproduces, STOP.

### Step 2: De-duplicate at the source

In `ChatSummaryQueries.participantsByChat`, add `DISTINCT` to the `SELECT` (the columns are `chj.chat_id, h.id, h.service` or similar; `DISTINCT` over those is what you want), and after building the per-chat arrays, collapse duplicates by handle while preserving first-seen order:

```swift
var seen = Set<String>()
let unique = participants.filter { seen.insert($0.handle).inserted }
```

**Verify**: first new test passes.

### Step 3: Make the two dictionaries tolerant

`IdentityDisplayFormatter.swift:33`:

```swift
let nameByHandle = Dictionary(zip(allParticipants.map(\.handle), allNames), uniquingKeysWith: { first, _ in first })
```

`PreviewResolvers.swift:88`:

```swift
let participantsByHandle = Dictionary(participants.map { ($0.handle, $0) }, uniquingKeysWith: { first, _ in first })
```

Keep "first wins" in both: callers order participants deterministically and the first entry is the one the rest of the function already assumed.

**Verify**: second new test passes; `grep -rn "uniqueKeysWithValues" swift/Sources` → no matches.

### Step 4: Full suite

**Verify**: `cd swift && swift test` → 0 failures.

## Test plan

- `ChatSummaryQueriesTests` +2 (or +1 plus a new formatter test file), both constructed from duplicate join rows so they exercise the real data shape, not a synthetic array.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` → 0 failures
- [ ] `grep -rn "uniqueKeysWithValues" swift/Sources` → no matches
- [ ] `grep -n "DISTINCT" swift/Sources/iMessageMax/Utilities/ChatSummaryQueries.swift` → at least one match inside `participantsByChat`
- [ ] `git status` shows no modified files outside the in-scope list (plus the optional new test file)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `joinChatHandle` in `ToolTestSupport.swift` enforces uniqueness (second insert fails). Report; changing the fixture schema is allowed only if the real `chat_handle_join` table also has no unique constraint, which you can confirm with `sqlite3 ~/Library/Messages/chat.db ".schema chat_handle_join"` (read-only; requires Full Disk Access for the terminal).
- Either dictionary's downstream code depends on "last wins" semantics (look for comments or tests asserting which duplicate is chosen).

## Maintenance notes

- Review rule: any `Dictionary(uniqueKeysWithValues:)` keyed by data from chat.db is a bug. Prefer `uniquingKeysWith:` or a `Set`.
- Plan 054 introduces one shared participant query helper; it must carry the `DISTINCT` and de-duplication from Step 2.
