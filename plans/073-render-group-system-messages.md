# Plan 073: Render group system messages (renames, joins, leaves) instead of showing blank rows

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 639529e..HEAD -- swift/Sources/iMessageMax/Tools/GetMessages.swift swift/Sources/iMessageMax/Tools/GetMessagesInternals.swift swift/Sources/iMessageMax/Utilities/ChatSummaryQueries.swift swift/Sources/iMessageMax/Utilities/PreviewResolvers.swift swift/Sources/iMessageMax/Utilities/IdentityDisplayFormatter.swift swift/Sources/iMessageMax/Models/ResponsePrimitives.swift swift/Tests/iMessageMaxTests/ToolTestSupport.swift swift/Tests/iMessageMaxTests/GetMessagesToolTests.swift swift/Tests/iMessageMaxTests/ListChatsToolTests.swift README.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW (additive response field; existing fields unchanged)
- **Depends on**: nothing
- **Category**: direction
- **Planned at**: commit `639529e`, 2026-09-01. Baseline: `cd swift && swift build && swift test` passes with 370 tests, 0 failures.

## Why this matters

Apple stores group events (someone renamed the chat, added a member,
left) as `message` rows with `item_type != 0`, `text IS NULL`, and
`attributedBody IS NULL`. The event's payload lives in three other
columns: `group_action_type`, `group_title`, and `other_handle`. The
server does not read any of them (`grep -rn "item_type\|group_title\|other_handle" swift/Sources` prints nothing), so today:

- `get_messages` returns these rows as `{"id": ..., "text": null, "from": "unknown"}`
  (or `"from": "<whoever>"`), which an agent can only describe as "an
  empty message".
- `list_chats`, `get_unread`, and `search` previews built by
  `ChatSummaryQueries.lastMessagesByChat` can pick one of these rows as
  the chat's newest message and render an attachment placeholder for a
  message that has no attachment.

On the operator's live database (read-only `sqlite3` on 2026-09-01) the
counts are large enough to matter:

| item_type | group_action_type | rows | meaning (from the columns that are set) |
|---|---|---|---|
| 1 | 0 | 425 | participant added; `other_handle` is a `handle.ROWID` on every row |
| 1 | 1 | 206 | participant removed; `other_handle` set on every row |
| 2 | 0 | 216 | renamed; `group_title` set on every row |
| 3 | 0 to 6 | 220 | participant left (variants; 4 rows carry `other_handle`) |
| 4 | 0 | 147 | other (44 rows carry `other_handle`) |
| 5 | 0 | 222 | other |
| 6 | 0 | 83 | other (26 rows are `is_from_me = 1`) |

Every one of these rows has `text IS NULL AND attributedBody IS NULL`.

The fix is to surface them as a small structured `event` on the message
and a short phrase in previews, so an agent can say "Alice renamed the
group to Trip" instead of guessing.

## Current state

### get_messages query and row

`swift/Sources/iMessageMax/Tools/GetMessagesInternals.swift:3-10`:

```swift
struct MessageRow {
    let id: Int
    let guid: String
    let text: String?
    let date: Int64?
    let isFromMe: Bool
    let senderHandle: String?
}
```

`GetMessagesInternals.swift:228-241` (inside `queryMessages`):

```swift
            .select(
                "m.ROWID as id",
                "m.guid",
                "m.text",
                "m.attributedBody",
                "m.date",
                "m.is_from_me",
                "h.id as sender_handle"
            )
            .from("message m")
            .join("chat_message_join cmj ON m.ROWID = cmj.message_id")
            .leftJoin("handle h ON m.handle_id = h.ROWID")
            .where("cmj.chat_id = ?", chatId)
            .where("m.associated_message_type = 0")
```

and the row mapping at `:299-306`:

```swift
                id: Int(row.int(0)),
                guid: row.string(1) ?? "",
                text: MessageTextExtractor.extract(text: row.string(2), attributedBody: row.blob(3)),
                date: row.optionalInt(4),
                isFromMe: row.int(5) == 1,
                senderHandle: row.string(6)
```

Note there is no `item_type` filter: system rows already flow through
this query. This plan renders them; it does not change which rows are
returned.

### get_messages response

