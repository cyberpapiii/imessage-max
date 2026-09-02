# Plan 070: `get_context` `contains` looks past the newest 500 messages, reports a distinct error when it runs out of window, and gets a tool test file

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 639529e..HEAD -- swift/Sources/iMessageMax/Tools/GetContext.swift swift/Tests/iMessageMaxTests/GetContextToolTests.swift swift/Tests/iMessageMaxTests/ResponseContractTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: 063 (`plans/063-input-hygiene-rowid-json-errors-bind-codes.md` touches id parsing and error text in the tools; land it first so the error-path tests here assert the post-063 strings)
- **Category**: bug / tests
- **Planned at**: commit `639529e`, 2026-09-01

## Why this matters

`get_context` with `chat_id` + `contains` loads the newest 500 non-reaction messages of the chat and substring-matches them in Swift. In any chat with more than 500 messages, a phrase older than that returns `not_found` with the message "No message found containing '...'", which is false: the message exists, the tool just did not look. The agent then reports to the user that the message does not exist. Busy group chats pass 500 messages in weeks.

The tool also has no test file of its own. Its only coverage is two tests in `ResponseContractTests.swift` that hit the `message_id` path. The `contains` path, the `before`/`after` window, the clamp to 50, and every error branch are untested.

After this plan: the lookup pushes the text match into SQL where it can, pages through the chat up to a documented cap, and returns a distinct `not_found_in_window` error carrying how many messages were scanned when the cap is hit. A `GetContextToolTests.swift` covers all of it, and the "hit beyond 500" test fails on the current code before the fix.

## Current state

### The tool

`swift/Sources/iMessageMax/Tools/GetContext.swift` (483 lines). Registration at `:49-113`; the handler reads `message_id`, `chat_id`, `contains`, `before` (default 5), `after` (default 10) and calls `execute`. Failures are thrown as `ToolError(content: [.plainText(JSON of GetContextError)])` (`:110`).

`GetContext.swift:37-44`:

```swift
struct GetContextError: LocalizedError, Codable {
    let error: String
    let message: String
    ...
}
```

`GetContext.swift:61-64` (schema text for `contains`):

```swift
                "contains": .object([
                    "type": "string",
                    "description": "Find message containing this text, then get context",
                ]),
```

`GetContext.swift:115-139` (entry, clamp, argument errors):

```swift
    static func execute(
        messageId: String? = nil,
        chatId: String? = nil,
        contains: String? = nil,
        before: Int = 5,
        after: Int = 10,
        database: Database = Database(),
        resolver: ContactResolver = ContactResolver()
    ) async -> Result<GetContextResponse, GetContextError> {
        let beforeCount = max(0, min(before, 50))
        let afterCount = max(0, min(after, 50))

        if messageId == nil && (chatId == nil || contains == nil) {
            return .failure(GetContextError(
                error: "invalid_params",
                message: "Either message_id OR (chat_id + contains) is required"
            ))
        }

        if contains != nil && chatId == nil {
            return .failure(GetContextError(
                error: "invalid_params",
                message: "chat_id is required when using contains"
            ))
        }
```

`GetContext.swift:146-190` — the `message_id` path: `parseMessageId` (`:450-458`, accepts `msg_N`, `msgN`, `N`) else `invalid_id` "Invalid message ID format: ..."; a single-row lookup by `m.ROWID = ?`; empty → `not_found` "Target message not found".

`GetContext.swift:200-253` — the `contains` path (the bug):

```swift
                guard let numericChatId = ChatIdentifier.parseRowId(cId) else {
                    return .failure(GetContextError(
                        error: "invalid_id",
                        message: "Invalid chat ID format: \(cId)"
                    ))
                }

                // attributedBody is a binary blob — cannot search in SQL; filter in Swift
                let sql = """
                    SELECT
                        m.ROWID as msg_id,
                        m.text,
                        m.attributedBody,
                        m.date,
                        m.is_from_me,
                        h.id as sender_handle,
                        c.ROWID as chat_id,
                        c.display_name as chat_name
                    FROM message m
                    JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
                    JOIN chat c ON cmj.chat_id = c.ROWID
                    LEFT JOIN handle h ON m.handle_id = h.ROWID
                    WHERE c.ROWID = ?
                    AND (m.text IS NOT NULL OR m.attributedBody IS NOT NULL)
                    AND m.associated_message_type = 0
                    ORDER BY m.date DESC
                    LIMIT 500
                    """

                let rows = try database.query(sql, params: [numericChatId]) { row in
                    ( msgId: row.int(0), text: row.string(1), attributedBody: row.blob(2), date: row.int(3),
                      isFromMe: row.int(4) != 0, senderHandle: row.string(5), chatId: row.int(6), chatName: row.string(7) )
                }

                let searchLower = searchText.lowercased()
                guard let found = rows.first(where: { row in
                    let extractedText = MessageTextExtractor.extract(text: row.text, attributedBody: row.attributedBody)
                    return extractedText?.lowercased().contains(searchLower) ?? false
                }) else {
                    return .failure(GetContextError(
                        error: "not_found",
                        message: "No message found containing '\(searchText)'"
                    ))
                }
                targetResult = found
```

