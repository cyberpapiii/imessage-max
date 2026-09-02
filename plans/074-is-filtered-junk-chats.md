# Plan 074: Hide junk and unknown-sender chats by default (`chat.is_filtered`)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 639529e..HEAD -- swift/Sources/iMessageMax/Tools/ListChats.swift swift/Sources/iMessageMax/Tools/Search.swift swift/Sources/iMessageMax/Tools/SearchInternals.swift swift/Sources/iMessageMax/Tools/GetUnread.swift swift/Sources/iMessageMax/Tools/FindChat.swift swift/Tests/iMessageMaxTests/ToolTestSupport.swift swift/Tests/iMessageMaxTests/ListChatsToolTests.swift swift/Tests/iMessageMaxTests/SearchToolTests.swift swift/Tests/iMessageMaxTests/GetUnreadToolTests.swift swift/Tests/iMessageMaxTests/FindChatToolTests.swift README.md using-imessage-max/SKILL.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: MEDIUM (changes default results of four discovery tools; the
  opt-out is one boolean)
- **Depends on**: nothing
- **Category**: direction
- **Planned at**: commit `639529e`, 2026-09-01. Baseline: `cd swift && swift build && swift test` passes with 370 tests, 0 failures.

## Why this matters

Messages.app sorts conversations from non-contacts and reported junk
into "Unknown Senders" and "Junk" and keeps them out of the main list.
It records that decision in `chat.is_filtered`. The server never reads
that column (`grep -rn "is_filtered" swift/Sources` prints nothing), so
`list_chats`, `search`, `get_unread`, and `find_chat` mix short-code
spam, RCS marketing agents, and random-mailbox iMessage spam into the
same list as real conversations. An agent doing "what needs attention"
sees the noise the operator has already been shielded from.

Live counts (read-only `sqlite3 ~/Library/Messages/chat.db`, 2026-09-01):

| `is_filtered` | chats |
|---|---|
| 0 | 1104 |
| 1 | 1527 |
| 2 | 37 |
| 3 | 7 |
| 4 | 16 |
| 36 | 7 |
| 52 | 5 |
| 68 | 8 |

So 59% of all chat rows are filtered, and the value is a bitmask rather
than a boolean (36 = 32+4, 52 = 32+16+4, 68 = 64+4). Chats active in the
last 7 days: 29 with `is_filtered = 0` and 4 with nonzero values (one
each of 2, 3, 36, 52). Sampling the nonzero rows shows short codes,
`@rbm.goog` RCS agents, and throwaway `outlook.com`/`hotmail.com`
addresses, some with a literal `(filtered)` suffix on the chat
identifier. The predicate is therefore `is_filtered = 0` for "shown",
never `is_filtered != 1`.

Default hidden, one flag to show. Tools that take an explicit chat id
(`get_messages`, `get_chat_details`, `get_context`, `list_attachments`
with `chat_id`) must keep working on filtered chats, because an agent
that found a filtered chat via `include_filtered: true` needs to read it.

## Current state

### Schema and fixture

`swift/Tests/iMessageMaxTests/ToolTestSupport.swift:129-134`:

```sql
        CREATE TABLE chat (
            ROWID INTEGER PRIMARY KEY,
            guid TEXT,
            display_name TEXT,
            service_name TEXT
        );
```

`ToolTestSupport.swift:47-53`:

```swift
    func insertChat(rowId: Int, guid: String, displayName: String? = nil, serviceName: String = "iMessage") throws {
        let display = displayName.map { "'\(escape($0))'" } ?? "NULL"
        try execute("""
            INSERT INTO chat (ROWID, guid, display_name, service_name)
            VALUES (\(rowId), '\(escape(guid))', \(display), '\(escape(serviceName))');
            """)
    }
```

### list_chats

Schema at `swift/Sources/iMessageMax/Tools/ListChats.swift:110-147`
(`"is_group"` at `:121-124`); arguments read at `:159-165`
(`let isGroup = arguments?["is_group"]?.boolValue`); `execute` signature at
`:198-208`:

```swift
    static func execute(
        limit: Int = 20,
        since: String? = nil,
        isGroup: Bool? = nil,
        minParticipants: Int? = nil,
        maxParticipants: Int? = nil,
        sort: String = "recent",
        cursor: String? = nil,
        db: Database = Database(),
        resolver: ContactResolver
    ) async -> Result<ListChatsResponse, ListChatsError> {
```

Page query base at `:283-291`:

```swift
                let qb = QueryBuilder()
                qb.select(
                    "c.ROWID as id",
                    "c.guid",
                    "c.display_name",
                    ...
                )
                .from("chat c")
```