`swift/Sources/iMessageMax/Tools/GetMessages.swift:34-52`:

```swift
    struct MessageInfo: Encodable {
        let id: String
        let ts: String?
        let text: String?
        let from: String
        let reactions: [String]?
        let media: [MediaInfo]?
        let attachments: [AttachmentSummary]?
        let links: [String]?
        let sessionId: String?
        let sessionStart: Bool?
        let sessionGapHours: Double?

        private enum CodingKeys: String, CodingKey {
            case id, ts, text, from, reactions, media, attachments, links
            case sessionId = "session_id"
            case sessionStart = "session_start"
            case sessionGapHours = "session_gap_hours"
        }
    }
```

Constructed at `GetMessages.swift:400-410`. The sender key is computed at
`:306-313`:

```swift
            let fromKey: String
            if row.isFromMe {
                fromKey = "me"
            } else if let handle = row.senderHandle {
                fromKey = handleToKey[handle] ?? handle
            } else {
                fromKey = "unknown"
            }
```

Optional fields are omitted when nil (`Encodable` default with optionals),
so adding an optional `event` changes nothing for ordinary rows.

### Previews

`swift/Sources/iMessageMax/Utilities/ChatSummaryQueries.swift:236-272`
(`lastMessagesByChat`) selects, in both CTE forms:

```sql
                SELECT i.chat_id, m.text, m.attributedBody, m.is_from_me,
                       h.id as sender_handle, m.date, m.ROWID as message_id
```

mapped into `RawRow` at `:285-294`, then at `:300-345` the sender name is
resolved via `IdentityDisplayFormatter.displayName(handle:resolver:)` and
the preview text via
`MessagePreviewResolver.messageSummary(db:messageId:text:attributedBody:maxLength:)`
(`swift/Sources/iMessageMax/Utilities/PreviewResolvers.swift:4-22`), which
falls through to `SummaryPreviewFormatter.attachmentPlaceholder(for:)`
when both text and attributedBody are nil.

`swift/Sources/iMessageMax/Models/ResponsePrimitives.swift:24-29`:

```swift
struct LastMessageSummary: Codable {
    let from: String
    let text: String
    let ago: String?
    let ts: String?
}
```

### Name resolution helper

`swift/Sources/iMessageMax/Utilities/IdentityDisplayFormatter.swift:16-19`:

```swift
    static func displayName(handle: String, resolver: ContactResolver) async -> String {
        let contactName = await resolver.resolve(handle)
        return displayName(handle: handle, contactName: contactName)
    }
```

### Test fixture

`swift/Tests/iMessageMaxTests/ToolTestSupport.swift:145-157` defines the
fixture `message` table inline with twelve columns (`ROWID, guid, text,
attributedBody, date, is_from_me, is_read, handle_id,
associated_message_type, associated_message_guid, error, is_sent`), and
`insertMessage(...)` at `:63-92` inserts exactly those twelve. The schema
is not generated from anywhere else, so adding columns is a local edit.

`makeGetMessagesFixture()` at `GetMessagesToolTests.swift:246-299` builds
chat 20 (handles 1 and 2, no display name) with messages 200, 201, 202,
203 and reaction 400; `testExactChatIdReturnsMessagesAndGeneratedChatName`
asserts `messages.count == 4` for chat 20. Any system row added to chat
20 changes that count, so add system rows to a new chat instead.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `cd swift && swift build` | ends in `Build complete!` |
| Focused | `cd swift && swift test --filter "GetMessagesToolTests\|ListChatsToolTests\|ResponseContractTests"` | 0 failures |
| Whole suite | `cd swift && swift test` | 370 plus new tests, 0 failures |
| Live spot check | `sqlite3 -readonly ~/Library/Messages/chat.db "SELECT item_type, group_action_type, COUNT(*) FROM message WHERE item_type != 0 GROUP BY 1,2"` | the table in "Why this matters" |

## Scope

In scope:

- Fixture: four new nullable columns on `message` (`item_type INTEGER DEFAULT 0`,
  `group_action_type INTEGER DEFAULT 0`, `group_title TEXT`, `other_handle INTEGER DEFAULT 0`)
  and matching optional parameters on `insertMessage`.