Match semantics to preserve: case-insensitive substring on the text produced by `MessageTextExtractor.extract(text:attributedBody:)` (`Utilities/MessageTextExtractor.swift:7`), newest match wins, reactions excluded.

`GetContext.swift:258-314` — `before`/`after` windows: `m.date < target ORDER BY m.date DESC LIMIT beforeCount` then `.reversed()`; `m.date > target ORDER BY m.date ASC LIMIT afterCount`. Both exclude reactions and are keyed by `cmj.chat_id = targetChatId`. Rows at the target's exact date are in neither.

`GetContext.swift:316-360` — people keys: `"me"` for outbound; resolved first name lowercased (with `2`, `3` suffixes on collision) for known contacts; `p1`, `p2`, ... for unknown handles.

`GetContext.swift:437-445` — `DatabaseError` is mapped through `ToolErrorMapping.map(_:context:)`; anything else becomes `internal_error` with `ClientErrorMessages.sanitized`.

### SQL-side prefilter already used by search

`swift/Sources/iMessageMax/Database/QueryBuilder.swift:126-130`:

```swift
    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "%", with: "\\%")
         .replacingOccurrences(of: "_", with: "\\_")
    }
```

`SearchInternals.swift:72-88` uses it as `m.text LIKE ? ESCAPE '\'` with the pattern `"%\(QueryBuilder.escapeLike(word))%"` (read those lines for the exact clause text and copy it). SQLite `LIKE` is case-insensitive for ASCII only; the Swift `.lowercased().contains` is Unicode-aware. To stay a *prefilter* (never a false negative), the SQL must also admit every row whose `text` is NULL (attributedBody-only rows) so Swift can decode and check them.

### Existing tests

`swift/Tests/iMessageMaxTests/ResponseContractTests.swift:117-152` — two `message_id` tests against `makeGetMessagesFixture()`:

```swift
    func testGetContextUsesMessageFieldNotTarget() async throws {
        let fixture = try makeGetMessagesFixture()
        let result = await GetContext.execute(
            messageId: "msg_200",
            database: fixture.database(),
            resolver: makeSeededResolver()
        )

        guard case .success(let response) = result else {
            return XCTFail("Expected get_context success")
        }

        let encoded = try decodeJSONDictionary(from: try FormatUtils.encodeJSON(response))
        XCTAssertNotNil(encoded["message"])
        XCTAssertNil(encoded["target"])
    }

    func testGetContextGeneratesHumanChatNameForUnnamedChats() async throws {
        ...
        XCTAssertEqual(response.chat.id, "chat20")
        let chatName = try XCTUnwrap(response.chat.name)
        XCTAssertEqual(Set(chatName.components(separatedBy: ", ").filter { !$0.isEmpty }), ["Alice Smith", "Bob Brown"])
    }
```

No file named `GetContextToolTests.swift` exists (`ls swift/Tests/iMessageMaxTests | grep -i context` → nothing).

### Fixture API

`swift/Tests/iMessageMaxTests/ToolTestSupport.swift:10-126` — `ToolTestDatabase(name:)`, `insertHandle(rowId:handle:)`, `insertChat(rowId:guid:displayName:)`, `joinChatHandle(chatId:handleId:)`, `insertMessage(rowId:guid:text:date:isFromMe:isRead:handleId:associatedMessageType:associatedMessageGuid:error:isSent:attributedBody:)`, `joinChatMessage(chatId:messageId:)`, `database()`. `makeSeededResolver()` (`:179`) resolves `+15550000001` → "Alice Smith", `+15550000002` → "Bob Brown". `makeGetMessagesFixture()` (`GetMessagesToolTests.swift:246-299`) builds chat 20 (unnamed, handles 1 and 2) with messages 200, 201, 400 (reaction), 202, 203 at `base + minute` offsets; message 200's text is `"trip to costa rica volcano"`.

