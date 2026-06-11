# Plan 010: Migrate GetUnread's summary loop onto ChatSummaryQueries

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on.
> Touch only in-scope files. On any STOP condition, stop and report. Your
> reviewer maintains `plans/README.md` — do not edit it. Audit every claim
> in your report against an actual tool result. Report format:
> STATUS / STEPS / STOPPED BECAUSE (if stopped) / FILES CHANGED / NOTES.
>
> **Drift check (run first)**: `git diff --stat 90c65e1..HEAD -- swift/Sources/iMessageMax/Tools/GetUnread.swift swift/Sources/iMessageMax/Utilities/ChatSummaryQueries.swift`
> Empty output expected; on a mismatch with the excerpts below, STOP.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW-MED (behavior-preserving refactor; characterization tests written first)
- **Depends on**: none (plans 002/003 already merged into main)
- **Category**: perf + tech-debt
- **Planned at**: commit `90c65e1`, 2026-06-11

## Why this matters

Plan 003 batched the per-chat N+1 queries in `list_chats` and
`get_active_conversations` via `ChatSummaryQueries`. `get_unread`'s summary
mode still runs the old pattern: 2+ queries per unread chat (participants +
latest-unread-message), each on its own SQLite connection. Unread-chat counts
can be large after time away — exactly when an agent calls `get_unread`. This
plan extends the shared layer with an unread-inbound filter and migrates the
summary loop, deleting two more duplicated per-chat helpers.

## Current state

- `swift/Sources/iMessageMax/Tools/GetUnread.swift` — summary loop at 386-414:

```swift
        for row in rows {
            let msgChatId = row.chatId
            // ...
            let participants = try await getChatParticipants(chatId: msgChatId)
            let identity = makeChatIdentity(
                chatId: msgChatId, explicitName: row.chatDisplayName, participants: participants
            )
            let summary = try ChatSummaryBuilder.buildSummary(
                db: database, chatId: msgChatId, identity: identity
            )
            let lastMessage = try await getLatestUnreadMessageSummary(chatId: msgChatId, sinceApple: sinceApple)
            // appends UnreadChatSummary(chat:unreadCount:oldestUnread:lastMessage:)
        }
```

  Its helpers: `getChatParticipants` (line 534 — same SQL shape as
  `ChatSummaryQueries.participantsByChat`: `chat_handle_join JOIN handle WHERE
  chj.chat_id = ?`, then `contactResolver.resolve` per row) and
  `getLatestUnreadMessageSummary` (line 474 — newest message per chat with
  filters `m.is_read = 0 AND m.is_from_me = 0 AND m.associated_message_type = 0`,
  optional `m.date >= sinceApple`; formats sender via
  `IdentityDisplayFormatter.displayName` with **"Unknown"** fallback (capital U;
  the `is_from_me` branch is unreachable because of the inbound filter),
  text via `MessagePreviewResolver.messageSummary(... maxLength: 50)`,
  `ago: TimeUtils.formatCompactRelative(date)` **with no fallback (nullable)**,
  `ts: TimeUtils.formatISO(date)`).
- `swift/Sources/iMessageMax/Utilities/ChatSummaryQueries.swift` — the shared
  batched layer from plan 003. `lastMessagesByChat(db:chatIds:resolver:sinceApple:previewMaxLength:unknownSenderLabel:agoFallback:)`
  already parameterizes window start and formatting. It does NOT yet filter by
  read state or direction.
- NOTE: `GetUnread` is a class/struct holding `database` and `contactResolver`
  as instance properties (helpers are instance methods, not statics) — adapt
  call sites accordingly; `ChatSummaryQueries` functions are static and take
  `db`/`resolver` explicitly.
- The detail (non-summary) path at `GetUnread.swift:298` uses
  `chatParticipantsCache` — OUT of scope (it already caches per chat).
- Test infrastructure: `ToolTestSupport.swift` (`ToolTestDatabase` with
  `insertMessage(..., isRead:...)`, `makeSeededResolver()`); exemplar
  characterization file: `swift/Tests/iMessageMaxTests/ListToolCharacterizationTests.swift`.
- Existing shape tests that must keep passing: `OverviewResponseTests.swift`,
  `ResponseContractTests.swift`.

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Build | `cd swift && swift build` | exit 0 |
| All tests | `cd swift && swift test` | exit 0 (baseline on `90c65e1`: 121 tests) |
| New tests | `cd swift && swift test --filter UnreadCharacterizationTests` | all pass |

## Scope

**In scope**:
- `swift/Tests/iMessageMaxTests/UnreadCharacterizationTests.swift` (create — Step 1)
- `swift/Sources/iMessageMax/Utilities/ChatSummaryQueries.swift` (extend — Step 2)
- `swift/Tests/iMessageMaxTests/ChatSummaryQueriesTests.swift` (one new test — Step 2)
- `swift/Sources/iMessageMax/Tools/GetUnread.swift` (migrate summary loop — Step 3)