with `groupBy("c.ROWID")` and `having(...)` clauses at `:307-323`. A
`.where("c.is_filtered = 0")` slots in right after `.from("chat c")`.

Totals at `:532-543` (`getTotals`), computed only on the first page:

```sql
            SELECT
                COUNT(*) as total,
                SUM(CASE WHEN cnt > 1 THEN 1 ELSE 0 END) as groups,
                SUM(CASE WHEN cnt <= 1 THEN 1 ELSE 0 END) as dms
            FROM (
                SELECT c.ROWID, COUNT(chj.handle_id) as cnt
                FROM chat c
                LEFT JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
                GROUP BY c.ROWID
            )
```

Response at `:13-30`: `ListChatsResponse { chats, totalChats?, totalGroups?, totalDms?, more, cursor? }`
with a hand-written `encode(to:)` at `:31-` that uses `encodeIfPresent`
for the totals.

### search

Schema at `swift/Sources/iMessageMax/Tools/Search.swift:108-` (`"is_group"`
at `:123`, `"include_context"` at `:171`); arguments at `:227-235`; `execute`
at `:272-` with `isGroup: Bool? = nil` at `:276` and `includeContext: Bool = false`
at `:284`. Responses `SearchFlatResponse { results, total, more, cursor }`
at `:75-80` and `SearchGroupedResponse { chats, total, chatCount, query, more, cursor }`
at `:83-95`.

Query base in `swift/Sources/iMessageMax/Tools/SearchInternals.swift:59-72`:

```swift
            .from("message m")
            .join("chat_message_join cmj ON m.ROWID = cmj.message_id")
            .join("chat c ON cmj.chat_id = c.ROWID")
            .leftJoin("handle h ON m.handle_id = h.ROWID")
            .where("m.associated_message_type = ?", 0)
```

`chat c` is already joined, so the predicate is one more `.where`.

### get_unread

Schema at `swift/Sources/iMessageMax/Tools/GetUnread.swift:80-102`
(`chat_id`, `since`, `format`, `limit`); `Parameters` struct used by tests
as `GetUnread.Parameters(since: "all", format: .summary, limit: 5)`;
`execute(params:)` at `:166`. Three queries:

- messages mode, `:205-223`: joins `chat c ON cmj.chat_id = c.ROWID` at `:219`.
- summary mode, `:320-333`: joins `chat c` at `:330`.
- totals, `:451-459`: joins `chat_message_join cmj` only, no `chat c`:

```swift
            .select(
                "COUNT(DISTINCT m.ROWID) as total_unread",
                "COUNT(DISTINCT cmj.chat_id) as chats_with_unread"
            )
            .from("message m")
            .join("chat_message_join cmj ON m.ROWID = cmj.message_id")
            .where("m.is_read = 0")
            .where("m.is_from_me = 0")
            .where("m.associated_message_type = 0")
```

The totals query needs the `chat c` join added before the predicate so
`total_unread` and `chats_with_unread` also exclude filtered chats.

Responses `UnreadMessagesResponse { messages, totalUnread, chatsWithUnread, more, cursor }`
at `:10-` and `UnreadSummaryResponse { chats, totalUnread, chatsWithUnread, more }`
at `:35-`.

### find_chat

Schema at `swift/Sources/iMessageMax/Tools/FindChat.swift:12-39` (static
`inputSchema`; `"is_group"` at `:28-31`); parameters parsed at `:50-56`:

```swift
            self.isGroup = arguments?["is_group"]?.boolValue
            self.limit = max(1, min(arguments?["limit"]?.intValue ?? 5, 50))
```

Response at `:85-88`: `struct Response: Codable { let chats: [ChatResult]; let more: Bool }`.

Four raw queries, each already filtering on `c` via the shared
`groupFilterSQL` fragment (`:253-260`), which returns `" AND (...)"` or
`""`:

- `:277-284` candidates by handle set: `WHERE h.id IN (...) \(groupSQL)`
- `:399-405` by display name: `WHERE c.display_name LIKE ? ESCAPE '\\' \(groupSQL)`
- `:427-435` unnamed DMs by participant: `WHERE (c.display_name IS NULL OR ...) AND h.id IN (...) AND (...) <= 1`
- `:459-470` by recent content: `WHERE m.associated_message_type = 0 AND (...) \(groupSQL)`

The natural seam is a second fragment function next to `groupFilterSQL`,
`filteredSQL(includeFiltered: Bool) -> String`, returning
`" AND c.is_filtered = 0"` or `""`, appended at each of the four sites.
The unnamed-DM query (`:427`) has no `groupSQL`; append the new fragment
after its last `AND` line.

