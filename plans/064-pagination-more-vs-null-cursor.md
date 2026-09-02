# Plan 064: Pagination — `more: true` must never ship with `cursor: null`

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 639529e..HEAD -- swift/Sources/iMessageMax/Tools/ListChats.swift swift/Sources/iMessageMax/Tools/GetMessages.swift swift/Sources/iMessageMax/Tools/GetMessagesInternals.swift swift/Sources/iMessageMax/Tools/SearchInternals.swift swift/Sources/iMessageMax/Tools/ListAttachments.swift swift/Sources/iMessageMax/Utilities/TimelineCursor.swift swift/Tests/iMessageMaxTests/ListChatsToolTests.swift swift/Tests/iMessageMaxTests/CursorCodecTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `639529e`, 2026-09-01

## Why this matters

Every paginated tool reports two fields: `more` (is there another page) and
`cursor` (how to ask for it). They are computed independently, and the
cursor codecs return `nil` when the keyset value they need is `NULL`. So a
response can say `more: true, cursor: null`. An agent that follows the
contract loops forever asking for the next page with no cursor, or gives up
and reports "more results exist" that it cannot fetch. Both are wrong; the
second is quietly wrong, which is worse.

Concretely, `list_chats` with `sort: "recent"` (the default) orders by
`last_message_date DESC NULLS LAST`. Chats with no messages sit at the
tail with a `NULL` date. When a page boundary lands in that tail,
`ChatListCursor.encode(primary: nil, ...)` returns `nil` while `hasMore` is
still `true`. The same shape exists in `get_messages`, `search`, and
`list_attachments` through `TimelineCursor.encode(date: nil, ...)`, and
`get_messages` and `search` additionally compute `more` from a different
array than the one the cursor is derived from.

The fix in this plan is the contract fix: `more` is derived from the cursor,
so the two fields cannot disagree. Making the NULL tail itself pageable is
a query change and is out of scope (see Maintenance notes).

## Current state

### Cursor codecs return nil on a NULL keyset value

`swift/Sources/iMessageMax/Utilities/TimelineCursor.swift:8-11`:

```swift
static func encode(date: Int64?, messageId: Int64) -> String? {
    guard let date else { return nil }
    return "\(date):\(messageId)"
}
```

`TimelineCursor.swift:52-58` (`ChatListCursor.encode`):

```swift
static func encode(primary: Int64?, secondary: Int64?, chatId: Int64) -> String? {
    guard let primary else { return nil }
    if let secondary {
        return "\(primary):\(secondary):\(chatId)"
    }
    return "\(primary):\(chatId)"
}
```

`CursorCodecTests.testTimelineCursorNilDateEncodesNil` pins the nil
behavior. That test stays; nil-on-NULL is the codec's job. The bug is in
the callers that ignore the nil.

### list_chats

`swift/Sources/iMessageMax/Tools/ListChats.swift:362` orders `.recent` by
`last_message_date DESC NULLS LAST, c.ROWID DESC`; `:364` orders
`.mostActive` by `message_count DESC, last_message_date DESC NULLS LAST, c.ROWID DESC`.
Row mapping at `:395-404` reads `lastMessageDate: row.optionalInt(5)`.

`ListChats.swift:410`:

```swift
let hasMore = fetchedRows.count > clampedLimit
```

`ListChats.swift:475-497`:

```swift
let nextCursor: String?
if hasMore, let last = chatRows.last {
    switch sortOrder {
    case .recent:
        nextCursor = ChatListCursor.encode(
            primary: last.lastMessageDate,
            secondary: nil,
            chatId: last.id
        )
    case .mostActive:
        nextCursor = ChatListCursor.encode(
            primary: last.messageCount,
            secondary: last.lastMessageDate,
            chatId: last.id
        )
    case .alphabetical:
        nextCursor = ChatListCursor.encodeName(
            name: last.displayName ?? "",
            chatId: last.id
        )
    }
} else {
    nextCursor = nil
}
```

