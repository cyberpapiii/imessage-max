# 083 — URL preview balloon rows: pin single-row behaviour, fix link filters, hide payload attachments

> **Executor instructions.** Read this whole file before touching code. Work
> on branch `advisor/083-url-preview-coalescing` from `main`. Commit after
> every step with a conventional-commit message. Write the failing test first,
> then the code. Never add `Task.sleep` under `swift/Sources`
> (`LaunchdSafetyTests` fails the build if you do). Never edit `.mcp.json`.
> If a step's **Verify** block does not match, stop and report; do not improvise.
>
> **Drift check.** This plan was written against commit `42deb1f`. Before
> starting, run:
>
> ```bash
> cd /Users/robdezendorf/Documents/GitHub/imessage-max
> git diff --stat 42deb1f..HEAD -- \
>   swift/Sources/iMessageMax/Tools/GetMessagesInternals.swift \
>   swift/Sources/iMessageMax/Tools/GetMessages.swift \
>   swift/Sources/iMessageMax/Tools/GetUnread.swift \
>   swift/Sources/iMessageMax/Tools/SearchInternals.swift \
>   swift/Sources/iMessageMax/Tools/ListAttachments.swift \
>   swift/Sources/iMessageMax/Utilities/MessageTextExtractor.swift \
>   swift/Tests/iMessageMaxTests/ToolTestSupport.swift \
>   swift/Tests/iMessageMaxTests/GetMessagesToolTests.swift \
>   swift/Tests/iMessageMaxTests/GetUnreadToolTests.swift \
>   swift/Tests/iMessageMaxTests/ListAttachmentsQueryTests.swift \
>   swift/Tests/iMessageMaxTests/SearchToolTests.swift \
>   README.md using-imessage-max/SKILL.md CHANGELOG.md
> ```
>
> `ToolTestSupport.swift` is shared with every tool test; other plans in this
> round (080–082, 084–085) may add columns to the same fixture. If it changed,
> re-read `insertMessage` / `insertAttachment` and the `CREATE TABLE` block
> before Step 1 and merge, do not overwrite. If any of the four Tools files
> changed in the regions quoted under *Current state*, re-check line numbers
> before editing.

## Status

- **Status:** TODO
- **Priority:** P2
- **Effort:** S–M (5 commits; no AppleScript, no schema beyond the test fixture)
- **Risk:** LOW — additive SQL predicates on existing queries; no new queries,
  so the query-count tests are unaffected
- **Depends on:** nothing. Touches the shared test fixture; rebase onto
  whichever of 080–082 / 084–085 merges first and re-run the drift check.
- **Category:** correctness / verification
- **Planned at:** commit `42deb1f`, 2026-09-02. Baseline: `cd swift && swift build && swift test`
  passes with 433 tests, 0 failures.

**Premise check result.** The brief for this plan was: "Messages rewrites a
link message as a `com.apple.messages.URLBalloonProvider` balloon row, so
naive readers show the link twice and count it twice in unread; borrow imsg's
dedupe." Two things were checked before writing this plan:

