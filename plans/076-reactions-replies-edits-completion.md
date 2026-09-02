# 076: Reactions, replies, and edits completion

Planned at commit `639529e` on 2026-09-01. Baseline: `cd swift && swift build && swift test` passes with 370 tests, 0 failures.

## Executor instructions

Read this whole file before touching anything. Then run the drift check. If any line disagrees with what this plan quotes, stop and report the difference instead of adapting on the fly.

### Drift check

```bash
cd /Users/robdezendorf/Documents/GitHub/imessage-max
git rev-parse --short HEAD                                            # expect 639529e or a descendant
git log --oneline -1 --grep='068' main                                # expect a merged 068 commit; this plan depends on it
grep -n 'case love = 2000\|type >= 3000 && type < 3006' swift/Sources/iMessageMax/Models/Reactions.swift   # expect both
grep -n 'associated_message_type >= 2000' swift/Sources/iMessageMax/Tools/GetMessagesInternals.swift        # expect :330 area
grep -n 'associated_message_emoji\|thread_originator_guid\|date_edited' swift/Tests/iMessageMaxTests/ToolTestSupport.swift   # expect no output
grep -n 'reactions: \[String\]?' swift/Sources/iMessageMax/Tools/GetMessages.swift    # expect :38 area
grep -n 'XCTAssertEqual(reactions, \["❤️ alice"\])' swift/Tests/iMessageMaxTests/GetMessagesToolTests.swift   # expect :101
```

## Status

- Priority: P2
- Size: M
- Kind: direction (additive response fields)
- Depends on: 068 (message-shape groundwork; must be merged first)
- Blocks: nothing

## Why

The reader tools show only a slice of what chat.db records about a message. On the live database on 2026-09-01 (read-only, `sqlite3 -readonly ~/Library/Messages/chat.db`):

| Signal | Rows | Currently surfaced |
|--------|------|--------------------|
| Standard tapbacks, `associated_message_type` 2000-2005 | 46,761 | yes, as `"❤️ alice"` strings |
| Custom emoji reactions, type 2006 | 3,274 | dropped (no `ReactionType` case) |
| Sticker reactions, type 2007 | 238 | dropped |
| Removals, type 3000-3007 | 69 | skipped, but the matching 200x row is still shown, so removed reactions look live |
| Replies, `thread_originator_guid` set | 9,640 | not surfaced at all |
| Edited, `date_edited != 0` | 1,480 | not surfaced |
| Unsent, `date_retracted != 0` | 0 | nothing to surface; stays out |

Two of those are silent correctness bugs today. A custom-emoji reaction is not a rare edge: it is the seventh most common reaction type and the emoji is sitting in a column (`associated_message_emoji`) the query never selects. And a removed tapback is still reported as present because the removal is skipped instead of applied.

Replies and edits are additive: a model reading a thread cannot tell that "yes" was an answer to a message from two hours ago, and cannot tell that a message was edited after the fact.

Unsend stays out. Zero live rows means no fixture can be validated against reality.

## Current state

### Reaction model

```swift
// swift/Sources/iMessageMax/Models/Reactions.swift
enum ReactionType: Int {
    case love = 2000
    case like = 2001
    case dislike = 2002
    case laugh = 2003
    case emphasize = 2004
    case question = 2005

    static func isRemoval(_ type: Int) -> Bool {
        type >= 3000 && type < 3006
    }

    var emoji: String { ... }
}
```

`isRemoval` stops at 3005. Live data has 8 rows of 3006 and 1 row of 3007 (removal of a custom emoji and of a sticker). The bound must extend to 3007 as part of adding 2006 and 2007.

Live counts also show 12 rows of type 4000 and 4 of 4001. Their meaning is not established; leave them unmapped and unfiltered as today. Note them in the doc comment so nobody mistakes the omission for an oversight.

### Reaction query and rendering

```swift
// swift/Sources/iMessageMax/Tools/GetMessagesInternals.swift:310-347 (excerpt)
static func getReactionsMap(messageGuids: [String], ...) -> [String: [(type: Int, fromHandle: String?)]]
    ... WHERE m.associated_message_guid IN (...) AND m.associated_message_type >= 2000
```

The map strips the `p:` and `bp:` prefixes from `associated_message_guid`. Live sample of a 2006 row:

```
p:0/0E72F4E3-213C-4ECB-979B-AC6B542E632F|🥕
```

so the same prefix handling covers custom emoji. The query selects `type` and handle only; it does not select `associated_message_emoji`, and it does not select `date`, which the removal-cancellation logic below needs.