The response is built with `more: hasMore`, so a `.recent` page ending on
a chat with no messages yields `more: true, cursor: nil`.
(`.mostActive` with `secondary: nil` produces a two-part cursor and the
HAVING clause at `:333-341` decodes `secondary ?? 0`, so that sort does
not hit this bug; `.alphabetical` always encodes.)

`ListChatsResponse` at `ListChats.swift:13-19` carries
`more: Bool, cursor: String?`.

### get_messages

`swift/Sources/iMessageMax/Tools/GetMessages.swift:452-453`:

```swift
more: messages.count == limit,
cursor: Self.nextCursor(from: messageRows, limit: limit),
```

`GetMessagesInternals.swift:471-474`:

```swift
static func nextCursor(from rows: [MessageRow], limit: Int) -> String? {
    guard rows.count >= limit, let last = rows.last else { return nil }
    return TimelineCursor.encode(date: last.date, messageId: Int64(last.id))
}
```

`MessageRow.date` is `Int64?` (`GetMessagesInternals.swift:3-10`). Two
independent disagreements: `messages` (post-filter) versus `messageRows`
(raw page), and nil date.

### search

`swift/Sources/iMessageMax/Tools/SearchInternals.swift:243-244` (flat) and
`:358-359` (grouped):

```swift
more: results.count >= limit,
cursor: nextCursor(from: rows, limit: limit)
```

`nextCursor` at `:690-693` has the same shape as get_messages;
`SearchRow.date` is `Int64?` (`:8-16`).

### list_attachments

`swift/Sources/iMessageMax/Tools/ListAttachments.swift:253` and `:318-325`:

```swift
let hasMore = supportsCursor && messageRows.count > limit
...
let nextCursor: String?
if hasMore, let last = pageRows.last {
    nextCursor = TimelineCursor.encode(date: last.date, messageId: last.msgId)
} else {
    nextCursor = nil
}
return (results, hasMore, nextCursor)
```

Row `date` is `row.optionalInt(3)` (`:245`).

### Existing test harness

`swift/Tests/iMessageMaxTests/ListChatsToolTests.swift:5-40`
(`testCursorPageSkipsTotalsQuery`) builds a `ToolTestDatabase`, inserts
chats with one message each, and has a local `run(cursor:)` helper that
calls `ListChatsTool.execute(limit: 1, sort: "recent", cursor:, db: fixture.database(), resolver: ContactResolver(seedCache: [:]))`
and unwraps the `Result`. Copy that helper.

`ToolTestDatabase.insertChat(rowId:guid:displayName:serviceName:)` inserts
a chat with no messages; the `.recent` query LEFT JOINs the message
aggregate (`ListChats.swift:303`), so such a chat has `NULL last_message_date`.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `cd swift && swift build` | `Build complete!` |
| Focused | `cd swift && swift test --filter "ListChatsToolTests\|GetMessagesToolTests\|SearchToolTests\|ListAttachmentsToolTests\|CursorCodecTests"` | 0 failures |
| Whole suite | `cd swift && swift test` | 0 failures (baseline 370 at `639529e`) |
| Disagreement grep | `grep -n "more: " swift/Sources/iMessageMax/Tools/ListChats.swift swift/Sources/iMessageMax/Tools/GetMessages.swift swift/Sources/iMessageMax/Tools/SearchInternals.swift` | see Done criteria |

## Scope

### In scope

- `swift/Sources/iMessageMax/Tools/ListChats.swift` (`:410`, `:475-497`, response construction)
- `swift/Sources/iMessageMax/Tools/GetMessages.swift` (`:452-453`)
- `swift/Sources/iMessageMax/Tools/SearchInternals.swift` (`:243-244`, `:358-359`)
- `swift/Sources/iMessageMax/Tools/ListAttachments.swift` (`:318-325`)
- `swift/Tests/iMessageMaxTests/ListChatsToolTests.swift`
- `swift/Tests/iMessageMaxTests/GetMessagesToolTests.swift` (one test, optional; see Step 3)