### Docs

`README.md`: `### find_chat` at `:223`, `### list_chats` at `:265`,
`### search` at `:274`, `### get_unread` at `:306`. Each has a short
description and a fenced example block.

`using-imessage-max/SKILL.md:27-35` describes the default catch-up flow
(`list_chats` first, `get_unread` as cross-check, `get_active_conversations`
for prioritisation, `get_messages` to drill in); `:79-82` lists the four
discovery tools.

### What does not change

`docs/conformance-baseline.yml` is the MCP conformance suite's
expected-failure list; it does not pin tool schemas. `CapabilityContractTests`
tests the `diagnose` capability contract, not tool input schemas
(`grep -n "inputSchema\|properties" swift/Tests/iMessageMaxTests/CapabilityContractTests.swift`
prints nothing). `ResponseContractTests` decodes `list_chats`, `search`,
`get_unread`, and `find_chat` responses but only asserts on existing keys
(`:6`, `:51`, `:97`, `:154`); an added optional key does not break them.
Confirm by running the filter after Step 4.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `cd swift && swift build` | ends in `Build complete!` |
| Focused | `cd swift && swift test --filter "ListChatsToolTests\|SearchToolTests\|GetUnreadToolTests\|FindChatToolTests\|ResponseContractTests\|ListToolCharacterizationTests"` | 0 failures |
| Whole suite | `cd swift && swift test` | 370 plus new tests, 0 failures |
| Live check | `sqlite3 -readonly ~/Library/Messages/chat.db "SELECT is_filtered, COUNT(*) FROM chat GROUP BY 1"` | the table above, give or take new rows |

## Scope

In scope:

- Fixture: `is_filtered INTEGER DEFAULT 0` on `chat`, and
  `insertChat(..., isFiltered: Int = 0)`.
- `include_filtered` boolean (default `false`) on the input schema of
  `list_chats`, `search`, `get_unread`, `find_chat`; threaded through
  each `execute`.
- `AND c.is_filtered = 0` in every discovery query of those four tools
  when the flag is false, including the totals queries in `list_chats`
  and `get_unread`.
- `filtered_hidden: Int` on the top-level response of each of the four
  tools, present whenever `include_filtered` is false (0 is a valid
  value), omitted when true. For `list_chats` it is first-page-only like
  the other totals.
- Tests per tool; README and SKILL updates.

Out of scope:

- `get_messages`, `get_chat_details`, `get_context`, `list_attachments`,
  `get_active_conversations`, `send`. Explicit-id tools must not filter.
  `get_active_conversations` is a prioritisation hint and is left alone
  in this plan; note it in the maintenance section.
- Any per-bit interpretation of `is_filtered`. Shown means `= 0`.
- Touching `.mcp.json` (never), committing secrets (never), `Task.sleep`
  under `swift/Sources` (never; `LaunchdSafetyTests` enforces it).

## Git workflow

- Branch: `git checkout -b advisor/074-is-filtered-junk-chats main`.
- Commit 1 (after Step 1): `test: add is_filtered to the chat fixture`
- Commit 2 (after Step 4): `feat(discovery): hide filtered chats by default with include_filtered opt-in`
- Commit 3 (after Step 5): `docs: document include_filtered and filtered_hidden`
- Do not push, do not merge.

## Steps

### Step 1: Fixture

In `ToolTestSupport.swift` add `is_filtered INTEGER DEFAULT 0` to the
`chat` table and an `isFiltered: Int = 0` parameter to `insertChat`,
included in the INSERT. Existing callers unchanged.

**Verify**: `cd swift && swift test` still reports 370 tests, 0 failures. Commit 1.

### Step 2: Tests first (red)

One test per tool, each building two chats with a recent message: chat 1
`isFiltered: 0`, chat 2 `isFiltered: 1`, plus a third chat with
`isFiltered: 36` to prove the predicate is `= 0` and not `= 1`.

- `ListChatsToolTests.testFilteredChatsAreHiddenByDefault`: `execute(limit: 10, sort: "recent", db:, resolver:)`
  returns only chat 1; `response.filteredHidden == 2`; `totalChats == 1`.
  Then `execute(..., includeFiltered: true)` returns all three and
  `filteredHidden == nil`.
- `SearchToolTests.testFilteredChatsAreHiddenByDefault`: all three chats
  have a message containing `"zebra"`; `SearchTool.execute(query: "zebra", ...)`
  flat results contain only chat 1's message; the decoded response has
  `filtered_hidden == 2`; with `includeFiltered: true` all three messages
  come back and the key is absent. Use the argument list shape shown at
  `SearchToolTests.swift:10-22`.