Structural pattern for the new file: `GetMessagesToolTests.swift:1-60` (`final class ... : XCTestCase`, one fixture per test, decode helpers, `catch let error as ToolError` with `decodeJSONDictionary(from: error.content)` for error payloads).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| Full suite | `cd swift && swift test` | 0 failures, count ≥ 370 |
| New tests | `cd swift && swift test --filter GetContextToolTests` | 0 failures after Step 3; exactly 1 failure after Step 1 |
| Contract tests | `cd swift && swift test --filter ResponseContractTests` | 0 failures |
| Sleep guard | `cd swift && swift test --filter LaunchdSafetyTests` | 0 failures |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Tools/GetContext.swift`
- `swift/Tests/iMessageMaxTests/GetContextToolTests.swift` (create)
- `swift/Tests/iMessageMaxTests/ResponseContractTests.swift` — only to *move* the two `get_context` tests into the new file if you choose to; leaving them is also fine

**Out of scope** (do NOT touch, even though they look related):
- `GetContext.swift:316-360` people-key generation and `:460-481` chat naming — plan 068 owns naming.
- `SearchInternals.swift` — its `contains` is a different feature.
- `ChatIdentifier.parseRowId`, `MessageTextExtractor`, `QueryBuilder` — used, not changed.
- The `message_id` path and the `before`/`after` SQL — unchanged; tests pin them.
- Response shape: `GetContextResponse` fields do not change. `GetContextError` gains no fields; the scanned count goes in the `message` string (see Step 2) so the error contract stays `{error, message}`.
- `.mcp.json` — never touch.

## Git workflow

- Branch: `advisor/070-get-context-contains-window` from current `main` (after 063 is merged).
- Conventional commits, one per step: `test:`, `fix:`, `docs:`. Examples from `git log`: `ci: run the suite serially on macos-26`, `docs: record 060 serial CI`.
- Do NOT push or open a PR.
- Never commit secrets; none are involved.

Standing rules: never add `Task.sleep` under `swift/Sources` (`LaunchdSafetyTests` enforces it); never touch `.mcp.json`.

## Steps

### Step 1: Test file first, with the beyond-500 test failing

Create `swift/Tests/iMessageMaxTests/GetContextToolTests.swift`:

```swift
import XCTest
import MCP
@testable import iMessageMax