- A shared `GroupEvent` model plus a classifier from the four raw columns.
- `get_messages`: `MessageInfo.event` (optional), populated for
  `item_type != 0` rows; `text` stays `null` for those rows.
- Previews: `lastMessagesByChat` renders a short phrase for system rows.
- `README.md` `### get_messages` section documents the field.

Out of scope:

- Filtering system rows out (a follow-up could add `include_events`;
  not now).
- `search`, `get_context`, and `get_unread` message lists. They share
  `associated_message_type = 0` predicates but have their own row types;
  they can adopt `GroupEvent` later.
- Guessing meanings for `item_type` 4, 5, 6. They map to `"other"` and
  carry the raw `item_type` so nothing is lost.
- Touching `.mcp.json` (never), committing secrets (never), `Task.sleep`
  under `swift/Sources` (never; `LaunchdSafetyTests` enforces it).
- `docs/conformance-baseline.yml` lists MCP conformance-suite expected
  failures, not tool response shapes; it does not change. None of the
  `ResponseContractTests` cases decode `get_messages` message rows, so
  they do not change either. Say so in the commit body.

## Git workflow

- Branch: `git checkout -b advisor/073-render-group-system-messages main`.
- Commit 1 (after Step 2): `test: add group event columns to the message fixture`
- Commit 2 (after Step 4): `feat(get_messages): render group system messages as an event object`
- Commit 3 (after Step 5): `feat(previews): describe group events in last-message previews`
- Commit 4 (after Step 6): `docs: document the get_messages event field`
- Do not push, do not merge.

## Steps

### Step 1: Fixture columns

In `ToolTestSupport.swift` extend the `CREATE TABLE message` block at
`:145-157` with:

```sql
            is_sent INTEGER DEFAULT 0,
            item_type INTEGER DEFAULT 0,
            group_action_type INTEGER DEFAULT 0,
            group_title TEXT,
            other_handle INTEGER DEFAULT 0
```

Extend `insertMessage` with trailing parameters
`itemType: Int = 0, groupActionType: Int = 0, groupTitle: String? = nil, otherHandle: Int = 0`
and add them to the INSERT column and value lists. Existing callers do
not change.

**Verify**: `cd swift && swift build --build-tests` ends in `Build complete!`
and `cd swift && swift test` still reports 370 tests, 0 failures. Commit 1.

### Step 2: Tests first (red)

Add to `GetMessagesToolTests.swift` a new fixture function
`makeGroupEventFixture()` that creates chat 40 with handles 1
(`+15550000001`) and 2 (`+15550000002`), one ordinary message, and four
system rows, dated a minute apart:

| rowId | itemType | groupActionType | groupTitle | otherHandle | handleId | isFromMe |
|---|---|---|---|---|---|---|
| 500 | 2 | 0 | `"Trip"` | 0 | 1 | false |
| 501 | 1 | 0 | nil | 2 | 1 | false |
| 502 | 1 | 1 | nil | 2 | 1 | false |
| 503 | 3 | 0 | nil | 0 | 2 | false |
| 504 | 5 | 0 | nil | 0 | nil | false |

Then three tests:

1. `testGroupEventsAreRenderedAsEventObjects`: `get_messages(chat_id: "chat40", limit: 10)`;
   for each of the five rows assert `text` is nil and `event` decodes to,
   respectively:
   `{"type":"rename","title":"Trip"}`,
   `{"type":"participant_added","participant":"<display name of +15550000002>"}`,
   `{"type":"participant_removed","participant":"<same>"}`,
   `{"type":"left"}`,
   `{"type":"other","item_type":5}`.
   The participant display name comes from `makeSeededResolver()`; read
   its seed map to get the exact expected string.
2. `testOrdinaryMessagesHaveNoEventKey`: in the same response the ordinary
   message's dictionary has no `"event"` key at all (not `null`).
3. `testExistingFixtureIsUnchanged`: `testExactChatIdReturnsMessagesAndGeneratedChatName`
   still asserts 4 messages for chat 20; no edit to that test.