### Out of scope

- Making the NULL tail pageable (a `date IS NULL AND id < ?` keyset
  branch in each query, plus a cursor form that encodes "null date").
  That is a query and codec change across four tools; file it as a
  follow-up if the reviewer wants it.
- `TimelineCursor.swift` and `CursorCodecTests.swift`. The codecs are
  correct; they are listed in the drift check because a change there would
  invalidate this plan's premise.
- `get_context`, `get_unread`, `get_active_conversations`: none of them
  emits a cursor.

## Git workflow

- Branch: `advisor/064-more-vs-null-cursor` from current `main`.
- Test-first: one commit with the failing `list_chats` test, one commit
  fixing all four tools (they are one contract), one optional commit for the
  `get_messages` test if Step 3 finds a way to build a NULL-date row.
- Commit messages:
  - `test: list_chats reports more:true with a null cursor on the no-message tail`
  - `fix: derive more from the cursor in every paginated tool`
  - `test: get_messages more/cursor agree on a null-date page boundary` (optional)
- The executor does not merge or push. Report the branch name.

Standing rules:

- Never `Task.sleep` in `swift/Sources`; `LaunchdSafetyTests` enforces it.
- Never touch `.mcp.json`.
- Never commit secrets.

## Steps

### Step 1: Failing test for list_chats

In `ListChatsToolTests.swift` add:

```swift
func testMoreIsFalseWhenNoCursorCanBeIssued() async throws {
    let fixture = try ToolTestDatabase(name: "list-chats-null-tail")
    try fixture.insertHandle(rowId: 1, handle: "+15550000001")
    // Three chats, no messages: every last_message_date is NULL, so the
    // keyset cursor cannot address the next page.
    for chatId in 1...3 {
        try fixture.insertChat(rowId: chatId, guid: "null-tail-\(chatId)", displayName: "Chat \(chatId)")
        try fixture.joinChatHandle(chatId: chatId, handleId: 1)
    }

    let result = await ListChatsTool.execute(
        limit: 1,
        sort: "recent",
        db: fixture.database(),
        resolver: ContactResolver(seedCache: [:])
    )
    guard case .success(let page) = result else {
        return XCTFail("list_chats failed: \(result)")
    }
    XCTAssertEqual(page.chats.count, 1)
    // The contract: more and cursor agree. At 639529e this is
    // more == true, cursor == nil.
    XCTAssertEqual(page.more, page.cursor != nil,
                   "more=\(page.more) cursor=\(String(describing: page.cursor))")
}
```

**Verify**: `swift test --filter ListChatsToolTests` → the new test fails
with `more=true cursor=nil`. Commit.

### Step 2: Derive `more` from the cursor

`ListChats.swift`: keep `hasMore` at `:410` for the cursor-emission guard,
then set the response field from the cursor. Where the response is built
(`more: hasMore`), change to `more: nextCursor != nil`. Add a one-line
comment above it: `// more and cursor must agree; a NULL keyset value yields no cursor and therefore no next page.`

`GetMessages.swift:452-453`: compute the cursor once into a local and use
it for both fields:

```swift
let nextCursor = Self.nextCursor(from: messageRows, limit: limit)
...
more: nextCursor != nil,
cursor: nextCursor,
```

`SearchInternals.swift:243-244` and `:358-359`: same shape with a local
`nextCursor` in each response builder.

`ListAttachments.swift:318-325`: return `(results, nextCursor != nil, nextCursor)`.
Check the caller of that tuple in `ListAttachments.swift` (search for
`hasMore` in the file) and confirm it only forwards the boolean into the
response; if it uses `hasMore` for anything else, STOP.