- `GetUnreadToolTests.testFilteredChatsAreHiddenByDefault`: all three
  chats have an unread message; `GetUnread.Parameters(since: "all", format: .summary, limit: 5)`
  yields one chat, `totalUnread == 1`, `chatsWithUnread == 1`,
  `filteredHidden == 2`; with `includeFiltered: true`, three chats and
  `totalUnread == 3`. Repeat once for `format: .messages`.
- `FindChatToolTests.testFilteredChatsAreHiddenByDefault`: all three
  chats named `"Zebra Club N"`; `FindChatTool.execute(arguments: ["name": .string("Zebra")], ...)`
  returns one chat and `filtered_hidden == 2`; with
  `"include_filtered": .bool(true)` returns three.
- `GetMessagesToolTests.testExplicitChatIdIgnoresIsFiltered`: chat with
  `isFiltered: 1`; `get_messages(chat_id: "chatN")` still returns its
  messages. This is the guard against over-reach.

**Verify**: `cd swift && swift build --build-tests` fails on the unknown
`includeFiltered` / `filteredHidden` names. Expected red.

### Step 3: Schema and plumbing

For each of the four tools add to the input schema `properties`:

```swift
                "include_filtered": .object([
                    "type": "boolean",
                    "description": "Include chats Messages.app has filtered as junk or unknown senders (default false)",
                ]),
```

Read it as `arguments?["include_filtered"]?.boolValue ?? false` next to
the `is_group` read in each tool, add `includeFiltered: Bool = false` to
each `execute` (and to `GetUnread.Parameters` and `FindChat`'s parameter
struct), and thread it down to the query builders.

**Verify**: `cd swift && swift build` ends in `Build complete!`; tests still red.

### Step 4: Predicates and counts

- `list_chats`: `.where("c.is_filtered = 0")` after `.from("chat c")` when
  `!includeFiltered`; add `WHERE c.is_filtered = 0` to the inner select of
  `getTotals` under the same condition. `filtered_hidden` on the first
  page is `SELECT COUNT(*) FROM chat c WHERE c.is_filtered != 0` (plus the
  same `since` inner join bound if `since` is set, so the number means
  "hidden from this view"; if that is awkward, the unscoped count is
  acceptable and must be documented as such in the README). Add
  `filteredHidden: Int?` to `ListChatsResponse`, coding key
  `filtered_hidden`, encoded with `encodeIfPresent` beside the totals.
- `search`: `.where("c.is_filtered = 0")` in `SearchInternals` at `:72`
  when `!includeFiltered`. `filtered_hidden` = `COUNT(DISTINCT c.ROWID)`
  over the same builder with the predicate flipped to `!= 0` and without
  cursor, limit, or order. Factor the builder construction into a function
  that takes the predicate so both queries share every other clause. Add
  `filteredHidden: Int?` (key `filtered_hidden`) to both `SearchFlatResponse`
  and `SearchGroupedResponse`.
- `get_unread`: predicate on all three queries; add
  `.join("chat c ON cmj.chat_id = c.ROWID")` to the totals query first.
  `filtered_hidden` = `COUNT(DISTINCT cmj.chat_id)` with the same unread
  predicates and `c.is_filtered != 0`. Add `filteredHidden: Int?` to both
  response structs.
- `find_chat`: `filteredSQL(includeFiltered:)` fragment appended at the
  four sites. `filtered_hidden` = number of candidate rows the same query
  returns with the fragment flipped to `!= 0`, capped by the query's own
  LIMIT (exactness is not required here; the README says "at least").
  Add `filteredHidden: Int?` to `Response`.

**Verify**: `cd swift && swift test --filter "ListChatsToolTests\|SearchToolTests\|GetUnreadToolTests\|FindChatToolTests\|GetMessagesToolTests\|ResponseContractTests\|ListToolCharacterizationTests"`
reports 0 failures with the new tests green and no edits to existing
tests. Commit 2.

### Step 5: Docs

`README.md`:

- Under `### list_chats` (`:265`) add an example line
  `list_chats(include_filtered=True)   # Also show junk / unknown-sender chats`
  and one sentence: "By default, chats Messages.app has filtered into
  Unknown Senders or Junk are hidden. The response carries
  `filtered_hidden`, the number of chats the filter removed; pass
  `include_filtered=True` to see them."
- Same sentence, shortened, under `### search` (`:274`), `### get_unread`
  (`:306`), and `### find_chat` (`:223`), each with one example line.
