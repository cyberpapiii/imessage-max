# Plan 003: Replace per-chat N+1 queries with a shared batched chat-summary layer

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 57a2ff3..HEAD -- swift/Sources/iMessageMax/Tools/ListChats.swift swift/Sources/iMessageMax/Tools/GetActiveConversations.swift swift/Sources/iMessageMax/Utilities/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED (behavior-preserving refactor of the hottest read paths)
- **Depends on**: plans/002-characterization-tests-list-tools-and-send.md (its tests are this plan's safety net — do NOT start without them passing)
- **Category**: perf + tech-debt
- **Planned at**: commit `57a2ff3`, 2026-06-11

## Why this matters

Every list/overview tool runs 2–3 SQL queries *per chat* in a loop, and `Database.query()` opens and closes a fresh SQLite connection for each query. A `list_chats(limit: 100)` call issues roughly 200+ queries / connection cycles where ~3 batched queries would do. This is the product's hot path — the strategy doc's "time-to-context" metric — and the per-chat helpers are also duplicated near-identically across tools (`getParticipants` exists in `ListChats.swift:360`, `GetActiveConversations.swift:325`, and `SendResolution.swift:248`), so fixes to participant logic currently require synchronized edits in three files. This plan introduces one shared, batched query layer and migrates the two overview tools to it.

## Current state

- `swift/Sources/iMessageMax/Tools/ListChats.swift` — per-chat loop at 245-292:

```swift
            for chatRow in chatRows {
                // Get participants
                let participantRows = try await getParticipants(
                    db: db, chatId: chatRow.id, resolver: resolver
                )
                // ... builds ChatIdentity ...
                // Get last message
                let lastMsg = try await getLastMessage(
                    db: db, chatId: chatRow.id, resolver: resolver
                )
                // ... ChatSummaryBuilder.participantsPreview(db:chatId:identity:) per chat ...
            }
```

  Its private helpers: `getParticipants` (line 360 — one query on `chat_handle_join JOIN handle WHERE chj.chat_id = ?`, then `await resolver.resolve(handle)` per row) and `getLastMessage` (line 390 — one query `WHERE cmj.chat_id = ? AND m.associated_message_type = 0 ORDER BY m.date DESC LIMIT 1`, then sender display-name resolution, `AppleTime.toDate`, `TimeUtils` formatting, and `MessagePreviewResolver.messageSummary(db:messageId:text:attributedBody:maxLength: 50)`; returns `LastMessageResult(info: LastMessageSummary(from:text:ago:ts:), awaitingReply: !last.isFromMe)`).

- `swift/Sources/iMessageMax/Tools/GetActiveConversations.swift` — same pattern at 224-291 with its own `getParticipants` (line 325) and `getLastPreview` (line ~355); plus `ChatSummaryBuilder.participantsPreview` per chat (line 280).
- `swift/Sources/iMessageMax/Utilities/PreviewResolvers.swift` — `ChatSummaryBuilder.participantsPreview(db:chatId:identity:)` (line 54): only queries the DB (`recentParticipantPreviewNames`, line 83, `LIMIT 50` per chat) when the chat is named AND has >4 participants; otherwise computes from the already-loaded identity in memory. `MessagePreviewResolver.messageSummary` is in the same file (line 4).
- `swift/Sources/iMessageMax/Database/Database.swift` — `query(sql, params, map)`; opens one connection per call. Params support Int/Int64/String/Double/Data/NSNull.
- Models: `ChatIdentity` (`Models/ChatIdentity.swift`) with `makeParticipant(handle:contactName:)`.
- Safety net: `swift/Tests/iMessageMaxTests/ListToolCharacterizationTests.swift` (from plan 002), `ResponseContractTests.swift`, `OverviewResponseTests.swift`.

Conventions: tool-private row structs (`ParticipantRow`, `LastMessageResult`) are currently per-file; SQL is written as multi-line string literals with `?` placeholders; contact resolution goes through `ContactResolver.resolve` / `IdentityDisplayFormatter.displayName`.

SQLite note: the system SQLite on macOS 14+ supports window functions (`ROW_NUMBER() OVER`). Both production (chat.db) and the test fixture (`ToolTestDatabase`) use the system SQLite, so window functions are safe.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| All tests | `cd swift && swift test` | exit 0, all pass |
| Safety net | `cd swift && swift test --filter ListToolCharacterizationTests` | all pass, unmodified |

## Scope

**In scope**:
- `swift/Sources/iMessageMax/Utilities/ChatSummaryQueries.swift` (create — the shared batched layer)
- `swift/Sources/iMessageMax/Tools/ListChats.swift` (migrate; delete its private `getParticipants`/`getLastMessage`)
- `swift/Sources/iMessageMax/Tools/GetActiveConversations.swift` (migrate; delete its private equivalents)
- `swift/Tests/iMessageMaxTests/ChatSummaryQueriesTests.swift` (create)
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- `GetUnread.swift`, `FindChat.swift`, `SendResolution.swift` — they have the same pattern but different shapes; migrating them is explicitly deferred (see Maintenance notes). Do not "drive-by" migrate them.
- `ChatSummaryBuilder.participantsPreview` internals — its per-chat query only fires for named chats with >4 participants; leave it.
- `Database.swift` — no connection-pooling changes here.
- Response shapes / JSON keys — any characterization test failure means you changed behavior: revert and rethink.
- Test files from plan 002 — they must pass UNMODIFIED.

## Git workflow

- Branch: `advisor/003-batched-chat-summaries`
- Commit per step; style: lowercase conventional prefix, e.g. `perf: batch participant and last-message queries in list tools`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Create the batched query layer

New file `swift/Sources/iMessageMax/Utilities/ChatSummaryQueries.swift` with an enum namespace:

```swift
enum ChatSummaryQueries {
    struct Participant { let handle: String; let name: String?; let service: String? }
    struct LastMessage { /* mirror ListChats.LastMessageResult fields: info fields + awaitingReply */ }

    /// One query for all chats: participants keyed by chat id.
    static func participantsByChat(
        db: Database, chatIds: [Int64], resolver: ContactResolver
    ) async throws -> [Int64: [Participant]]

    /// One query for all chats: newest non-reaction message per chat.
    static func lastMessagesByChat(
        db: Database, chatIds: [Int64], resolver: ContactResolver
    ) async throws -> [Int64: LastMessage]
}
```

Implementation requirements:
- Guard `chatIds.isEmpty` → return `[:]` without querying.
- Build the `IN` clause with one `?` per id: `let placeholders = chatIds.map { _ in "?" }.joined(separator: ",")`, params `chatIds.map { $0 as Any }`. Never interpolate ids into SQL.
- `participantsByChat` SQL (note `chj.chat_id` must be selected for grouping):

```sql
SELECT chj.chat_id, h.id as handle, h.service
FROM chat_handle_join chj
JOIN handle h ON chj.handle_id = h.ROWID
WHERE chj.chat_id IN (<placeholders>)
```

  Then resolve contact names: collect *unique* handles first, `await resolver.resolve(handle)` once per unique handle, and reuse — this also removes the duplicate resolutions the old code did when the same person is in many chats.
- `lastMessagesByChat` SQL — newest non-reaction message per chat via a window function:

```sql
SELECT chat_id, text, attributedBody, is_from_me, sender_handle, date, message_id FROM (
    SELECT cmj.chat_id as chat_id, m.text, m.attributedBody, m.is_from_me,
           h.id as sender_handle, m.date, m.ROWID as message_id,
           ROW_NUMBER() OVER (PARTITION BY cmj.chat_id ORDER BY m.date DESC) as rn
    FROM message m
    JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
    LEFT JOIN handle h ON m.handle_id = h.ROWID
    WHERE cmj.chat_id IN (<placeholders>)
    AND m.associated_message_type = 0
) WHERE rn = 1
```

- Post-processing must replicate `ListChats.getLastMessage` EXACTLY (read `ListChats.swift:390-449` side by side): sender = "Me" / resolved display name via `IdentityDisplayFormatter.displayName` / "unknown"; `ago` via `TimeUtils.formatCompactRelative(AppleTime.toDate(date)) ?? "unknown"`; `ts` via `TimeUtils.formatISO`; text via `MessagePreviewResolver.messageSummary(db:messageId:text:attributedBody:maxLength: 50)`; `awaitingReply = !isFromMe`.

**Verify**: `cd swift && swift build` → exit 0.

### Step 2: Unit-test the layer in isolation

`swift/Tests/iMessageMaxTests/ChatSummaryQueriesTests.swift` using `ToolTestDatabase` + `makeSeededResolver()`:

1. `testParticipantsByChatGroupsAndResolves` — 2 chats, overlapping participants; assert grouping and resolved names.
2. `testLastMessagesByChatPicksNewestNonReactionPerChat` — per chat: older message, newer message, even-newer reaction (`associatedMessageType: 2000`); assert the newer *message* wins for each chat.
3. `testEmptyChatIdsReturnsEmpty` — no query crash on `[]`.
4. `testChatWithNoMessagesAbsentFromLastMessages` — a chat with participants but zero messages appears in `participantsByChat` but not in `lastMessagesByChat`.

**Verify**: `cd swift && swift test --filter ChatSummaryQueriesTests` → 4 tests pass.

### Step 3: Migrate ListChats

In the loop at `ListChats.swift:245`, hoist: collect `chatRows.map(\.id)`, call the two batched functions once before the loop, then look up per chat inside the loop. Map `ChatSummaryQueries.Participant` into the existing `ChatIdentity.makeParticipant` flow. Delete the now-unused private `getParticipants` and `getLastMessage`. The `ChatSummaryBuilder.participantsPreview` call stays as is.

**Verify**: `cd swift && swift test --filter ListToolCharacterizationTests` → all pass UNMODIFIED. Then `cd swift && swift test` → all pass.

### Step 4: Migrate GetActiveConversations

Same hoist for `getParticipants` (line 325). For `getLastPreview` (line ~355): first read it — if it is the same "newest non-reaction message, formatted" query parameterized by the window start (`windowStartApple`), extend `lastMessagesByChat` with an optional `sinceApple: Int64? = nil` parameter that adds `AND m.date >= ?`; if it differs more than that, STOP and report the difference. Delete the migrated private helpers.

**Verify**: `cd swift && swift test --filter ListToolCharacterizationTests` and full `swift test` → all pass.

### Step 5: Confirm the query-count win

Add one temporary instrumentation point ONLY if needed to convince yourself; otherwise reason from code: after migration, `list_chats(limit: N)` should issue 1 (chat list) + 1 (participants) + 1 (last messages) + 1 (totals) + per-chat preview queries only for named >4-participant chats + per-message `messageSummary` enrichment queries. Record before/after query counts for N=50 in your final report (count `db.query` call sites reachable per iteration). Remove any temporary instrumentation.

**Verify**: `git diff` contains no leftover instrumentation; `cd swift && swift test` → all pass.

## Test plan

- New: `ChatSummaryQueriesTests` (Step 2, 4 tests), modeled on `GetMessagesToolTests.swift`.
- Regression gate: `ListToolCharacterizationTests` (from plan 002) must pass without modification — that is the definition of behavior-preserving here.
- Full suite: `cd swift && swift test` → all pass.

## Done criteria

- [ ] `cd swift && swift build` exits 0
- [ ] `cd swift && swift test` exits 0; `ListToolCharacterizationTests` unmodified (verify: `git diff --stat -- swift/Tests/iMessageMaxTests/ListToolCharacterizationTests.swift` is empty)
- [ ] `grep -n "func getParticipants" swift/Sources/iMessageMax/Tools/ListChats.swift swift/Sources/iMessageMax/Tools/GetActiveConversations.swift` returns no matches
- [ ] `grep -c "ROW_NUMBER" swift/Sources/iMessageMax/Utilities/ChatSummaryQueries.swift` ≥ 1
- [ ] No files outside the in-scope list modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `ListToolCharacterizationTests` does not exist or does not pass before you start (plan 002 not landed).
- Any characterization test fails after migration and the cause is not an outright mistake you can revert — never "fix" the test to match new output.
- `getLastPreview` in GetActiveConversations differs from the shared shape by more than a `sinceApple` filter.
- The window-function query fails on the test fixture (would mean an unexpectedly old SQLite — report the version from `sqlite3_libversion`).
- You find yourself wanting to edit `GetUnread.swift`, `FindChat.swift`, or response models.

## Maintenance notes

- Deferred follow-ups (do not do now): migrate `GetUnread.swift:386-413` and `FindChat.swift:320-377` to `ChatSummaryQueries`; consolidate `SendResolution.getParticipants` (line 248) onto `participantsByChat`; consider one shared SQLite connection per tool call in `Database.swift` (drops remaining per-query open/close overhead).
- Reviewer should scrutinize: exact parity of last-message formatting (the `maxLength: 50` summary, "Me"/unknown sender fallbacks, `awaitingReply` polarity) and the empty-`chatIds` guard.
- If pagination or new list tools are added later, they should build on `ChatSummaryQueries`, not new per-chat helpers.
