# Plan 045: Make `search` and `find_chat contains_recent` scan the rows they claim to search

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 61e75d9..HEAD -- swift/Sources/iMessageMax/Tools/Search.swift swift/Sources/iMessageMax/Tools/SearchInternals.swift swift/Sources/iMessageMax/Tools/FindChat.swift swift/Tests/iMessageMaxTests/SearchToolTests.swift swift/Tests/iMessageMaxTests/FindChatToolTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MEDIUM
- **Depends on**: 041 (search characterization tests), 042 (limit clamps in the same files; land it first to avoid merge conflicts)
- **Category**: correctness / performance
- **Planned at**: commit `61e75d9`, 2026-09-01

## Why this matters

`search` with a `query` never puts the query into SQL. It fetches the newest 500 messages (or `limit × 10`, whichever is larger) that have any text, then filters those in Swift. On a real chat.db with years of history that means a search for a word from last month silently returns nothing if the word is not in the most recent 500 messages, while the response looks like a complete, empty result. Agents trust it and tell the user "no messages mention that".

`find_chat` with `contains_recent` has a different version of the same bug: its SQL predicate is `(m.text LIKE ? OR m.attributedBody IS NOT NULL)`, which matches every message that has an attributed body regardless of content, then relies on a Swift filter over at most 200 rows. Chats whose matching message is older than the 200 most recent attributed-body rows are missed.

The fix in both cases is to push a cheap SQL prefilter (`m.text LIKE '%term%'`) into the query for the common case where the text column is populated, and only fall back to the bounded scan of attributed-body-only rows. This is not full-text search; it is making the bounded scan look at the right rows.

## Current state

### search

`swift/Sources/iMessageMax/Tools/Search.swift:306-320`:

```swift
let clampedLimit = max(1, min(limit, 100))
...
// When a text query or unanswered filter is present we over-fetch and filter in Swift.
let fetchLimit = (hasQuery || unanswered) ? max(500, clampedLimit * 10) : clampedLimit
```

`swift/Sources/iMessageMax/Tools/SearchInternals.swift:59-100` (`buildQuery`) — the only text predicate:

```swift
if hasQuery {
    query = query.where("(m.text IS NOT NULL OR m.attributedBody IS NOT NULL)")
}
```

The search term itself is never bound. Lines 80-86 add `since`/`before`, lines 88-95 add the keyset cursor, line 98 parses `chat_id`.

`Search.swift:336-347` maps rows and extracts text via `MessageTextExtractor` (uses `m.text` when non-empty, else decodes `attributedBody`; `Utilities/MessageTextExtractor.swift:7-14`). `Search.swift:352-380` applies the word filter in Swift:

```swift
let filtered = rows.filter { row in
    guard let text = row.text else { return false }
    return wordMatches(text, terms: terms, matchAll: matchAll, fuzzy: fuzzy)
}
```

So the recall bound is `fetchLimit` newest rows, not "all rows containing the term".

Test coverage: `swift/Tests/iMessageMaxTests/SearchToolTests.swift` uses a fixture with a handful of messages, so it never exercises the 500-row cliff. Plan 041 adds cursor tests (`CursorCodecTests`) but not recall tests.

### find_chat contains_recent

`swift/Sources/iMessageMax/Tools/FindChat.swift:426-446`:

```swift
let fetchLimit = min(max(limit * 10, 50), 200)
let sql = """
    SELECT m.ROWID, m.text, m.attributedBody, cmj.chat_id
    FROM message m
    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    WHERE cmj.chat_id IN (\(placeholders))
      AND (m.text LIKE ? ESCAPE '\\' OR m.attributedBody IS NOT NULL)
    ORDER BY m.date DESC
    LIMIT ?
    """
```

followed by a Swift `contains` check over the decoded text. The `OR m.attributedBody IS NOT NULL` disjunct makes the LIKE useless as a filter: on modern macOS nearly every message has an attributedBody, so the query is effectively "newest 200 messages in these chats".

`FindChat.swift:55` sets `limit` (plan 042 clamps it). `escapeLike` exists in the codebase; check `grep -rn "func escapeLike" swift/Sources` for its location and signature before using it.

### chat.db facts you can rely on