Add to `ListChatsToolTests.swift` a test `testLastMessagePreviewDescribesGroupEvents`:
a chat whose newest row is a rename by handle 1 to `"Trip"`; run
`ListChatsTool.execute(limit: 5, sort: "recent", cursor: nil, db:, resolver: ContactResolver(seedCache: [:]))`
and assert the chat's `last_message.text == "renamed the group to Trip"`
and `last_message.from` is the formatted handle. Then a second chat whose
newest row is `item_type 1, group_action_type 0, other_handle 2` and
assert `text == "added <display name of handle 2>"`.

**Verify**: `cd swift && swift build --build-tests` fails to compile on the
new `event` accessor or the tests fail on missing keys. Expected red.

### Step 3: Model and classifier

Create `swift/Sources/iMessageMax/Models/GroupEvent.swift`:

```swift
/// A group-chat system message (rename, membership change, leave).
/// Apple stores these as `message` rows with `item_type != 0` and no text.
struct GroupEvent: Encodable, Equatable {
    enum Kind: String, Encodable {
        case rename, participantAdded = "participant_added",
             participantRemoved = "participant_removed", left, other
    }
    let type: Kind
    let title: String?          // rename only
    let participant: String?    // added/removed, resolved display name
    let itemType: Int?          // set only for .other

    private enum CodingKeys: String, CodingKey {
        case type, title, participant
        case itemType = "item_type"
    }

    /// Classifies the raw columns. `otherHandleId` is the `handle.id` string
    /// already joined from `message.other_handle`, or nil.
    static func classify(itemType: Int, groupActionType: Int, groupTitle: String?, otherHandleName: String?) -> GroupEvent?
    /// Short preview phrase, e.g. "renamed the group to Trip".
    var previewText: String { get }
}
```

`classify` returns nil for `itemType == 0`. Mapping:

- `1, 0` → `.participantAdded` with `participant: otherHandleName ?? "someone"`.
- `1, 1` → `.participantRemoved` likewise.
- `2, _` → `.rename` with `title: groupTitle` (title may be nil if the
  row is malformed; keep the type anyway).
- `3, _` → `.left`.
- anything else nonzero → `.other` with `itemType`.

`previewText`: `"renamed the group to <title>"` (or `"renamed the group"`
when title is nil), `"added <participant>"`, `"removed <participant>"`,
`"left the group"`, `"[group event]"`.

**Verify**: `cd swift && swift build` ends in `Build complete!`.

### Step 4: get_messages

- `MessageRow` gains `itemType: Int`, `groupActionType: Int`,
  `groupTitle: String?`, `otherHandle: String?`.
- The select in `queryMessages` adds `"m.item_type"`, `"m.group_action_type"`,
  `"m.group_title"`, `"oh.id as other_handle_id"` and a
  `.leftJoin("handle oh ON m.other_handle = oh.ROWID")`. Map them at
  indices 7 to 10 with `Int(row.int(7))`, `Int(row.int(8))`, `row.string(9)`,
  `row.string(10)`. SQLite returns 0 for `row.int` on NULL through this
  wrapper; confirm by reading `Database.Row.int` before relying on it.
- `MessageInfo` gains `let event: GroupEvent?` and `case event` in
  `CodingKeys`.
- In the loop at `GetMessages.swift:305-411`, before building `MessageInfo`,
  resolve the participant name once per distinct `otherHandle` with
  `IdentityDisplayFormatter.displayName(handle:resolver:)` (collect the
  handles first and resolve in one pass, the way `ChatSummaryQueries`
  does at `:297-305`, so a page of 50 messages does not make 50 resolver
  calls), then `event: GroupEvent.classify(...)`.
- Leave `text` as-is (nil for system rows) and `from` as-is (the
  `handle_id` of a rename row is the renamer; `"unknown"` when nil).

**Verify**: `cd swift && swift test --filter GetMessagesToolTests` reports
13 tests, 0 failures. Commit 2.

### Step 5: Previews

In `ChatSummaryQueries.lastMessagesByChat`:

- Both SELECTs at `:241-242` and `:259-260` add
  `m.item_type, m.group_action_type, m.group_title, oh.id as other_handle_id`
  and both add `LEFT JOIN handle oh ON m.other_handle = oh.ROWID` after the
  existing `LEFT JOIN handle h`.
- `RawRow` gains the four fields; the mapping closure reads indices 7 to 10.
- In the name-resolution pass at `:297-305`, add `other_handle_id` values
  to the set of handles resolved.