final class GetContextToolTests: XCTestCase {
    ...
}
```

Add a private fixture builder `makeLongChatFixture(messageCount: Int) throws -> ToolTestDatabase`: handle 1 (`+15550000001`), handle 2 (`+15550000002`), chat 50 (`displayName: "Long Chat"`, both handles), and `messageCount` messages with `rowId: 1000 + i`, `guid: "long-\(i)"`, `text: "filler \(i)"`, `date: base + Int64(i) * minute`, alternating `isFromMe` and `handleId: (i % 2 == 0) ? 1 : nil`, all joined to chat 50. Use the same `base` / `minute` constants as `makeGetMessagesFixture` (`GetMessagesToolTests.swift:263-264`). Let the caller override a few texts after the fact by returning the fixture and letting the test call `fixture.execute("UPDATE message SET text = '...' WHERE ROWID = ...")` (`ToolTestDatabase.execute(_:)` is at `ToolTestSupport.swift:33`).

Tests (all call `GetContext.execute(...)` directly, like `ResponseContractTests.swift:119-123`, and decode with `FormatUtils.encodeJSON` + `decodeJSONDictionary` where the JSON shape matters):

1. `testMessageIdReturnsBeforeAndAfterInDateOrder` — `makeGetMessagesFixture()`, `messageId: "msg_202"`, `before: 5`, `after: 5`. Expect `before` ids `["msg_200", "msg_201"]` (ascending, reaction 400 excluded), `after` ids `["msg_203"]`, `message.id == "msg_202"`.
2. `testBeforeAndAfterDefaultsAreFiveAndTen` — `makeLongChatFixture(messageCount: 40)`, `messageId: "msg_1020"`, no `before`/`after` arguments. Expect `before.count == 5`, `after.count == 10`, `before.first?.id == "msg_1015"`, `after.last?.id == "msg_1030"`.
3. `testBeforeAndAfterClampToFifty` — `makeLongChatFixture(messageCount: 150)`, `messageId: "msg_1075"`, `before: 500`, `after: 500`. Expect `before.count == 50`, `after.count == 50`. Also `before: -3, after: -3` → both empty.
4. `testMissingArgumentsIsInvalidParams` — no arguments → `.failure` with `error == "invalid_params"` and message `"Either message_id OR (chat_id + contains) is required"`; `contains` without `chat_id` → same code, message `"chat_id is required when using contains"`. (If 063 changed these strings, assert the post-063 strings; read the live file.)
5. `testInvalidMessageIdIsInvalidId` — `messageId: "nope"` → `error == "invalid_id"`.
6. `testUnknownMessageIdIsNotFound` — `messageId: "msg_999999"` → `error == "not_found"`, message `"Target message not found"`.
7. `testInvalidChatIdWithContainsIsInvalidId` — `chatId: "chat_abc"`, `contains: "x"` → `error == "invalid_id"`.
8. `testContainsFindsNewestMatchWithinWindow` — `makeGetMessagesFixture()`, `chatId: "chat20"`, `contains: "VOLCANO"` (uppercase, proves case-insensitivity). Two messages match (200 and 201); the newest is 201. Expect `message.id == "msg_201"`, `before` contains `msg_200`, `after` contains `msg_202`.
9. `testContainsMatchesAttributedBodyOnlyRows` — insert one message with `text: nil` and `attributedBody:` a typedstream blob that decodes to `"hidden phrase"`. Build the blob the way an existing test does: `grep -rn "attributedBody:" swift/Tests/iMessageMaxTests/*.swift | grep -v "nil" | head` and reuse that helper or byte literal. Expect `contains: "hidden"` to find it. If no test in the repo builds a decodable blob, STOP (see conditions) rather than inventing one.
10. `testContainsFindsMatchBeyondNewestFiveHundred` — `makeLongChatFixture(messageCount: 600)`; set `text = 'needle in the old part'` on `ROWID 1010` (message 10 of 600, so ~590 newer messages precede it in `ORDER BY date DESC`). `chatId: "chat50"`, `contains: "needle"`. Expect `.success` with `message.id == "msg_1010"`. **This test must FAIL on current code** with `error == "not_found"`; run it once before Step 2 and record that in the commit message.
11. `testContainsMissReturnsNotFoundWithinCap` — `makeLongChatFixture(messageCount: 50)`, `contains: "zzz-never"` → `error == "not_found"` (chat fully scanned, phrase absent).
12. `testContainsMissBeyondCapIsNotFoundInWindow` — written now, asserted after Step 2: `makeLongChatFixture(messageCount: 5100)`, `contains: "zzz-never"` → `error == "not_found_in_window"`, message contains `"5000"`. Until Step 2 this returns `not_found`; write the assertion for the target behaviour and expect it to fail now (that makes two expected failures after Step 1; say so in the commit).

Inserting 5100 rows through `insertMessage` (one `INSERT` each) takes a few seconds; acceptable. If it exceeds ~10 s on your machine, wrap the inserts in `fixture.execute("BEGIN")` / `fixture.execute("COMMIT")` inside the fixture builder.

**Verify**: `cd swift && swift test --filter GetContextToolTests` → exactly 2 failures: `testContainsFindsMatchBeyondNewestFiveHundred` and `testContainsMissBeyondCapIsNotFoundInWindow`. All others pass.

Commit: `test: add GetContextToolTests; contains lookup beyond 500 messages fails today`.

### Step 2: SQL prefilter, paging up to a cap, distinct error

In `GetContext.swift`, replace the `contains` block (`:207-253`) with a paged scan:

```swift
                // Page newest-first through the chat. LIKE prefilters rows with
                // plain text; rows whose text is NULL (attributedBody-only) are
                // always admitted so the Swift decode can check them. LIKE is
                // ASCII-case-insensitive; the Swift check below is the one
                // that decides, so the prefilter can only remove non-matches.
                let pageSize = 500
                let scanCap = 5000
                let pattern = "%\(QueryBuilder.escapeLike(searchText))%"
                let searchLower = searchText.lowercased()
                var scanned = 0
                var offset = 0
                var foundRow: <the tuple type at :144>? = nil
                var exhausted = false

                while foundRow == nil && !exhausted && scanned < scanCap {
                    let rows = try database.query(
                        """
                        SELECT ... (same columns as today) ...
                        FROM message m
                        JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
                        JOIN chat c ON cmj.chat_id = c.ROWID
                        LEFT JOIN handle h ON m.handle_id = h.ROWID
                        WHERE c.ROWID = ?
                          AND m.associated_message_type = 0
                          AND (m.text LIKE ? ESCAPE '\\' OR (m.text IS NULL AND m.attributedBody IS NOT NULL))
                        ORDER BY m.date DESC
                        LIMIT ? OFFSET ?
                        """,
                        params: [numericChatId, pattern, pageSize, offset]
                    ) { row in ... same mapping ... }
                    scanned += rows.count
                    offset += pageSize
                    exhausted = rows.count < pageSize
                    foundRow = rows.first(where: { row in
                        let extracted = MessageTextExtractor.extract(text: row.text, attributedBody: row.attributedBody)
                        return extracted?.lowercased().contains(searchLower) ?? false
                    })
                }

                guard let found = foundRow else {
                    if exhausted {
                        return .failure(GetContextError(
                            error: "not_found",
                            message: "No message found containing '\(searchText)'"
                        ))
                    }
                    return .failure(GetContextError(
                        error: "not_found_in_window",
                        message: "No message containing '\(searchText)' in the newest \(scanned) candidate messages of this chat (scan cap \(scanCap)). Narrow the phrase or use search with chat_id to find the message id, then call get_context with message_id."
                    ))
                }
                targetResult = found
```

Notes:
- `scanned` counts *candidate* rows (post-prefilter), not all messages. With the prefilter, most chats are exhausted in one page even when they hold 50 000 messages, because only rows containing the phrase or lacking text are candidates. The cap exists for chats full of attributedBody-only rows.
- Keep the Swift `.lowercased().contains` as the decider so Unicode case folding is unchanged from today.
- The `ESCAPE '\\'` inside a Swift multi-line string literal produces `ESCAPE '\'` in SQL; copy the exact form from `SearchInternals.swift:72-88`.
- Do not change the error type; the count is in the message string.

Update the schema description at `:61-64` to: `"Find the newest message containing this text (case-insensitive), then get context. Scans up to 5000 candidate messages newest-first; returns not_found_in_window if the cap is reached."`

**Verify**:
- `cd swift && swift test --filter GetContextToolTests` → 0 failures (all 12).
- `cd swift && swift test --filter ResponseContractTests` → 0 failures.
- `grep -n "LIMIT 500$" swift/Sources/iMessageMax/Tools/GetContext.swift` → no matches.
- `grep -n "not_found_in_window" swift/Sources/iMessageMax/Tools/GetContext.swift` → 2 matches (the error and the schema description).
- `grep -n "escapeLike" swift/Sources/iMessageMax/Tools/GetContext.swift` → 1 match.
- Wildcard safety: add `testContainsTreatsPercentAndUnderscoreLiterally` — `makeLongChatFixture(messageCount: 20)`, set one text to `"100% done"` and another to `"a_b"`; `contains: "%"` finds the first; `contains: "_"` finds the second; `contains: "x_y"` returns `not_found` (no wildcard match against `"a_b"`... adjust texts so the literal/wildcard distinction is unambiguous). → passes.

Commit: `fix: get_context contains pages past the newest 500 messages and reports not_found_in_window at the cap`.

### Step 3: Document the error code where tools' errors are listed

`grep -rn "not_found\b" AGENTS.md docs/ README.md swift/Sources/iMessageMax/Utilities/ToolErrorMapping.swift` and read the hits. If there is a table or list of tool error codes (AGENTS.md or `docs/`), add `not_found_in_window` with one line: "get_context contains: the phrase was not in the newest N candidate messages; narrow the phrase or use search to get a message id." If `ToolErrorMapping` enumerates codes for the modern dispatcher (plan 063 may have added an enum), add the code there too; if it does not, do nothing there.

**Verify**: `grep -rn "not_found_in_window" AGENTS.md docs/ swift/Sources` → at least the two source matches plus one doc match if a code list exists. `cd swift && swift build` → exit 0.

Commit: `docs: list the get_context not_found_in_window error` (skip the commit if no doc site exists; note that in the plan status row).

## Test plan

- Twelve tests in the new `GetContextToolTests.swift` plus the wildcard test from Step 2 (thirteen total): window contents and ordering (1), defaults (2), clamp and negative inputs (3), each `invalid_params` message (4), `invalid_id` for message and chat (5, 7), `not_found` for an unknown id (6), contains hit inside 500 with case-insensitivity (8), attributedBody-only hit (9), hit beyond 500 (10, red before Step 2), miss within the cap (11), miss beyond the cap (12, red before Step 2), LIKE wildcard literalness (13).
- Model on `GetMessagesToolTests.swift:1-60` for structure and `ResponseContractTests.swift:117-132` for calling `GetContext.execute` directly.
- The two `get_context` tests in `ResponseContractTests.swift` stay where they are (they test the response contract, which is that file's job).
- Final: `cd swift && swift test` → 0 failures, count ≥ 383.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift build` exits 0
- [ ] `cd swift && swift test` exits 0 with 0 failures
- [ ] `test -f swift/Tests/iMessageMaxTests/GetContextToolTests.swift` and `grep -c "func test" swift/Tests/iMessageMaxTests/GetContextToolTests.swift` → `13`
- [ ] `grep -n "LIMIT 500$" swift/Sources/iMessageMax/Tools/GetContext.swift` → no matches
- [ ] `grep -c "not_found_in_window" swift/Sources/iMessageMax/Tools/GetContext.swift` → `2`
- [ ] `grep -c "escapeLike" swift/Sources/iMessageMax/Tools/GetContext.swift` → `1`
- [ ] `git log --oneline main..HEAD` shows the test commit *before* the fix commit
- [ ] `grep -rn "Task.sleep" swift/Sources` → no matches
- [ ] `git status --porcelain` lists only in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any "Current state" excerpt does not match the live file. In particular, if plan 063 changed `GetContextError`, the `invalid_id` / `invalid_params` strings, or `ChatIdentifier.parseRowId`, re-read `GetContext.swift:115-253` and adjust the test strings in Step 1 before writing them; if the *structure* of the `contains` block changed, stop.
- `testContainsFindsMatchBeyondNewestFiveHundred` **passes** on the current code (the bug is not what the plan says; do not proceed to Step 2).
- No test in the repo constructs a decodable `attributedBody` typedstream blob (test 9 cannot be written honestly). Report and drop test 9 only; the done-criterion count becomes 12.
- The `ESCAPE` form copied from `SearchInternals.swift` does not match the shape described here (`LIKE ? ESCAPE '\'` with a `%...%` pattern from `escapeLike`).
- The 5100-row fixture takes more than 30 s even inside a transaction; report the timing and reduce `scanCap` in the test to a value you can afford by making the cap an internal parameter of `execute` (default 5000) rather than shrinking the production cap.
- `ToolErrorMapping` has a closed enum of error codes that the modern dispatcher validates against, and adding a code there requires changing a file outside scope.

## Maintenance notes

- **The cap is 5000 candidates, newest first.** A candidate is a row that passed the LIKE prefilter or has no plain text. If attributedBody-only rows become common (Apple has been moving more content into `attributedBody`), the cap will bite sooner; the fix then is an `attributedBody`-aware prefilter (e.g. `instr(attributedBody, ?)` on the UTF-8 bytes of the phrase as a cheap pre-check), not a bigger cap.
- **`not_found` vs `not_found_in_window`**: agents should treat the second as "use `search` with `chat_id`, then `get_context` with `message_id`". The message string says so; keep that sentence if the wording changes.
- **Reviewer should scrutinize**: the LIKE/Swift agreement on case (the prefilter is ASCII-case-insensitive; a phrase with non-ASCII letters relies on Swift for case folding and on LIKE matching the *exact* bytes, so `contains: "É"` would miss a message containing `"é"` in plain text — that is unchanged from today's behaviour only for the Swift side; document it if it matters), and that `OFFSET` paging is stable given `ORDER BY m.date DESC` without a tie-break (add `, m.ROWID DESC` if two rows share a date, which is common).
- **Deferred**: making `get_context` take a `search`-style multi-word or fuzzy query; making the per-anchor window shared with `SearchInternals.getContextBatch` (plan 069 aligns the search side).