- Under `### get_messages` (`:241`) add: "Explicit `chat_id` lookups are
  never filtered."

`using-imessage-max/SKILL.md`: in the "Why" list after `:35` add
"`list_chats`, `search`, `get_unread`, and `find_chat` hide junk and
unknown-sender chats by default and report how many in `filtered_hidden`.
Only pass `include_filtered=true` when the user asks about a message that
did not show up."

**Verify**: `grep -c "include_filtered" README.md` is at least 5;
`grep -n "include_filtered" using-imessage-max/SKILL.md` finds the new
line. `cd swift && swift build && swift test` reports 376 tests, 0
failures (370 plus 6 new). Commit 3.

### Step 6: Live sanity check (no code change)

Run the built server against the live database and call `list_chats`
with `since: "7d"`. Expect roughly 29 chats and `filtered_hidden` around 4
(the numbers drift with new messages). Then call `list_chats` with
`include_filtered: true` and confirm the extra rows are the short-code
and RCS-agent chats, not conversations with saved contacts. If a chat
with a resolved contact name appears only under `include_filtered: true`,
that is a STOP condition: Apple's bitmask has a bit this plan
misunderstands. Report which chat (by id, not by content).

## Test plan

- 6 new tests: one per discovery tool (4), `get_unread` in both formats
  counts as one test with two assertions blocks, and the explicit-id
  guard in `GetMessagesToolTests`.
- Existing `ResponseContractTests`, `ListToolCharacterizationTests`,
  `ListChatsToolTests`, `SearchToolTests`, `GetUnreadToolTests`,
  `FindChatToolTests` unchanged and green.
- Manual live check per Step 6.

## Done criteria

- [ ] `grep -n "is_filtered" swift/Tests/iMessageMaxTests/ToolTestSupport.swift` shows the column and the `insertChat` parameter.
- [ ] `grep -c '"include_filtered"' swift/Sources/iMessageMax/Tools/ListChats.swift swift/Sources/iMessageMax/Tools/Search.swift swift/Sources/iMessageMax/Tools/GetUnread.swift swift/Sources/iMessageMax/Tools/FindChat.swift` is 2 per file (schema plus argument read).
- [ ] `grep -n "is_filtered" swift/Sources/iMessageMax/Tools/GetMessages.swift swift/Sources/iMessageMax/Tools/GetMessagesInternals.swift swift/Sources/iMessageMax/Tools/GetChatDetails.swift swift/Sources/iMessageMax/Tools/GetContext.swift swift/Sources/iMessageMax/Tools/ListAttachments.swift` prints nothing.
- [ ] `grep -n "filtered_hidden" swift/Sources/iMessageMax/Tools/*.swift | wc -l` is at least 5 (list_chats, search flat, search grouped, unread messages, unread summary, find_chat).
- [ ] `git diff main -- docs/conformance-baseline.yml swift/Tests/iMessageMaxTests/ResponseContractTests.swift swift/Tests/iMessageMaxTests/CapabilityContractTests.swift` is empty.
- [ ] `cd swift && swift test` reports 376 tests, 0 failures.
- [ ] Three commits on `advisor/074-is-filtered-junk-chats`, not pushed.

## STOP conditions

- The drift check shows in-scope changes and the excerpts no longer match.
- The live database has no `is_filtered` column on `chat` (`sqlite3 -readonly ~/Library/Messages/chat.db "PRAGMA table_info(chat)" | grep is_filtered` prints nothing). The plan's premise is wrong for this macOS version.
- Step 6 shows a saved-contact conversation hidden by the default.
- `ResponseContractTests` or `ListToolCharacterizationTests` need an edit to pass.
- The `search` count query cannot share the builder without duplicating the ~80 lines of filter logic in `SearchInternals.swift:73-140`. Report; do not copy-paste the block.

## Maintenance notes

- The predicate is `c.is_filtered = 0` everywhere. If Apple's bitmask
  ever needs per-bit handling, add one function
  `ChatFilter.shownPredicate(alias:)` and route all five query sites
  through it rather than editing them individually.
- `get_active_conversations` still counts filtered chats. If it starts
  surfacing spam threads, the same predicate goes after its
  `JOIN chat c` (see plan 071's QueryBuilder migration for the file's
  shape).
- `filtered_hidden` semantics differ slightly per tool (scoped to the
  window for `list_chats` and `get_unread`, to the match set for `search`,
  bounded by the candidate LIMIT for `find_chat`). The README wording
  "the number of chats the filter removed from this view" covers all four;
  keep it that way rather than promising exact global counts.