```swift
// swift/Sources/iMessageMax/Tools/GetMessages.swift:315-330 (excerpt)
guard let reactionType = ReactionType(rawValue: r.type), !ReactionType.isRemoval(r.type) else { continue }
...
reactionStrings.append("\(reactionType.emoji) \(reactor)")
```

Type 2006 fails `ReactionType(rawValue:)` and is dropped. Removals are skipped without cancelling anything.

### Message row and select

```swift
// GetMessagesInternals.swift:3-10
struct MessageRow {
    let id: Int64
    let guid: String
    let text: String?
    let date: Int64?
    let isFromMe: Bool
    let senderHandle: String?
}
```

The select at `:230-240` filters `m.associated_message_type = 0` and does not read `thread_originator_guid` or `date_edited`. Live sample of a reply row:

```
7324BD61-984D-4E99-AE0C-AA7167D33659|0:0:1
```

`thread_originator_guid` is a bare message guid (no `p:` prefix) and is covered by Apple's own index `message_idx_thread_originator_guid`, confirmed present in `sqlite_master`.

### Response shape

```swift
// GetMessages.swift:34-49
struct MessageInfo: Codable {
    let id: String
    let ts: String
    let text: String?
    let from: String
    let reactions: [String]?
    let media: ...
    let attachments: ...
    let links: ...
    let sessionId: ...
    let sessionStart: ...
    let sessionGapHours: ...
}
```

`SearchResult` and `SearchContextMessage` (`Search.swift:18-40`) and `ContextMessage` (`GetContext.swift:5-34`, fields `id, from, text, ago, ts`) carry no reactions, reply, or edited fields. `GetChatDetails.swift` has no per-message struct beyond `LastMessageSummary`, so it is out of scope for mirroring.

### Fixture

`swift/Tests/iMessageMaxTests/ToolTestSupport.swift:145-157` creates the `message` table without `associated_message_emoji`, `thread_originator_guid`, or `date_edited`. The `insertMessage` helper at `:62-93` has no parameters for them. Both must grow.

The existing reaction assertion:

```swift
// GetMessagesToolTests.swift:100-101
let reactions = try XCTUnwrap(target["reactions"] as? [String])
XCTAssertEqual(reactions, ["❤️ alice"])
```

with the fixture row at `:286`:

```swift
try fixture.insertMessage(rowId: 400, guid: "reaction-love", text: nil, date: base + (3 * minute), isFromMe: false, handleId: 1, associatedMessageType: 2000, associatedMessageGuid: "gm201")
```

### Docs and contract pins

`README.md:241` `### get_messages` has no reaction documentation. `docs/conformance-baseline.yml` has no reaction or reply entries. `CapabilityContractTests` and `ResponseContractTests` pin `tapbacks: unsupported` and `edit_unsend: unsupported` in `diagnose` (`Diagnose.swift:283-284`). Those capabilities describe the ability to *send* a tapback or edit, which this plan does not add. They stay `unsupported`, and the contract tests are not touched. Say so explicitly in the README change so a reader does not see `reactions` in output and expect `tapbacks: supported`.

## Commands

| Purpose | Command | Expect |
|---------|---------|--------|
| Build | `cd swift && swift build` | `Build complete!` |
| Full suite | `cd swift && swift test` | 370 + new tests, 0 failures |
| Messages tests | `cd swift && swift test --filter GetMessagesToolTests` | 0 failures |
| Search tests | `cd swift && swift test --filter SearchToolTests` | 0 failures |
| Contract tests untouched | `cd swift && swift test --filter 'CapabilityContractTests\|ResponseContractTests'` | 0 failures |
| Live spot check (read-only) | `sqlite3 -readonly ~/Library/Messages/chat.db "SELECT associated_message_type, COUNT(*) FROM message WHERE associated_message_type>=2000 GROUP BY 1"` | includes `2006\|3274` and `2007\|238` at planning time |

## Scope

### In

(a) `ReactionType`: add `customEmoji = 2006` and `sticker = 2007`; extend `isRemoval` to `< 3008`; carry the emoji text for 2006 from `associated_message_emoji`; render 2007 as a fixed `"🩵 sticker"`-style token (pick one literal and document it).

(b) Removal cancellation: a 300x row cancels the most recent 200x row with the same `(target guid, from handle, type - 1000)` that has an earlier `date`. Requires selecting `date` in `getReactionsMap`.