**Verify**: `swift test --filter ListChatsToolTests` → 0 failures.
`swift test --filter "GetMessagesToolTests|SearchToolTests|ListAttachmentsToolTests|GetUnreadToolTests"` → 0 failures. Commit.

### Step 3 (optional): get_messages NULL-date test

`ToolTestDatabase.insertMessage` takes `date: Int64` (non-optional), but
the fixture exposes `execute(_ sql:)` (`ToolTestSupport.swift:33`). After
inserting a page of messages via `insertMessage`, run
`try fixture.execute("UPDATE message SET date = NULL WHERE ROWID = <last>")`
to null the boundary row, then call `GetMessagesTool(db:resolver:).execute(args: ["chat_id": .string("chatN"), "limit": .int(k)])`
and decode with the file's existing `decodeGetMessagesResponse` helper.
Assert `(response["more"] as? Bool) == (response["cursor"] != nil && !(response["cursor"] is NSNull))`.

If the `message.date` column in the fixture schema is `NOT NULL`
(`grep -n "date" swift/Tests/iMessageMaxTests/ToolTestSupport.swift` near
the `CREATE TABLE message` block), skip this step and say so in the report.

**Verify**: the test passes after Step 2 and fails when Step 2's
`GetMessages.swift` hunk is reverted. Commit.

### Step 4: Full suite

**Verify**: `cd swift && swift test` → 0 failures, ≥ 371 tests.

## Test plan

- `ListChatsToolTests` +1 (`testMoreIsFalseWhenNoCursorCanBeIssued`).
- `GetMessagesToolTests` +1 optional.
- Existing `testCursorPageSkipsTotalsQuery` still passes (it uses chats with
  messages, so its cursor is non-nil and `more` is unchanged).
- Whole suite green.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` → 0 failures
- [ ] `grep -n "more: hasMore" swift/Sources/iMessageMax/Tools/ListChats.swift` → no matches
- [ ] `grep -n "more: messages.count == limit" swift/Sources/iMessageMax/Tools/GetMessages.swift` → no matches
- [ ] `grep -n "more: results.count >= limit\|more: rows.count >= limit" swift/Sources/iMessageMax/Tools/SearchInternals.swift` → no matches
- [ ] `grep -c "more: nextCursor != nil" swift/Sources/iMessageMax/Tools/ListChats.swift swift/Sources/iMessageMax/Tools/GetMessages.swift swift/Sources/iMessageMax/Tools/SearchInternals.swift` → `1`, `1`, `2` respectively
- [ ] `grep -n "return (results, hasMore, nextCursor)" swift/Sources/iMessageMax/Tools/ListAttachments.swift` → no matches
- [ ] `git diff --stat main..HEAD` lists only in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any existing test asserts `more == true` on a page whose cursor is nil.
  Report the test; that test encodes the bug.
- `ListAttachments.swift` uses the tuple's `hasMore` for anything other than
  the response field (for example to decide whether to run a second query).
- The `get_messages` `messages` array can legitimately be shorter than
  `messageRows` on a full page (post-filtering) *and* a reviewer wants
  `more` to reflect the filtered count. That is a product question; this
  plan's answer is "more means a cursor exists," and it should be confirmed
  rather than guessed.

## Maintenance notes

- Contract: in every paginated response, `more == (cursor != nil)`. A
  reviewer can check with `grep -rn "more: " swift/Sources/iMessageMax/Tools | grep -v "nextCursor != nil"`, which after this plan should list only
  `get_unread` (its `more` is a truncation flag with no cursor, by design).
- The NULL tail is still not pageable after this plan: a `list_chats` page
  that ends on a chat with no messages reports `more: false` even when more
  no-message chats exist. Callers who need the full set of empty chats can
  use `sort: "alphabetical"`, whose cursor never depends on a date. Making
  `.recent` fully pageable needs a `last_message_date IS NULL AND c.ROWID < ?`
  branch in the HAVING clause and a cursor form for it; that is the
  follow-up.