- When `GroupEvent.classify(...)` returns non-nil, use its `previewText`
  as the `LastMessageSummary.text` instead of calling
  `MessagePreviewResolver.messageSummary`. Otherwise unchanged.

**Verify**: `cd swift && swift test --filter "ListChatsToolTests\|GetUnreadToolTests\|SearchToolTests\|ResponseContractTests\|ListToolCharacterizationTests"`
reports 0 failures. Commit 3.

### Step 6: Docs and full suite

In `README.md` under `### get_messages` (line 241), after the example
block, add:

```markdown
Group system messages (renames, members added or removed, someone
leaving) come back with `text: null` and an `event` object:
`{"type": "rename", "title": "Trip"}`, `{"type": "participant_added", "participant": "Alice"}`,
`{"type": "participant_removed", ...}`, `{"type": "left"}`, or
`{"type": "other", "item_type": N}` for event kinds the server does not
name. Chat previews describe the same events in words
("renamed the group to Trip").
```

Check `using-imessage-max/SKILL.md` for any sentence describing blank or
empty messages (`grep -n -i "empty\|blank" using-imessage-max/SKILL.md`);
if one exists, adjust it, otherwise leave the skill alone.

**Verify**: `cd swift && swift build && swift test` reports 374 tests, 0
failures (370 plus 3 in `GetMessagesToolTests` plus 1 in
`ListChatsToolTests`). Commit 4.

## Test plan

- `GetMessagesToolTests`: 3 new tests (event objects, no key on ordinary
  rows, existing fixture count unchanged).
- `ListChatsToolTests`: 1 new test for preview phrases.
- All existing tests unchanged, including `ResponseContractTests`.
- Manual: with the built binary pointed at the live db, call
  `get_messages` on a group chat known to have been renamed and confirm
  the rename row shows `event.type == "rename"` with the expected title.
  Do not paste live message text into the commit or the plan.

## Done criteria

- [ ] `grep -n "item_type" swift/Tests/iMessageMaxTests/ToolTestSupport.swift` shows the column and the `insertMessage` parameter.
- [ ] `swift/Sources/iMessageMax/Models/GroupEvent.swift` exists.
- [ ] `grep -n "other_handle" swift/Sources/iMessageMax/Tools/GetMessagesInternals.swift swift/Sources/iMessageMax/Utilities/ChatSummaryQueries.swift` shows the join in both files.
- [ ] `grep -n '"event"\|case event' swift/Sources/iMessageMax/Tools/GetMessages.swift` finds the coding key.
- [ ] `grep -n "event" README.md` shows the new get_messages paragraph.
- [ ] `git diff main -- swift/Tests/iMessageMaxTests/ResponseContractTests.swift docs/conformance-baseline.yml` is empty.
- [ ] `cd swift && swift test` reports 374 tests, 0 failures.
- [ ] Four commits on `advisor/073-render-group-system-messages`, not pushed.

## STOP conditions

- The drift check shows in-scope changes and the excerpts no longer match.
- `Database.Row.int` traps or returns something other than 0 on NULL, so the four new columns need different handling. Report before changing the wrapper.
- Adding the `oh` join changes the row count or ordering of any existing `GetMessagesToolTests` or `ListChatsToolTests` case (a LEFT JOIN on `ROWID` should not, but `other_handle` values that point at deleted handles are the case to watch).
- The live spot check shows `item_type = 2` rows with `group_title IS NULL`, or `item_type = 1` rows with `other_handle = 0`, in numbers large enough that the classifier's defaults would be the common path. Report the counts.
- Any `ResponseContractTests` case fails.

## Maintenance notes

- `GroupEvent.classify` is the single place that knows Apple's `item_type`
  encoding. When a meaning for 4, 5, or 6 is confirmed, add a case there
  and a fixture row; do not special-case in tool files.
- `search`, `get_context`, and `get_unread` message rows still render
  system rows as blank text. Adopting `GroupEvent` there is a small
  follow-up once this shape has been used for a while.
- If a future plan adds `include_events: false` to `get_messages`, the
  predicate is `m.item_type = 0`, and the fixture already has rows to test it.