(c) `reply_to: String?` (formatted like `id`, i.e. `msg_<rowid>` of the originator, resolved by guid lookup in a single batched query) and `reply_count: Int?` (count of rows whose `thread_originator_guid` equals this message's guid, batched with `GROUP BY`). Both omitted when zero or absent.

(d) `edited: Bool?` set to `true` when `date_edited != 0`, omitted otherwise.

(e) Mirror `reactions`, `reply_to`, `reply_count`, `edited` onto `SearchResult`, `SearchContextMessage`, and `ContextMessage`. All optional, all omitted when empty.

Fixture columns, `insertMessage` parameters, tests, README.

### Out

- Unsend / `date_retracted` (0 live rows).
- Types 4000 and 4001.
- Sending tapbacks, edits, or replies. `tapbacks` and `edit_unsend` stay `unsupported` in `diagnose`.
- `GetChatDetails` (no per-message struct to mirror onto).
- Any change to the `reactions` string format for 2000-2005. `"❤️ alice"` stays byte-identical.

## Git workflow

```bash
git checkout main && git pull --ff-only
git log --oneline --grep='068' -1        # confirm 068 merged
git checkout -b advisor/076-reactions-replies-edits-completion
```

Conventional commits, one per lettered step:

1. `test: fixture columns for emoji, thread, and edit`
2. `fix: surface custom emoji and sticker reactions`
3. `fix: apply reaction removals`
4. `feat: reply_to and reply_count on messages`
5. `feat: edited flag on messages`
6. `feat: mirror reaction and reply fields onto search and context`
7. `docs: document reactions, replies, and edits in README`

Executor does not push or merge.

Standing rules: never add `Task.sleep` under `swift/Sources` (`LaunchdSafetyTests` enforces); never touch `.mcp.json`; never commit secrets; leave `advisor/018-imcore-helper-bridge` and `advisor/019-imcore-helper-dylib` alone.

## Steps

### Step 1: Grow the fixture

In `ToolTestSupport.swift`, add `associated_message_emoji TEXT`, `thread_originator_guid TEXT`, `date_edited INTEGER DEFAULT 0` to the `message` DDL at `:145-157`. Add matching optional parameters (`associatedMessageEmoji: String? = nil`, `threadOriginatorGuid: String? = nil`, `dateEdited: Int64 = 0`) to `insertMessage` at `:62-93`. Defaults keep every existing call site compiling unchanged.

Verify:

```bash
cd swift && swift test     # expect 370 tests, 0 failures; nothing behaves differently yet
```

Commit 1.

### Step 2: Custom emoji and stickers (test first)

Add to `makeGetMessagesFixture` in `GetMessagesToolTests.swift` (after the `:286` row):

```swift
try fixture.insertMessage(rowId: 401, guid: "reaction-carrot", text: nil, date: base + (3 * minute) + 1, isFromMe: false, handleId: 2, associatedMessageType: 2006, associatedMessageGuid: "p:0/gm201", associatedMessageEmoji: "🥕")
try fixture.joinChatMessage(chatId: 20, messageId: 401)
try fixture.insertMessage(rowId: 402, guid: "reaction-sticker", text: nil, date: base + (3 * minute) + 2, isFromMe: true, associatedMessageType: 2007, associatedMessageGuid: "p:0/gm201")
try fixture.joinChatMessage(chatId: 20, messageId: 402)
```

Change the assertion at `:101` to the new expected list, ordered by reaction date: `["❤️ alice", "🥕 <handle2 name>", "<sticker token> me"]`. Look up how the fixture names handle 2 and how `from` renders the local user before writing the literal.

Run, expect failure. Then:

- `Reactions.swift`: add cases 2006, 2007; `isRemoval` bound to `< 3008`; doc comment listing 4000/4001 as unmapped.
- `getReactionsMap`: select `m.associated_message_emoji` and `m.date`; return tuple gains `emoji: String?` and `date: Int64`.
- `GetMessages.swift:315-330`: for 2006 use `r.emoji ?? "?"`; for 2007 use the sticker literal.

Verify: `swift test --filter GetMessagesToolTests` passes. Commit 2.

### Step 3: Removal cancellation (test first)

Add a 3000 row from handle 1 targeting `gm201` with `date: base + (5 * minute)`, joined to chat 20. Assert `"❤️ alice"` is now absent and the other two remain. Add a second test where the removal predates the reaction (date earlier) and assert the reaction is kept: a removal only cancels an earlier add.

Implement in the reaction loop: sort the target's rows by date; keep a dictionary keyed by `(handle, type)`; a 200x row inserts, a 300x row removes the entry for `(handle, type - 1000)` if present. Emit remaining entries in insertion order.

Verify: `swift test --filter GetMessagesToolTests`. Commit 3.

### Step 4: Replies (test first)

Fixture: give `gm203` a `threadOriginatorGuid: "gm201"`. Assert `msg_203` has `reply_to == "msg_201"` and `msg_201` has `reply_count == 1`, and that `msg_202` has neither key present.

Implement:

- `MessageRow` gains `threadOriginatorGuid: String?` and `dateEdited: Int64`; select both columns at `:230-240`; map at `:298-307`.
- New batched helper in `GetMessagesInternals.swift` next to `getReactionsMap`: given the page's guids, run one `SELECT guid, ROWID FROM message WHERE guid IN (...)` for originators not already on the page, and one `SELECT thread_originator_guid, COUNT(*) FROM message WHERE thread_originator_guid IN (...) GROUP BY 1` for counts. Two queries per page, never per row.
- `MessageInfo` gains `replyTo: String?` (`reply_to`) and `replyCount: Int?` (`reply_count`), both `nil` when absent or zero, encoded with `encodeIfPresent` so they are omitted.

Verify: `swift test --filter GetMessagesToolTests`. Commit 4.

### Step 5: Edited (test first)

Fixture: `gm202` gets `dateEdited: base + sixteenHours + 30`. Assert `msg_202["edited"] as? Bool == true` and `msg_201` has no `edited` key.

Implement: `MessageInfo.edited: Bool?`, set `true` when `dateEdited != 0`. Commit 5.

### Step 6: Mirror onto search and context (test first)

In `SearchToolTests.swift`, extend `makeSearchFixture` with one custom-emoji reaction, one reply, and one edit on rows the existing `testAnyWordVsMatchAll` already finds (`msg_200`, `msg_250`, `msg_300`). Add `testSearchResultsCarryReactionReplyAndEditFields`. Do the same in the get_context test file for `ContextMessage`.

Implement by reusing the same helpers from `GetMessagesInternals.swift`; do not duplicate SQL. Add the four optional fields to `SearchResult`, `SearchContextMessage`, `ContextMessage`. Existing tests that decode these structs must keep passing without edits, which is what "omitted when empty" buys.

Verify:

```bash
cd swift && swift test --filter 'SearchToolTests\|GetContextToolTests\|GetMessagesToolTests'
cd swift && swift test --filter 'CapabilityContractTests\|ResponseContractTests'   # untouched, must still pass
cd swift && swift test
```

Commit 6.

### Step 7: README

Under `README.md:241` `### get_messages`, add a short "Reactions, replies, edits" subsection: the `reactions` string format, that custom emoji show the emoji itself, the sticker literal, that removed reactions are not shown, `reply_to` / `reply_count` semantics, `edited`, and that `search` and `get_context` carry the same four fields. Add one sentence: these are read-only; `diagnose` still reports `tapbacks` and `edit_unsend` as `unsupported` because the server cannot send them.

Commit 7.

## Test plan

- New or changed tests: reactions assertion at `:101` (changed), removal cancels (new), removal before add keeps (new), reply fields (new), edited (new), search mirror (new), context mirror (new). Net +6 tests, expected total 376.
- Regression guard: every test that existed at baseline still passes unmodified except the one assertion at `GetMessagesToolTests.swift:101`.
- Contract tests unmodified and passing.

## Done criteria

- Live spot check via the MCP server against a chat known to contain a 🥕 reaction returns the emoji in `reactions`. Pick the chat with `sqlite3 -readonly ... "SELECT cmj.chat_id FROM message m JOIN chat_message_join cmj ON cmj.message_id=m.ROWID WHERE m.associated_message_type=2006 ORDER BY m.date DESC LIMIT 1"`.
- Full suite 376 tests, 0 failures.
- README updated; `docs/conformance-baseline.yml` untouched (no entry existed and none is needed for additive optional fields).
- Seven commits on `advisor/076-reactions-replies-edits-completion`, not pushed.

## STOP conditions

- Drift check fails, or 068 is not merged into `main`.
- The reply lookup cannot be done in two batched queries per page. Do not fall back to a per-row query.
- Any existing test other than `GetMessagesToolTests.swift:101` needs its assertion changed. That means a shape leaked where it should not have.
- `CapabilityContractTests` or `ResponseContractTests` fail. You touched something you should not have.
- Live spot check shows `associated_message_emoji` empty on 2006 rows in a chat where Messages.app shows an emoji reaction. Report and stop; the column may be populated differently on that macOS build.

## Maintenance notes

- If Apple adds reaction types above 2007, `ReactionType(rawValue:)` fails silently and the row is dropped, same as 2006 was. When the live count query in the Commands table shows a new type with meaningful volume, extend the enum.
- Types 4000/4001 are known-unmapped. If someone identifies them, add a case and a fixture row.
- `reply_count` counts every reply row, including ones filtered out of the page by `associated_message_type = 0`; in practice reply rows are type 0, but a tapback on a reply does not count as a reply because it has no `thread_originator_guid`.