1. **Does imessage-max already coalesce?** No. `grep -rn "balloon\|URLBalloonProvider" swift/` matches nothing in Sources or Tests.
2. **Does the duplicate-row pattern occur on this machine?** No. On the live
   `chat.db` (macOS 26.6.2, sqlite 3.51.0, queried read-only 2026-09-02T17:46Z)
   there are 128 URLBalloonProvider rows in the last 30 days (538 in 180 d,
   1,121 in 365 d) and **0** of them are preceded by a same-sender text row
   containing the same URL within 90 s (imsg's window) — over the full 365 d.
   On this build the balloon row **is** the link message: `text` is NULL, the
   URL lives in `attributedBody`, the preview in `payload_data`, and the
   preview image is a hidden `pluginPayloadAttachment` attachment. Nothing is
   shown twice and unread counts it once.

So the imsg coalescing / dedupe port is **not needed** and is recorded below
as a deferred, guarded item (Appendix A) with the query that would justify it.
What the audit did find are two real, measurable defects in how those 128
rows are read, plus behaviour that is correct but unpinned:

| Finding | Live count (30 d) | Effect today |
|---|---|---|
| `get_messages has:"links"` and `search has:"link"` filter on `m.text LIKE '%http%'` | 128 link messages, **0** non-balloon text rows containing `http` | every link message in the last 30 days is invisible to both filters |
| hidden `pluginPayloadAttachment` rows surface as attachments (`hide_attachment=1`, mime NULL, type `other`) | 287 hidden attachment rows on 125 messages; 125 of the 471 messages with any attachment (27%) have *only* hidden ones | `get_messages` lists preview blobs as `attachments: [{type:"other", filename:"…pluginPayloadAttachment"}]`, `has:"attachments"` matches them, `list_attachments` returns them |
| `get_messages` / `get_unread` / `search` render a balloon row once with the URL as text | 128 rows, 128 with `NSString` + `http` in attributedBody, 2 unread inbound | correct, but only because `MessageTextExtractor` falls back to attributedBody; no test pins it |

This plan fixes the two defects and pins the third.

## Why this matters

A caller asking "what links did Alice send me this month" gets an empty
answer from `get_messages has:"links"` even though the `links` array on each
message (extracted in Swift from `attributedBody`) is populated when the
message is fetched without the filter. The SQL prefilter and the Swift
extraction disagree about what a link message is. Likewise "what did she
share" via `list_attachments` returns ~97 KB `pluginPayloadAttachment` blobs
that no client can open and that Messages itself hides.

### Live-DB evidence (read-only; re-run before starting)

All queries were run with `sqlite3 -readonly ~/Library/Messages/chat.db`.
`message.balloon_bundle_id` is column 53, `payload_data` 54,
`attachment.hide_attachment` exists on this schema.

```sql
-- balloon rows and how many pair with a preceding same-sender URL text row
WITH b AS (
  SELECT m.ROWID, m.date, m.handle_id, m.is_from_me, cmj.chat_id
  FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
  WHERE m.balloon_bundle_id = 'com.apple.messages.URLBalloonProvider'
    AND m.date >= (strftime('%s','now') - 30*86400 - 978307200) * 1000000000
)
SELECT
  (SELECT COUNT(*) FROM b) AS balloon_rows_30d,
  (SELECT COUNT(*) FROM b WHERE EXISTS (
     SELECT 1 FROM message p JOIN chat_message_join pc ON pc.message_id = p.ROWID
     WHERE pc.chat_id = b.chat_id AND p.ROWID < b.ROWID
       AND p.is_from_me = b.is_from_me AND p.handle_id = b.handle_id
       AND p.balloon_bundle_id IS NULL AND p.text LIKE '%http%'
       AND b.date - p.date BETWEEN 0 AND 90*1000000000)) AS paired_with_url_text_90s;
```

| Metric | Value |
|---|---|
| balloon_rows_30d | 128 |
| balloon_rows_180d / 365d | 538 / 1,121 |
| all messages 30d | 5,134 |
| preceded by *any* same-sender text row within 90 s / 5 s | 28 / 13 |
| preceded by a same-sender text row **containing http** within 90 s (30 d / 365 d) | **0 / 0** |
| balloon rows with `text` NULL | 123 of 128 |
| balloon rows whose attributedBody contains `NSString` and `http` | 128 of 128 |
| balloon rows with `payload_data` | 128 |
| balloon rows with `item_type = 0` and `associated_message_type = 0` | 128 |
| from me / inbound / inbound unread | 36 / 92 / 2 |
| non-balloon text rows containing `http` (30 d) | **0** |
| attachment rows joined to balloon rows | 287, all `hide_attachment = 1`, mime NULL, uti `dyn.age81a5dzq7y066dbtf0g82peqf4hk2pdrb00n5xy`, name ends `.pluginPayloadAttachment`, avg 97,125 B, max 542,670 B |
| messages with any attachment / with only hidden attachments (30 d) | 471 / 125 |
| other `balloon_bundle_id` values (30 d) | MSMessageExtensionBalloonPlugin business 2, chatbot 1, PhotosMessagesApp 1, FindMy 1 |

The 28 "preceded by any text within 90 s" rows are ordinary conversation
("look at this" then a link), not duplicates: none of the preceding rows
contains the URL.

## Current state

### Link filters look only at `m.text`

`swift/Sources/iMessageMax/Tools/GetMessagesInternals.swift:476-482`:

```swift
        if let has = has {
            switch has {
            case "links":
                query.where("(m.text LIKE '%http://%' OR m.text LIKE '%https://%')")
```

`swift/Sources/iMessageMax/Tools/SearchInternals.swift:145-147`:

```swift
            switch hasType {
            case "link":
                builder.where("m.text LIKE ? ESCAPE '\\'", "%http%")
```

But the row text and `links` array come from the typedstream fallback,
`GetMessagesInternals.swift:512`:

```swift
                    text: MessageTextExtractor.extract(text: row.string(2), attributedBody: row.blob(3)),
```

and `GetMessages.swift:352-413` builds `links` with `extractLinks(from: row.text)`.
So a balloon row fetched *without* `has` renders as `text: "https://…"`,
`links: ["https://…"]`, yet `has:"links"` never returns it.

### Attachment queries never filter `hide_attachment`

`GetMessagesInternals.swift:530-539` (`getAttachmentsMap`):

```swift
        let sql = """
            SELECT maj.message_id, a.ROWID, a.filename, a.mime_type, a.uti, a.total_bytes
            FROM attachment a
            JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
            WHERE maj.message_id IN (\(placeholders))
            """
```

`GetMessagesInternals.swift:480-497` (`has:"attachments"` / `has:"images"`
EXISTS subqueries), `SearchInternals.swift:148-165` (`has:"attachment"` /
`"image"` / `"video"`), `ListAttachments.swift:368-369` (join),
`:380-383` and `:413-417` (`typeClause` size subquery and EXISTS),
`:476-479` (`attachmentsForMessages`) — none mention `hide_attachment`.
`GetAttachment.swift:279` fetches by explicit ROWID and is out of scope.

`GetMessages.swift:352-413` maps each attachment to `media` (images) or
`AttachmentSummary(id: "att\(id)", type: attachmentType.rawValue, filename, size)`;
`AttachmentType.from(mimeType:uti:)` returns `other` for
`(nil, "dyn.age81a5dzq7y…")`, which is why preview blobs show as
`type: "other"`.

### Unread counts a balloon row once (correct, unpinned)

`GetUnread.swift:374-379`:

```swift
            .from("message m")
            .join("chat_message_join cmj ON m.ROWID = cmj.message_id")
            .join("chat c ON cmj.chat_id = c.ROWID")
            .where("m.is_read = 0")
            .where("m.is_from_me = 0")
            .where("m.associated_message_type = 0")
```

There is one row per link message on this build, so this is right; it needs
a test so a future dedupe (Appendix A) cannot silently double-count or
under-count.

### Test fixture lacks the two columns

`swift/Tests/iMessageMaxTests/ToolTestSupport.swift:156-176` `CREATE TABLE message`
has no `balloon_bundle_id`; `:181-188` `CREATE TABLE attachment` has no
`hide_attachment`. `insertMessage` (`:62-103`) and `insertAttachment`
(`:112-125`, `mimeType: String` is non-optional) have no matching parameters.

`GetMessagesToolTests.swift:73-82` pins `has:"links"` on chat 20 to exactly
`msg_201` (`"volcano photos? http://example.com"`); leave that fixture alone
and insert balloon rows per test (row ids 700–799 are unused across the test
suite: `grep -rn "rowId: 7[0-9][0-9]" swift/Tests` prints nothing).

The typedstream helper is private in two test files
(`SearchRecallTests.swift:72-79`, `SendVerifierTests.swift:195`):

```swift
/// Builds: <prefix junk> + marker + 5 filler bytes + length field + payload.
private func typedstreamBlob(marker: String = "NSString", lengthField: [UInt8], payload: [UInt8]) -> Data {
    var bytes: [UInt8] = [0x04, 0x0B]
    bytes += Array(marker.utf8)
    bytes += [0x01, 0x94, 0x84, 0x01, 0x2B]
    bytes += lengthField
    bytes += payload
    return Data(bytes)
}
```

For a URL shorter than 128 bytes, `lengthField` is `[UInt8(payload.count)]`.

### Reference implementation (openclaw/imsg `674f7c6`, inlined for Appendix A only)

`Sources/IMsgCore/MessageStore+URLPreviews.swift:10-96`:

```swift
let urlPreviewBalloonBundleID = "com.apple.messages.URLBalloonProvider"
let urlPreviewCoalescingWindow: TimeInterval = 5
func canCoalesceURLPreview(textMessage: Message, previewMessage: Message) -> Bool {
    guard isURLPreviewBalloon(previewMessage) else { return false }
    guard textMessage.chatID == previewMessage.chatID,
          textMessage.isFromMe == previewMessage.isFromMe,
          textMessage.sender == previewMessage.sender,
          previewMessage.rowID > textMessage.rowID else { return false }
    let delta = previewMessage.date.timeIntervalSince(textMessage.date)
    guard delta >= 0, delta <= urlPreviewCoalescingWindow else { return false }
    return textMessageContainsPreviewURL(textMessage, previewMessage)
}
```

`Sources/IMsgCore/MessageStore.swift:87-122`:

```swift
struct URLBalloonDedupeState: Sendable {
    let duplicateWindow: TimeInterval = 90
    let retention: TimeInterval = 600
    private var lastSeen: [String: (rowID: Int64, date: Date)] = [:]
    mutating func shouldSkip(_ message: Message) -> Bool {
        let key = "\(message.chatID)|\(message.isFromMe ? 1 : 0)|\(message.sender ?? "")|\(message.text ?? "")"
        if let previous = lastSeen[key],
           message.rowID <= previous.rowID || abs(message.date.timeIntervalSince(previous.date)) <= duplicateWindow {
            return true
        }
        lastSeen[key] = (message.rowID, message.date)
        return false
    }
}
```

`Sources/IMsgCore/MessageStore+Chats.swift:275-282` (unread folding):

```swift
if isURLPreviewBalloon(message), let textMessage = try precedingTextMessageForURLPreview(message, db: db) {
    guard textMessage.isRead == false else { continue }
    logicalRowID = textMessage.rowID
}
```

`MessageStore+Messages.swift:16-81` doubles the physical `LIMIT`
(`nextHistoryPhysicalLimit = current * 2`) until enough logical rows survive
coalescing. None of this is ported here; see Appendix A.

## Commands

| Purpose | Command |
|---|---|
| Build | `cd /Users/robdezendorf/Documents/GitHub/imessage-max/swift && swift build` |
| Full suite | `cd /Users/robdezendorf/Documents/GitHub/imessage-max/swift && swift test` |
| Focused | `cd /Users/robdezendorf/Documents/GitHub/imessage-max/swift && swift test --filter 'URLPreviewBalloonTests\|GetMessagesToolTests\|GetUnreadToolTests\|ListAttachmentsQueryTests\|SearchToolTests\|QueryCountTests\|ListToolCharacterizationTests'` |
| Live premise re-check (read-only) | the SQL under *Live-DB evidence*, run with `sqlite3 -readonly ~/Library/Messages/chat.db` |

## Scope

### In

- Fixture: `balloon_bundle_id TEXT` on `message`, `hide_attachment INTEGER DEFAULT 0`
  on `attachment`, matching optional parameters on `insertMessage` /
  `insertAttachment`.
- New `swift/Tests/iMessageMaxTests/URLPreviewBalloonTests.swift` pinning
  single-row rendering, unread count, search, link filter, hidden attachments.
- `has:"links"` (get_messages) and `has:"link"` (search) match
  `m.balloon_bundle_id = 'com.apple.messages.URLBalloonProvider'`.
- `COALESCE(a.hide_attachment, 0) = 0` on every attachment listing / EXISTS
  predicate in `GetMessagesInternals`, `SearchInternals`, `ListAttachments`.
- Docs: README `get_messages has` note, SKILL.md one line, CHANGELOG.

### Out

- Any coalescing / dedupe of balloon rows with preceding text rows
  (Appendix A; not observed on this build).
- `get_attachment` by explicit id (fetching a hidden attachment on request is fine).
- Rendering `payload_data` (preview title / image) — a separate feature.
- Other balloon bundle ids (business chat, FindMy, Photos); they keep today's behaviour.
- Query-count bounds; no new queries are added.

## Git workflow

```bash
cd /Users/robdezendorf/Documents/GitHub/imessage-max
git checkout main && git pull --ff-only
git checkout -b advisor/083-url-preview-coalescing
```

Commit after each step. Do not squash. Leave the branch for review.

## Steps

### Step 1 — Fixture columns

`ToolTestSupport.swift`:

- `CREATE TABLE message` (`:156-176`): add `balloon_bundle_id TEXT` after `date_edited`.
- `CREATE TABLE attachment` (`:181-188`): add `hide_attachment INTEGER DEFAULT 0`.
- `insertMessage` (`:62-103`): add `balloonBundleId: String? = nil` as the
  last parameter and include it in the INSERT column list / VALUES (use
  `NULL` when nil, `'\(escape(...))'` otherwise, matching how `groupTitle` is handled).
- `insertAttachment` (`:112-125`): change `mimeType: String` to
  `mimeType: String?` and add `hideAttachment: Bool = false`; write
  `mime_type` as `NULL` when nil and `hide_attachment` as `0`/`1`.

**Verify**

```bash
cd /Users/robdezendorf/Documents/GitHub/imessage-max/swift && swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1
```

Expected: `Executed 433 tests, with 0 failures` (no behaviour change).

Commit: `test(fixture): add balloon_bundle_id and hide_attachment columns`

### Step 2 — Characterization tests that already pass (pin single-row behaviour)

Create `swift/Tests/iMessageMaxTests/URLPreviewBalloonTests.swift` with a
private fixture builder:

```swift
private let urlBalloon = "com.apple.messages.URLBalloonProvider"

/// Chat 1 (DM with +15550000001), one inbound unread link message stored the
/// way macOS 26 stores it: text NULL, URL in attributedBody, one hidden
/// pluginPayloadAttachment, balloon_bundle_id set.
private func makeBalloonFixture() throws -> ToolTestDatabase {
    let fixture = try ToolTestDatabase(name: "url-balloon")
    try fixture.insertHandle(rowId: 1, handle: "+15550000001")
    try fixture.insertChat(rowId: 1, guid: "iMessage;-;+15550000001", displayName: nil)
    try fixture.joinChatHandle(chatId: 1, handleId: 1)
    let base: Int64 = 1_000_000_000_000
    // a plain text row 20 s earlier so ordering and unread pairing are exercised
    try fixture.insertMessage(rowId: 700, guid: "m-700", text: "look at this", date: base, isFromMe: false, isRead: true, handleId: 1)
    try fixture.joinChatMessage(chatId: 1, messageId: 700)
    let url = "https://example.com/article"
    let payload = Array(url.utf8)
    try fixture.insertMessage(
        rowId: 701, guid: "m-701", text: nil, date: base + 20_000_000_000,
        isFromMe: false, isRead: false, handleId: 1,
        attributedBody: typedstreamBlob(lengthField: [UInt8(payload.count)], payload: payload),
        balloonBundleId: urlBalloon
    )
    try fixture.joinChatMessage(chatId: 1, messageId: 701)
    try fixture.insertAttachment(
        rowId: 7001, filename: "/Library/Messages/Attachments/aa/01/x.pluginPayloadAttachment",
        mimeType: nil, uti: "dyn.age81a5dzq7y066dbtf0g82peqf4hk2pdrb00n5xy",
        totalBytes: 97_125, transferName: "x.pluginPayloadAttachment", hideAttachment: true
    )
    try fixture.joinMessageAttachment(messageId: 701, attachmentId: 7001)
    return fixture
}
```

(Copy the `typedstreamBlob` helper from `SearchRecallTests.swift:72-79` into
this file as `private`. Check the exact `insertMessage` label for the
attributed body — it is `attributedBody:` per `ToolTestSupport.swift:62-103`.)

Tests that must pass at this step (decode helpers: copy
`decodeGetMessagesResponse` / `decodeJSONArray` from `GetMessagesToolTests.swift`,
or reuse them if they are internal):

1. `testBalloonRowRendersOnceWithURLAsText` — `get_messages chat_id:"chat1" limit:10`
   returns 2 messages; the newest has `id == "msg_701"`, `text == "https://example.com/article"`,
   `links == ["https://example.com/article"]`.
2. `testBalloonRowCountsOnceInUnread` — `get_unread` (construct the tool the way
   `GetUnreadToolTests` does) reports the chat with unread count 1 and one
   message whose text is the URL.
3. `testSearchFindsBalloonRowOnce` — `search query:"example.com"` returns
   exactly one result, `msg_701`.

**Verify**

```bash
cd /Users/robdezendorf/Documents/GitHub/imessage-max/swift && swift test --filter URLPreviewBalloonTests 2>&1 | grep -E "Executed [0-9]+ tests"
```

Expected: `Executed 3 tests, with 0 failures`. If test 1 or 3 fails, the
typedstream blob is malformed — compare with `MessageTextExtractorTests` before
touching Sources.

Commit: `test(messages): pin single-row rendering of URL preview balloon rows`

### Step 3 — Link filters match balloon rows, test-first

Add to `URLPreviewBalloonTests.swift`:

4. `testHasLinksReturnsBalloonRow` — `get_messages chat_id:"chat1" has:"links"`
   returns exactly `msg_701`.
5. `testSearchHasLinkReturnsBalloonRow` — `search query:"example" has:"link"`
   (check the exact parameter name in `Search.swift`'s schema) returns `msg_701`.

Run them; both must fail (0 results). Then:

`GetMessagesInternals.swift:480`:

```swift
            case "links":
                query.where("(m.text LIKE '%http://%' OR m.text LIKE '%https://%' OR m.balloon_bundle_id = 'com.apple.messages.URLBalloonProvider')")
```

`SearchInternals.swift:147`:

```swift
            case "link":
                builder.where("(m.text LIKE ? ESCAPE '\\' OR m.balloon_bundle_id = 'com.apple.messages.URLBalloonProvider')", "%http%")
```

Put the bundle id in one place: add
`static let urlPreviewBalloonBundleID = "com.apple.messages.URLBalloonProvider"`
to `AttachmentType.swift` or a new tiny `Utilities/BalloonBundle.swift`, and
interpolate it (it contains no quotes, so string interpolation into SQL is
safe; do not bind it as a parameter — `QueryCountTests` do not care, but
keeping the literal visible in `EXPLAIN` output helps debugging).

**Verify**

```bash
cd /Users/robdezendorf/Documents/GitHub/imessage-max/swift && swift test --filter 'URLPreviewBalloonTests|GetMessagesToolTests|SearchToolTests|SearchRecallTests|QueryCountTests|ListToolCharacterizationTests' 2>&1 | grep -E "Executed [0-9]+ tests|failed" | tail -3
```

Expected: `0 failures`; `GetMessagesToolTests` `has:"links"` on chat 20 still
returns exactly `msg_201`.

Commit: `fix(messages): has=links and search has=link match URL preview balloon rows`

### Step 4 — Hide `hide_attachment = 1` rows, test-first

Add to `URLPreviewBalloonTests.swift`:

6. `testHiddenPayloadAttachmentIsNotListedOnMessage` — `get_messages chat_id:"chat1"`
   message `msg_701` has no `attachments` key and no `media` key.
7. `testHasAttachmentsIgnoresHiddenPayload` — `get_messages chat_id:"chat1" has:"attachments"`
   returns 0 messages.
8. `testListAttachmentsSkipsHiddenPayload` — `list_attachments chat_id:"chat1"`
   returns 0 items (build the tool as `ListAttachmentsQueryTests.swift:23-100` does).
9. `testVisibleAttachmentOnSameMessageStillListed` — add attachment 7002
   (`image/jpeg`, `public.jpeg`, `hideAttachment: false`) to `msg_701`; both
   `get_messages` (`media` has one entry, no `attachments` entry) and
   `list_attachments` (one item, `att7002`) show only it.
10. `testSearchHasAttachmentIgnoresHiddenPayload` — `search query:"example" has:"attachment"`
    returns 0 (and returns 1 after adding 7002, if easy).

Run; 6–8 and 10 must fail. Then add `COALESCE(a.hide_attachment, 0) = 0` (the
`COALESCE` protects against NULL on older schemas):

- `GetMessagesInternals.swift:530-539` `getAttachmentsMap`: `WHERE maj.message_id IN (…) AND COALESCE(a.hide_attachment, 0) = 0`.
- `GetMessagesInternals.swift:481-486` `has:"attachments"`: the EXISTS currently
  joins only `message_attachment_join`; change it to join `attachment a` and add the predicate.
- `GetMessagesInternals.swift:488-497` `has:"images"`: add `AND COALESCE(a.hide_attachment, 0) = 0`.
- `SearchInternals.swift:148-165`: same on the three EXISTS branches.
- `ListAttachments.swift:368-369`: after `.join("attachment a ON maj.attachment_id = a.ROWID")` add `.where("COALESCE(a.hide_attachment, 0) = 0")`.
- `ListAttachments.swift:380-383` and `:413-417`: append `AND COALESCE(a.hide_attachment, 0) = 0` inside both subqueries (next to `\(typeClause)`).
- `ListAttachments.swift:476-479` `attachmentsForMessages`: add `.where("COALESCE(a.hide_attachment, 0) = 0")`.

Do not touch `GetAttachment.swift`.

**Verify**

```bash
cd /Users/robdezendorf/Documents/GitHub/imessage-max/swift && swift test --filter 'URLPreviewBalloonTests|GetMessagesToolTests|ListAttachmentsQueryTests|SearchToolTests|GetAttachmentToolTests|QueryCountTests|ListToolCharacterizationTests' 2>&1 | grep -E "Executed [0-9]+ tests|failed" | tail -3
grep -c "hide_attachment" /Users/robdezendorf/Documents/GitHub/imessage-max/swift/Sources/iMessageMax/Tools/GetMessagesInternals.swift /Users/robdezendorf/Documents/GitHub/imessage-max/swift/Sources/iMessageMax/Tools/SearchInternals.swift /Users/robdezendorf/Documents/GitHub/imessage-max/swift/Sources/iMessageMax/Tools/ListAttachments.swift
```

Expected: `0 failures`; counts `3`, `3`, `4` respectively (or higher if a
helper constant is used; never `0`).

Commit: `fix(attachments): hide Messages-hidden pluginPayloadAttachment rows from listings`

### Step 5 — Docs, full suite, index

- `README.md` `get_messages` section: after the `has` parameter description
  add "`links` includes link messages Messages stores as URL preview balloons
  (the common case on macOS 26)." In the `list_attachments` section add
  "Attachments Messages hides (`hide_attachment`, e.g. link-preview payloads)
  are not listed; `get_attachment` still returns them by id."
- `using-imessage-max/SKILL.md` "browse shared items" guidance: one line that
  link previews are not attachments; use `get_messages has:"links"`.
- `CHANGELOG.md` `## Unreleased` → `### Fixes`: "`get_messages has:\"links\"`
  and `search has:\"link\"` match URL preview balloon rows; link-preview
  payload attachments are no longer listed."
- Full suite and Task.sleep guard:

```bash
cd /Users/robdezendorf/Documents/GitHub/imessage-max/swift && swift build 2>&1 | tail -1 && swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1
grep -rn "Task.sleep" /Users/robdezendorf/Documents/GitHub/imessage-max/swift/Sources
```

Expected: `Executed 443 tests, with 0 failures` (433 + 10; report the exact
number) and nothing from the grep.

- Add to `plans/README.md` current-round table:
  `| [083](083-url-preview-coalescing.md) | URL preview balloon rows: pin, link filters, hidden attachments | P2 | S–M | — | DONE |`
  and one line under "Findings considered and rejected": "imsg URL balloon
  coalescing/dedupe — 0 of 1,121 balloon rows in 365 d pair with a URL text
  row; see 083 Appendix A."

Commit: `docs: note balloon-aware link filters and hidden attachment listing`

## Test plan

- Unit/tool tests, all against the SQLite fixture: 10 cases in
  `URLPreviewBalloonTests` (3 pins that pass before any Sources change, 7
  that go red→green in Steps 3–4).
- Regression: `GetMessagesToolTests` (`has:"links"` still exactly `msg_201`),
  `ListAttachmentsQueryTests`, `SearchToolTests`, `SearchRecallTests`,
  `GetAttachmentToolTests`, `QueryCountTests`, `ListToolCharacterizationTests`
  (query counts unchanged — no new queries).
- Manual (optional, read-only): after `make install`, `get_messages` on a chat
  with a recent link with `has:"links"` returns it; `list_attachments` on the
  same chat no longer shows `.pluginPayloadAttachment` items.

## Done criteria

- [ ] `grep -n "balloon_bundle_id TEXT" swift/Tests/iMessageMaxTests/ToolTestSupport.swift` and `grep -n "hide_attachment INTEGER" …/ToolTestSupport.swift` both match.
- [ ] `swift/Tests/iMessageMaxTests/URLPreviewBalloonTests.swift` exists with 10 `func test` methods.
- [ ] `grep -c "URLBalloonProvider" swift/Sources/iMessageMax` ≥ 1 and both link predicates reference it (grep `has` branches in `GetMessagesInternals.swift` and `SearchInternals.swift`).
- [ ] `grep -rn "hide_attachment" swift/Sources/iMessageMax/Tools` matches in `GetMessagesInternals.swift`, `SearchInternals.swift`, `ListAttachments.swift` and nowhere in `GetAttachment.swift`.
- [ ] `swift test` passes with 0 failures and at least 443 tests.
- [ ] `grep -rn "Task.sleep" swift/Sources` prints nothing.
- [ ] `git diff main --stat` touches only the drift-check list, the new test file, an optional constants file, and `plans/README.md`.

## STOP conditions

- The live premise re-check (SQL under *Live-DB evidence*) returns
  `paired_with_url_text_90s > 0`. Messages on this machine has started writing
  duplicate rows; Appendix A becomes live work and this plan needs
  re-scoping. Report the number.
- `ToolTestSupport.swift` on `main` already has a `balloon_bundle_id` or
  `hide_attachment` column with a different name or default (another plan
  landed first) — merge, do not duplicate; if the semantics differ, stop.
- Step 2 tests 1 or 3 fail before any Sources change — the fixture or the
  typedstream helper is wrong, not the reader; do not "fix" Sources.
- Any `QueryCountTests` / `ListToolCharacterizationTests` bound needs raising —
  this plan adds predicates, not queries.
- `GetMessagesToolTests` `has:"links"` on chat 20 returns more than `msg_201`.

## Maintenance notes

- Definition used throughout: a **URL preview balloon row** is
  `message.balloon_bundle_id = 'com.apple.messages.URLBalloonProvider'`. On
  macOS 26 it is the link message itself (text NULL, URL in `attributedBody`).
- The `hide_attachment` filter is deliberately `COALESCE(a.hide_attachment, 0) = 0`
  so a chat.db from an older macOS without the column still works if the
  column is ever missing (it exists on every schema we have seen; the
  COALESCE is cheap insurance).
- `get_attachment` still serves hidden attachments by id on purpose — a
  caller who has an id from an older listing should not get a 404.
- Re-run the premise query once per macOS major release. The numbers in this
  plan are from macOS 26.6.2 on 2026-09-02.

## Appendix A — Deferred: imsg-style coalescing (only if the premise query goes positive)

If a future Messages build writes *both* a text row and a URL balloon row for
one link, port these three pieces from imsg (excerpts under *Current state*):

1. **Read-path coalescing** (`canCoalesceURLPreview`): after the page query in
   `GetMessagesInternals.swift:430-521`, drop a balloon row when the
   immediately preceding row in the same chat has the same `is_from_me` and
   `handle_id`, a smaller ROWID, a date within 5 s, and its text contains the
   balloon's URL. Attach the balloon's `links`/preview to the text row.
2. **Unread folding** (`MessageStore+Chats.swift:275-282`): in
   `GetUnread.swift:374-379` count `DISTINCT` logical rows where a balloon row
   maps to its preceding text row when that row is unread, and is skipped when
   the text row is already read.
3. **Physical-limit doubling** (`nextHistoryPhysicalLimit`): because
   coalescing removes rows after `LIMIT`, refetch with `limit * 2` (cap at 4×)
   until the page is full or the source is exhausted. `imsg` also keeps a
   90 s `URLBalloonDedupeState` keyed `chat|isFromMe|sender|text` for its
   *streaming* watcher; imessage-max has no streaming path, so that part is
   not needed.

Add the premise query to the plan that does this, and pin with fixture rows
700 (text with URL, date `t`) and 701 (balloon, date `t + 2 s`) expecting one
rendered message and one unread.