**Out of scope** (do NOT touch): `FindChat.swift` (rejected for migration —
bounded result counts), GetUnread's detail path and `chatParticipantsCache`
(line 298), `ListChats.swift`, `GetActiveConversations.swift` (already
migrated — their call sites must not change), `Database.swift`, response
models/JSON keys, `ListToolCharacterizationTests.swift`.

## Git workflow

- Branch: `advisor/010-getunread-batched`
- Commit per step; lowercase conventional prefixes. Do NOT push or open a PR.

## Steps

### Step 1: Characterization tests FIRST (against current behavior)

Create `UnreadCharacterizationTests.swift` modeled on
`ListToolCharacterizationTests.swift`. Read GetUnread's entry point/registration
to learn how to invoke summary mode directly (existing tests in
`OverviewResponseTests.swift` show the pattern). Fixture: 2 chats with unread
inbound messages (use `insertMessage(..., isFromMe: false, isRead: false, ...)`),
plus read messages and an unread *reaction* row (`associatedMessageType: 2000`)
newer than the unread messages.

1. `testUnreadSummaryResolvesParticipants` — resolved contact name appears.
2. `testUnreadSummaryLastMessageIsNewestUnreadInboundNonReaction` — the newer
   unread *message* wins; the newer reaction is ignored; `from` is the resolved
   sender name; preview text matches.
3. `testUnreadSummaryCountsPerChatAndTotal` — `unreadCount` per chat and
   `totalUnread`/`chatsWithUnread` are correct.
4. `testChatWithOnlyReadMessagesExcluded` — a chat with only read messages does
   not appear.

Pin actual current output (run, inspect, then assert). If any test reveals
apparently-buggy behavior, pin it with a NOTE comment and report — do not fix.

**Verify**: `swift test --filter UnreadCharacterizationTests` → 4 pass;
full `swift test` → 125.

### Step 2: Extend the shared layer

Add `onlyUnreadInbound: Bool = false` to
`ChatSummaryQueries.lastMessagesByChat`. When true, the inner windowed query
additionally filters `AND m.is_read = 0 AND m.is_from_me = 0`. Default `false`
preserves all existing call sites unchanged (verify ListChats /
GetActiveConversations need no edits). Add one test to
`ChatSummaryQueriesTests.swift`: `testOnlyUnreadInboundFilter` — a chat whose
newest message is read (or from me) returns the newest *unread inbound* one
instead; with the flag false, the overall newest wins.

**Verify**: `swift test --filter ChatSummaryQueriesTests` → 6 pass (5 existing + 1);
full suite → 126.

### Step 3: Migrate the summary loop

Hoist before the loop: `let chatIds = rows.map(\.chatId)`, then

```swift
let participantsByChat = try await ChatSummaryQueries.participantsByChat(
    db: database, chatIds: chatIds, resolver: contactResolver)
let lastByChat = try await ChatSummaryQueries.lastMessagesByChat(
    db: database, chatIds: chatIds, resolver: contactResolver,
    sinceApple: sinceApple, previewMaxLength: 50,
    unknownSenderLabel: "Unknown", agoFallback: nil,
    onlyUnreadInbound: true)
```

Inside the loop use lookups; map `ChatSummaryQueries.Participant` into the
existing `ParticipantInfo`/`makeChatIdentity` flow (or adjust
`makeChatIdentity` to accept the shared type — whichever is the smaller diff).
`lastMessage` comes from `lastByChat[chatId]?.info`. Delete
`getChatParticipants` and `getLatestUnreadMessageSummary`. CAUTION: if
`ParticipantInfo` or these helpers are referenced by the out-of-scope detail
path (check line 298's cache type before deleting), keep whatever the detail
path needs — delete only what becomes unused.

**Verify**: `swift test --filter UnreadCharacterizationTests` → 4 pass
UNMODIFIED (`git diff <branch-base>..HEAD -- swift/Tests/iMessageMaxTests/UnreadCharacterizationTests.swift`
shows only the Step-1 creation, no later edits); full suite → 126 pass.

## Done criteria

- [ ] `cd swift && swift build` exit 0; `cd swift && swift test` → 126 pass
- [ ] `grep -n "func getChatParticipants\|func getLatestUnreadMessageSummary" swift/Sources/iMessageMax/Tools/GetUnread.swift` → no matches (unless the detail path needed one — then report which and why)
- [ ] `ListChats.swift` / `GetActiveConversations.swift` unmodified (`git diff --stat <base>..HEAD` lists only the 4 in-scope files)
- [ ] Characterization tests unmodified after Step 1

## STOP conditions

- Drift check fails, or the excerpts don't match the live code.
- A characterization test fails after Step 3 for any reason you can't trace to
  an outright mistake — never adjust the test.
- `getLatestUnreadMessageSummary` turns out to differ from the shared shape by
  more than the unread-inbound filter (e.g. different reaction handling).
- Migrating requires touching the detail path or response models.

## Maintenance notes

- `onlyUnreadInbound` is the third behavior knob on `lastMessagesByChat`; if a
  fourth appears, fold the knobs into an options struct.
- FindChat migration was considered and rejected (bounded result counts) —
  recorded in the index; don't resurrect it without latency evidence.