- `message.text` is populated for the large majority of rows on macOS 13+ but is NULL for some (edited messages, some rich payloads), where `attributedBody` carries the text as a typedstream blob.
- There is no index on `message.text`; `LIKE '%x%'` is a sequential scan of the message table but it runs inside SQLite at C speed and returns only matching rows. That is far cheaper than shipping 500 rows to Swift and decoding blobs.
- `message.date` has an index; `ORDER BY date DESC LIMIT n` is cheap.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | `Build complete!` |
| Focused | `cd swift && swift test --filter "SearchToolTests|FindChatToolTests|SearchRecallTests"` | 0 failures |
| Whole suite | `cd swift && swift test` | 0 failures |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Tools/SearchInternals.swift` (`buildQuery`)
- `swift/Sources/iMessageMax/Tools/Search.swift` (fetch strategy)
- `swift/Sources/iMessageMax/Tools/FindChat.swift` (contains_recent query)
- `swift/Tests/iMessageMaxTests/SearchRecallTests.swift` (create)
- `swift/Tests/iMessageMaxTests/FindChatToolTests.swift` (add one test)

**Out of scope** (do NOT touch, even though they look related):
- Adding an FTS5 sidecar or any new index/table. Rejected this round; the bounded scan with a correct predicate is enough.
- `fuzzy` matching semantics and `match_all`. They stay as Swift post-filters; this plan only changes which rows reach them.
- The unanswered path (`filterUnanswered`) and `hasReplyWithinWindow` — plan 054.
- `GetMessagesInternals` — it has no text search.

## Git workflow

- Branch: `advisor/045-search-recall`
- Commits: `fix: prefilter search rows by term in SQL before the Swift word filter`; `fix: make find_chat contains_recent match message content, not attributedBody presence`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Recall test that fails today

Create `swift/Tests/iMessageMaxTests/SearchRecallTests.swift`. Use `ToolTestDatabase` from `ToolTestSupport.swift` (`insertHandle`, `insertChat`, `joinChatHandle`, `insertMessage(rowId:guid:text:date:isFromMe:...)`, `joinChatMessage`). Build a fixture with one chat and 601 messages: message 1 (oldest date) has text `"the zebra escaped"`, messages 2–601 have text `"filler N"` with increasing dates. Run `SearchTool` with `query: "zebra"` (find the tool's initializer and `execute` in `Search.swift`; the pattern for invoking a tool and decoding the JSON is in `SendToolExecuteTests.swift:229-234`).

Assert the result's `messages` (check the exact key name in `Search.swift`'s response construction near line 390) has count 1 and its text contains `zebra`.

**Verify**: `cd swift && swift test --filter SearchRecallTests` → **fails** with count 0 (the zebra row is outside the newest 500). If it passes, STOP: the fetch bound is not what this plan says.

### Step 2: Push the term into SQL for the text-populated case

In `SearchInternals.buildQuery`, when `hasQuery`, replace the presence-only predicate with a term prefilter. The search terms are already tokenized somewhere in `Search.swift` (look for where `terms` is built, around lines 300-304, before `buildQuery` is called); pass the tokens into `buildQuery` as a new parameter `terms: [String]`.

Build the predicate:

```swift
if !terms.isEmpty {
    // Cheap SQL prefilter on the text column. Rows whose text lives only in
    // attributedBody still pass (text IS NULL) and are filtered in Swift.
    let likeClauses = terms.map { _ in "m.text LIKE ? ESCAPE '\\'" }
    let joiner = matchAll ? " AND " : " OR "
    query = query.where("((\(likeClauses.joined(separator: joiner))) OR (m.text IS NULL AND m.attributedBody IS NOT NULL))")
    for term in terms {
        query = query.bind("%\(escapeLike(term))%")
    }
}
```

Adapt to `QueryBuilder`'s real API: read `swift/Sources/iMessageMax/Database/QueryBuilder.swift` for how `where` accepts bound parameters (there may be a `where(_:params:)` form; use whatever `SearchInternals.swift:88-95` already uses for the cursor binding). `fuzzy` mode: when `fuzzy` is true the LIKE prefilter would wrongly exclude near-misses, so skip the LIKE clauses when `fuzzy == true` and keep today's presence predicate. Note that `matchAll` with `AND`-joined LIKEs is correct only for the text column; attributedBody-only rows still fall through to the Swift filter.

Keep `fetchLimit` at `Search.swift:318` unchanged. With the prefilter, those 500 rows are now 500 *candidate* rows, which is the intended bound.

**Verify**: `cd swift && swift test --filter SearchRecallTests` → passes. `cd swift && swift test --filter SearchToolTests` → 0 failures (existing fixtures have text populated, so they must be unaffected).

### Step 3: attributedBody-only rows still work

Add `testAttributedBodyOnlyRowIsStillFound` to `SearchRecallTests`: insert a message with `text: nil` and an `attributedBody` blob containing `"zebra"` (copy the private `typedstreamBlob(marker:lengthField:payload:)` helper from `SendVerifierTests.swift`; plan 041 documents the exact lines), then 600 filler rows with text. Search for `zebra`. It must be found.

Note this test documents the residual bound: attributedBody-only rows are still subject to the 500-row window. That is acceptable and documented in the Maintenance notes.

**Verify**: `cd swift && swift test --filter SearchRecallTests` → 2 tests, 0 failures.

### Step 4: Fix `find_chat contains_recent`

In `FindChat.swift:426-446`, change the predicate to:

```sql
AND (m.text LIKE ? ESCAPE '\\' OR (m.text IS NULL AND m.attributedBody IS NOT NULL))
```

Bind `"%\(escapeLike(needle))%"` for the LIKE (check that the existing code already escapes; if it does not, use `escapeLike`). Keep the Swift `contains` check after decoding for the attributedBody-only rows and as a case-insensitivity guard (SQLite `LIKE` is case-insensitive for ASCII only; the Swift check handles Unicode).

Add `testContainsRecentFindsOlderMatchAmongManyRichMessages` to `FindChatToolTests.swift`: one chat, 250 messages with `text: nil` and a non-empty `attributedBody` blob (any bytes; they only need to be non-NULL) newer than one message with `text: "zebra"`. Call `find_chat` with the participant and `contains_recent: "zebra"`. Assert the chat is returned.

**Verify**: run the new test before the code change → fails; after → passes. `cd swift && swift test --filter FindChatToolTests` → 0 failures.

### Step 5: Full suite

**Verify**: `cd swift && swift test` → 0 failures, count = baseline + 3.

## Test plan

- `SearchRecallTests` (2): text-column recall beyond the 500-row window; attributedBody-only row still found within the window.
- `FindChatToolTests` +1: contains_recent match older than 200 rich rows.
- Existing `SearchToolTests` (match_all, fuzzy, cursor, since/before) unchanged.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` → 0 failures
- [ ] `grep -n "m.text LIKE ? ESCAPE" swift/Sources/iMessageMax/Tools/SearchInternals.swift` → at least one match
- [ ] `grep -n "OR m.attributedBody IS NOT NULL)" swift/Sources/iMessageMax/Tools/FindChat.swift` → no matches (the bare disjunct is gone)
- [ ] `SearchRecallTests` fails when Step 2's predicate is reverted (spot-check by `git stash` on `SearchInternals.swift`, run, `git stash pop`)
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `QueryBuilder` has no way to bind parameters inside a `where` clause and you would have to change `QueryBuilder.swift`. Report the API shape; a `QueryBuilder` change is a scope decision.
- Step 1's test passes before any change.
- Any existing `SearchToolTests` case fails after Step 2 and the failure is about which rows are returned (not about ordering). That means a fixture relies on a row with `text` present but not matching the term while `attributedBody` matches. Report the test.
- Search latency on a real database gets worse. Measure with the repo's `Makefile` `verify` target if available, or by timing a `search` call through `swift run imessage-max` against your own chat.db before and after; a full-table `LIKE` scan on a 1M-row message table should be well under one second. If it exceeds two seconds, report the timing.

## Maintenance notes

- The residual recall bound: rows whose text lives only in `attributedBody` are searched only within the newest 500 candidates. If that ever matters, the next step is an FTS5 sidecar (rejected this round; see `plans/README.md`).
- `fuzzy: true` bypasses the SQL prefilter entirely and keeps today's 500-row behaviour. The tool description should say so; plan 053 handles descriptions.
- Plan 051 batches participant queries in `SearchInternals.swift` and `FindChat.swift`. Land this plan first; 051 must rebase on it.
