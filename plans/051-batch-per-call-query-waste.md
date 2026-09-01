# Plan 051: Batch the per-row and per-call queries that dominate tool latency

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 61e75d9..HEAD -- swift/Sources/iMessageMax/Tools/FindChat.swift swift/Sources/iMessageMax/Tools/SearchInternals.swift swift/Sources/iMessageMax/Tools/ListChats.swift swift/Sources/iMessageMax/Tools/GetUnread.swift swift/Sources/iMessageMax/Tools/SendResolution.swift swift/Sources/iMessageMax/Tools/GetMessagesInternals.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MEDIUM
- **Depends on**: 045 (touches the same `FindChat.swift` and `SearchInternals.swift` regions; land 045 first and rebase), 042 (limit clamps)
- **Category**: performance
- **Planned at**: commit `61e75d9`, 2026-09-01

## Why this matters

The previous perf round (`perf/query-bottlenecks`, merged as `61e75d9`) fixed server-side overhead. The remaining latency is N+1 query patterns inside tools: `find_chat` runs two queries per candidate chat plus a handles query per multi-participant candidate, `search` with `include_context` runs a context query per result row, `get_unread` computes an unbounded GROUP BY over every chat on every call, `list_chats` recomputes totals on every page, and `send` by name runs a last-contact query per matched contact. On a database with a few thousand chats each of these is tens to hundreds of round trips through the raw sqlite3 wrapper per tool call.

The fixes are all "one query with `IN (...)` or a window, then join in Swift", the same shape `ChatSummaryQueries.participantsByChat` already uses (`Utilities/ChatSummaryQueries.swift:28-60`). That helper is the exemplar for every step below.

## Current state

### find_chat

`swift/Sources/iMessageMax/Tools/FindChat.swift:289-304`: candidate query `SELECT DISTINCT c.ROWID ... WHERE h.id IN (...)` with no `LIMIT`; a common handle (the operator's own number) returns every chat. `:308-331`: for multi-participant matches, `getChatHandles` per candidate. `:352-380` (`enrichAndSortChats`): per candidate, one `COUNT(*) FROM chat_handle_join` and one `MAX(m.date)` query. Result sorted in Swift, then `prefix(limit)` at `:334`.

### search include_context

`swift/Sources/iMessageMax/Tools/SearchInternals.swift:292-300`: when `includeContext` is set, `getContext(db:messageId:...)` runs per result row (up to `limit`, max 100) and each context call is its own windowed query.

### get_unread summary

`swift/Sources/iMessageMax/Tools/GetUnread.swift:332-370` (`getUnreadSummary`): `QueryBuilder` `GROUP BY chat_id ORDER BY unread_count DESC` with no `LIMIT`. `:326-327` comment: "Cursor pagination not implemented; never advertise more pages." and `more: false`. `:438-442` builds the response. The `more` field is declared at `:14`.

### list_chats totals

`swift/Sources/iMessageMax/Tools/ListChats.swift:437`: `getTotals(db:)` runs on every call, including every cursor page. `:516-539`: the SQL is `chat LEFT JOIN chat_handle_join ... GROUP BY` over every chat to compute total/group/direct counts.

### send by name

`swift/Sources/iMessageMax/Tools/SendResolution.swift:207-211`:

```swift
var candidates: [(handle: String, name: String, lastContact: Date?)] = []
for match in matches {
    let lastTime = try? getLastContactTime(handle: match.handle)
    candidates.append((match.handle, match.name, lastTime))
}
```

`matches` comes from `ContactResolver.searchByName`, which is a substring match over every cached contact (`Contacts/ContactResolver.swift:95-100`), so a short name like "Jo" yields dozens of matches and dozens of queries.

### Exemplar

`Utilities/ChatSummaryQueries.swift:28-60` `participantsByChat(db:chatIds:resolver:)`: builds `IN (?,?,...)` placeholders for a `[Int64]`, runs one query, groups rows into `[Int64: [Participant]]`. Copy its placeholder construction and grouping style.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | `Build complete!` |
| Focused | `cd swift && swift test --filter "FindChatToolTests|SearchToolTests|GetUnreadToolTests|ListChatsToolTests|SendResolverTests|ChatSummaryQueriesTests"` | 0 failures |
| Whole suite | `cd swift && swift test` | 0 failures |
| Query count (optional) | `cd swift && swift test --filter QueryCountTests` | 0 failures |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Tools/FindChat.swift`
- `swift/Sources/iMessageMax/Tools/SearchInternals.swift` (`:292-300` region only)
- `swift/Sources/iMessageMax/Tools/GetUnread.swift`
- `swift/Sources/iMessageMax/Tools/ListChats.swift`
- `swift/Sources/iMessageMax/Tools/SendResolution.swift`
- `swift/Sources/iMessageMax/Utilities/ChatSummaryQueries.swift` (add helpers; do not change existing signatures)
- `swift/Sources/iMessageMax/Database/Database.swift` (only if Step 6 adds a query counter)
- Tests under `swift/Tests/iMessageMaxTests/` for the tools above

**Out of scope** (do NOT touch, even though they look related):
- The 11 participant query copies as a set — plan 054 consolidates them. Here you may *call* `participantsByChat` from `FindChat` if it removes a per-candidate query, but do not rewrite the other sites.
- The search term predicate — plan 045.
- Response shapes and key names; every change here is invisible to clients except `get_unread` which gains an honest `more`.

## Git workflow

- Branch: `advisor/051-batch-queries`
- One commit per tool, type `perf:`. Example: `perf: enrich find_chat candidates with two batched queries instead of two per chat`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Query counter for tests

Add to `Database` an opt-in counter so tests can assert query counts: `nonisolated(unsafe) static var queryCountForTesting: Int?` incremented in the central execute path when non-nil (read `Database.swift` for the single method every `query`/`execute` call funnels through). Tests set it to 0 before a tool call and read it after. Keep it `internal` so `@testable import` can reach it. If `Database` is an actor or otherwise makes a static counter awkward, use an instance property and expose it through the `ToolTestDatabase` fixture instead.

**Verify**: `swift build` → `Build complete!`; a throwaway test asserting the counter increments passes.

### Step 2: find_chat

- Candidate query: add `LIMIT 500` (`:289-304`). Sort order for the limit: `ORDER BY c.ROWID DESC` (newest chats first) so a common handle still finds recent chats.
- Replace `enrichAndSortChats` per-candidate queries with two batched queries over the candidate id set: `SELECT chat_id, COUNT(*) FROM chat_handle_join WHERE chat_id IN (...) GROUP BY chat_id` and `SELECT cmj.chat_id, MAX(m.date) FROM chat_message_join cmj JOIN message m ON m.ROWID = cmj.message_id WHERE cmj.chat_id IN (...) GROUP BY cmj.chat_id`. Build `[Int64: Int]` and `[Int64: Int64]` maps, then compute scores in Swift as before.
- Replace the per-candidate `getChatHandles` (`:308-331`) with one call to `ChatSummaryQueries.participantsByChat(db:chatIds:resolver:)` and use its map.

Add `FindChatToolTests.testEnrichmentUsesBoundedQueryCount`: fixture with 30 candidate chats sharing a handle; assert the query counter after `find_chat` is ≤ 6.

**Verify**: `swift test --filter FindChatToolTests` → 0 failures.

### Step 3: search include_context

At `SearchInternals.swift:292-300`, collect the result rows' `(chatId, messageId, date)` first, then fetch context for all of them in one query per chat using a window: for each distinct chat, `SELECT ... FROM message m JOIN chat_message_join cmj ... WHERE cmj.chat_id = ? AND m.date BETWEEN ? AND ? ORDER BY m.date` with the min/max of the result dates in that chat padded by the context window, then slice per result in Swift. If the existing `getContext` signature makes this awkward, add `getContextBatch(db:anchors:[(chatId, date)], window:)` next to it and leave `getContext` for `get_context`.

Add `SearchToolTests.testIncludeContextQueryCountIsPerChatNotPerRow`: 20 results in 2 chats, assert query count ≤ 5.

**Verify**: `swift test --filter SearchToolTests` → 0 failures, including the existing context-shape tests.

### Step 4: get_unread summary bound

Add `LIMIT ?` to `getUnreadSummary` bound to `limit + 1` (the tool's existing `limit` argument; read `:200-230` for where it is parsed and clamped). If the query returns `limit + 1` rows, drop the last and set `more: true`. Update the comment at `:326-327` to say pagination is by `limit` only (no cursor) and that `more` now reports truncation honestly.

Add `GetUnreadToolTests.testSummaryReportsMoreWhenTruncated`: 6 chats with unread messages, `limit: 5`, assert 5 chats and `more == true`.

**Verify**: `swift test --filter GetUnreadToolTests` → 0 failures.

### Step 5: list_chats totals only on the first page

At `ListChats.swift:437`, compute `getTotals` only when no cursor was supplied. When a cursor is present, omit the totals block or carry it forward from the request (check the response struct: if `totals` is non-optional, make it optional and document in the tool description that totals appear on the first page). Prefer omission; the first page already told the client.

Add `ListChatsToolTests.testCursorPageSkipsTotalsQuery`: assert query count on a cursor page is less than on the first page by at least 1.

**Verify**: `swift test --filter ListChatsToolTests` → 0 failures.

### Step 6: send by name

Replace the loop at `SendResolution.swift:207-211` with one query: `SELECT h.id, MAX(m.date) FROM handle h JOIN chat_handle_join chj ON chj.handle_id = h.ROWID JOIN chat_message_join cmj ON cmj.chat_id = chj.chat_id JOIN message m ON m.ROWID = cmj.message_id WHERE h.id IN (...) GROUP BY h.id`. Read `getLastContactTime` first and mirror its exact join semantics (it may use `message.handle_id` directly, which is cheaper; if so use that). Cap `matches` at 50 before the query; more than 50 name matches is a query the tool should reject as ambiguous anyway (check whether the ambiguity path at `:215+` already does this).

Add `SendResolverTests.testNameResolutionUsesOneLastContactQuery`: 8 contacts matching "Jo", assert query count ≤ 3.

**Verify**: `swift test --filter SendResolverTests` → 0 failures.

### Step 7: Full suite

**Verify**: `cd swift && swift test` → 0 failures.

## Test plan

- One query-count test per tool (5), plus the `more` behaviour test for `get_unread`.
- Existing tool tests guard response shape.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` → 0 failures
- [ ] `grep -n "LIMIT 500" swift/Sources/iMessageMax/Tools/FindChat.swift` → one match
- [ ] `grep -n "getLastContactTime(handle: match.handle)" swift/Sources/iMessageMax/Tools/SendResolution.swift` → no matches
- [ ] `grep -n "Cursor pagination not implemented" swift/Sources/iMessageMax/Tools/GetUnread.swift` → no matches (comment rewritten)
- [ ] All five query-count tests present and passing
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `Database` has no single funnel for queries, so a counter would need to touch more than one method. Report; the counter can be dropped and the tests replaced by timing-free structural assertions (for example, asserting that `enrichAndSortChats` takes a batch parameter).
- `list_chats` `totals` is documented in the MCP output schema as required and a client test in `docs/validation/` asserts it on every page. Report; the alternative is to cache totals per process for 5 seconds instead of omitting them.
- Plan 045 has not landed and `FindChat.swift:426-446` still has the presence-only predicate. Land 045 first.

## Maintenance notes

- Rule for reviewers: a tool that loops over rows and runs a query inside the loop is a regression. Batch with `IN (...)` and group in Swift.
- The query counter is test-only. Do not use it for metrics; per-tool stats are an operator option recorded in `plans/README.md`.
