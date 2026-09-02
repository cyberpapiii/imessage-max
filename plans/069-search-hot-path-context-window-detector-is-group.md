# Plan 069: Search hot path — per-anchor context windows, hoisted detector and regexes, cheaper excerpts, and an `is_group` filter that stops counting

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 639529e..HEAD -- swift/Sources/iMessageMax/Tools/SearchInternals.swift swift/Sources/iMessageMax/Utilities/SummaryPreviewFormatter.swift swift/Tests/iMessageMaxTests/SearchToolTests.swift swift/Tests/iMessageMaxTests/SummaryPreviewFormatterTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S-M
- **Risk**: LOW
- **Depends on**: none (068 touches other parts of `SearchInternals.swift`; if both are in flight, land 068 first and rebase)
- **Category**: perf
- **Planned at**: commit `639529e`, 2026-09-01

## Why this matters

`search` is the tool agents call most, and three of its costs scale with the wrong thing:

1. `getContextBatch` fetches context for all anchors in a chat with one query bounded by `min(anchor dates)..max(anchor dates)`. Two matches a year apart in a busy chat pull every message in between (tens of thousands of rows, each decoded and formatted through the contact resolver) to produce four context messages. Then it filters the whole array twice per anchor.
2. `SummaryPreviewFormatter` constructs an `NSDataDetector` and compiles two regular expressions on every call, and `makeExcerpt` normalizes the *entire* message body (`maxLength: Int.max`) before truncating to 160 characters. Both run once per search result and once per list-tool preview.
3. The `is_group` filter is a correlated `(SELECT COUNT(*) FROM chat_handle_join ...) > 1` evaluated for every candidate message row of a message-table scan. `EXISTS` with `LIMIT 1 OFFSET 1` answers the same question after two join rows instead of all of them.

After this plan the context query cost is proportional to the number of anchors (four rows each), the detector and regexes are built once per process, excerpts touch at most a few hundred characters, and the group filter short-circuits. Output is byte-identical for (1) and (3); (2) is identical except for one documented edge case.

## Current state

### Context batch with a min..max window

`swift/Sources/iMessageMax/Tools/SearchInternals.swift:365-436`:

```swift
    /// One windowed query per distinct chat, then slice 2-before / 2-after
    /// per anchor in Swift. `getContext` stays for the get_context tool.
    static func getContextBatch(
        db: Database,
        anchors: [(chatId: Int64, date: Int64)],
        resolver: ContactResolver
    ) async throws -> [String: (before: [SearchContextMessage], after: [SearchContextMessage])] {
        guard !anchors.isEmpty else { return [:] }

        var datesByChat: [Int64: [Int64]] = [:]
        for anchor in anchors {
            datesByChat[anchor.chatId, default: []].append(anchor.date)
        }

        var formattedByChat: [Int64: [(date: Int64, message: SearchContextMessage)]] = [:]
        for (chatId, dates) in datesByChat {
            guard let minDate = dates.min(), let maxDate = dates.max() else { continue }
            let rows = try db.query(
                """
                SELECT m.ROWID as msg_id, m.text, m.attributedBody, m.date, m.is_from_me, h.id as sender_handle
                FROM message m
                JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
                LEFT JOIN handle h ON m.handle_id = h.ROWID
                WHERE cmj.chat_id = ?
                  AND m.associated_message_type = 0
                  AND (
                    m.ROWID IN (
                      SELECT m2.ROWID
                      FROM message m2
                      JOIN chat_message_join cmj2 ON m2.ROWID = cmj2.message_id
                      WHERE cmj2.chat_id = ? AND m2.date < ? AND m2.associated_message_type = 0
                      ORDER BY m2.date DESC LIMIT 2
                    )
                    OR (m.date >= ? AND m.date <= ?)
                    OR m.ROWID IN (
                      SELECT m3.ROWID
                      FROM message m3
                      JOIN chat_message_join cmj3 ON m3.ROWID = cmj3.message_id
                      WHERE cmj3.chat_id = ? AND m3.date > ? AND m3.associated_message_type = 0
                      ORDER BY m3.date ASC LIMIT 2
                    )
                  )
                ORDER BY m.date
                """,
                params: [chatId, chatId, minDate, minDate, maxDate, chatId, maxDate]
            ) { row in
                ContextRow(
                    msgId: row.int(0),
                    text: row.string(1),
                    attributedBody: row.blob(2),
                    date: row.optionalInt(3),
                    isFromMe: row.int(4) != 0,
                    senderHandle: row.string(5)
                )
            }

            var formatted: [(date: Int64, message: SearchContextMessage)] = []
            for row in rows {
                formatted.append((row.date ?? 0, await formatContextMessage(row: row, resolver: resolver)))
            }
            formattedByChat[chatId] = formatted
        }

        var result: [String: (before: [SearchContextMessage], after: [SearchContextMessage])] = [:]
        for anchor in anchors {
            let messages = formattedByChat[anchor.chatId] ?? []
            let before = Array(messages.filter { $0.date < anchor.date }.suffix(2).map(\.message))
            let after = Array(messages.filter { $0.date > anchor.date }.prefix(2).map(\.message))
            result["\(anchor.chatId):\(anchor.date)"] = (before, after)
        }
        return result
    }
```

Semantics to preserve: for each anchor, `before` = the two newest non-reaction messages in the chat with `date < anchor.date`, in ascending date order; `after` = the two oldest with `date > anchor.date`, ascending. Messages *at* the anchor date (the anchor itself and any same-instant siblings) are excluded from both. Row `date` of NULL is treated as 0. Result keyed by `"\(chatId):\(date)"`.

The single-anchor form at `:438-470` (`getContext`, used by nothing in `search` any more; check with `grep -n "getContext(" swift/Sources`) issues two LIMIT 2 queries and is the shape each per-anchor window should take.

Existing test: `SearchToolTests.swift:316-370` `testIncludeContextQueryCountIsPerChatNotPerRow` — 20 results in one chat, asserts `queryCount <= 5`. That bound assumes one context query per chat; Step 1 changes the approach and will need a different bound (see the step).

### Detector and regexes built per call; excerpt normalizes the whole body

`swift/Sources/iMessageMax/Utilities/SummaryPreviewFormatter.swift:4-22`:

```swift
    static func formattedTextPreview(
        text: String?,
        attributedBody: Data?,
        maxLength: Int
    ) -> String? {
        guard let extracted = MessageTextExtractor.extract(text: text, attributedBody: attributedBody)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !extracted.isEmpty
        else {
            return nil
        }

        if isSyntheticAttachmentPlaceholderText(extracted) {
            return nil
        }

        let collapsed = collapseURLs(in: extracted)
        return truncate(collapsed, maxLength: maxLength)
    }
```

`SummaryPreviewFormatter.swift:93-109, 119-128`:

```swift
    private static func collapseURLs(in text: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return text
        }

        var output = text
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        for match in detector.matches(in: output, range: range).reversed() {
            guard let swiftRange = Range(match.range, in: output) else { continue }
            let host = normalizedHost(for: match.url)
            output.replaceSubrange(swiftRange, with: "[Link: \(host)]")
        }

        return output
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    ...
    private static func isSyntheticAttachmentPlaceholderText(_ text: String) -> Bool {
        let normalized = text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        let pattern = #"^(?:\[(?:Photo|Video|Audio|PDF|Attachment)\])+$"#
        return normalized.range(of: pattern, options: .regularExpression) != nil
    }

    private static func truncate(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength, maxLength > 3 else { return text }
        return String(text.prefix(maxLength - 3)) + "..."
    }
```

`swift/Sources/iMessageMax/Tools/SearchInternals.swift:525-554` (`makeExcerpt`):

```swift
    static func makeExcerpt(text: String?, query: String?) -> String {
        guard let text else { return "" }
        let normalized = SummaryPreviewFormatter.formattedTextPreview(
            text: text,
            attributedBody: nil,
            maxLength: Int.max
        ) ?? text
        guard normalized.count > 160 else { return normalized }

        let excerptLength = 160
        let nsText = normalized as NSString

        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lowerText = normalized.lowercased()
            let lowerQuery = query.lowercased()
            if let matchRange = lowerText.range(of: lowerQuery) {
                let matchLocation = lowerText.distance(from: lowerText.startIndex, to: matchRange.lowerBound)
                let halfWindow = excerptLength / 2
                let start = max(0, matchLocation - halfWindow)
                let length = min(excerptLength, nsText.length - start)
                let excerpt = nsText.substring(with: NSRange(location: start, length: length))
                let prefix = start > 0 ? "..." : ""
                let suffix = (start + length) < nsText.length ? "..." : ""
                return prefix + excerpt + suffix
            }
        }

        let excerpt = nsText.substring(to: min(excerptLength, nsText.length))
        return nsText.length > excerptLength ? excerpt + "..." : excerpt
    }
```

Note the excerpt is centred on the *first* match of the query in the normalized text. A query that matches only deep in a very long message needs that region normalized; that is the edge case Step 2 documents.

Existing test: `SearchToolTests.swift:286-315` `testFlatSearchAddsExcerptForLongMessages`. There is no `SummaryPreviewFormatterTests.swift` (`ls swift/Tests/iMessageMaxTests | grep -i preview` → check; create it in Step 2).

### is_group as a correlated COUNT

`swift/Sources/iMessageMax/Tools/SearchInternals.swift:127-137`:

```swift
        if let isGroupChat = isGroup {
            if isGroupChat {
                builder.where(
                    "(SELECT COUNT(*) FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID) > ?",
                    1)
            } else {
                builder.where(
                    "(SELECT COUNT(*) FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID) = ?",
                    1)
            }
        }
```

This is a WHERE clause on the main search query, whose driving table is `message` (read `QueryBuilder` usage at `:72-125` to confirm the FROM/JOIN order). `FindChat.swift:257, 259, 434` have the same shape but on a `chat`-driven query with a small candidate set; leave those alone.

Equivalent forms:

- group: `EXISTS (SELECT 1 FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID LIMIT 1 OFFSET 1)`
- direct: `NOT EXISTS (SELECT 1 FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID LIMIT 1 OFFSET 1)`

Careful: `COUNT(*) = 1` is *not* the same as `NOT EXISTS(... OFFSET 1)` when a chat has zero join rows. Current code treats a zero-participant chat as neither group nor direct. Preserve that: direct = `EXISTS (... LIMIT 1) AND NOT EXISTS (... LIMIT 1 OFFSET 1)`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| Full suite | `cd swift && swift test` | 0 failures, count ≥ 370 |
| Search tests | `cd swift && swift test --filter SearchToolTests` | 0 failures |
| Preview tests | `cd swift && swift test --filter SummaryPreviewFormatterTests` | 0 failures (after Step 2 creates it) |
| Sleep guard | `cd swift && swift test --filter LaunchdSafetyTests` | 0 failures |
| Query plan (before/after Step 3) | `sqlite3 -readonly ~/Library/Messages/chat.db "EXPLAIN QUERY PLAN <sql>"` | plan text; see Step 3 for what to compare |
| Timing (before/after Step 3) | `sqlite3 -readonly ~/Library/Messages/chat.db ".timer on" "<sql>"` | `Run Time: real N.NNN` line |

`sqlite3` on this machine is 3.51.0 (`sqlite3 --version`). `~/Library/Messages/chat.db` exists and is ~480 MB; open it `-readonly` only.

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Tools/SearchInternals.swift` (`getContextBatch`, `makeExcerpt`, the `isGroup` clause only)
- `swift/Sources/iMessageMax/Utilities/SummaryPreviewFormatter.swift`
- `swift/Tests/iMessageMaxTests/SearchToolTests.swift`
- `swift/Tests/iMessageMaxTests/SummaryPreviewFormatterTests.swift` (create)

**Out of scope** (do NOT touch, even though they look related):
- `SearchInternals.swift` name generation, `buildChatSummary`, `generateChatDisplayName`, grouped/flat builders — plan 068.
- `SearchInternals.getContext` (`:438+`) — the single-anchor form; keep it as-is (or delete it in a separate commit only if `grep -n "getContext(" swift/Sources` shows no callers, and say so).
- `FindChat.swift:254-260, 434` — chat-driven queries; the COUNT is cheap there.
- `GetContext.swift` — plan 070.
- Response JSON shape and any text of any field.
- `.mcp.json` — never touch.

## Git workflow

- Branch: `advisor/069-search-hot-path` from current `main`.
- Conventional commits, one per step: `test:`, `perf:`. Examples from `git log`: `ci: run the suite serially on macos-26`, `docs: record 060 serial CI`.
- Do NOT push or open a PR.
- Never commit secrets; none are involved. Do not commit any output from the operator's real `chat.db` (message text, handles). Paste only `EXPLAIN QUERY PLAN` lines and timings into the commit body.

Standing rules: never add `Task.sleep` under `swift/Sources` (`LaunchdSafetyTests` enforces it); never touch `.mcp.json`.

## Steps

### Step 1: Per-anchor context windows, byte-identical output

**Test first.** In `SearchToolTests.swift` add `testIncludeContextWindowsArePerAnchorAndExact`:

- One chat, handle 1, 30 non-reaction messages with dates `base + i*minute` for `i` in 0..<30, text `"filler i"`, except messages at `i = 5`, `15`, `25` have text `"anchorword i"`. Add one reaction row (`associatedMessageType: 2000`) at `i = 6` (it must never appear as context). Add a fourth message at exactly the same date as `i = 15` with text `"twin 15"` (same-instant sibling; must not appear in context for that anchor because `< / >` are strict).
- Run `SearchTool.execute(query: "anchorword", ..., format: "flat", includeContext: true, limit: 20, ...)` copying the argument list from `SearchToolTests.swift:351-364`.
- Assert three results, and for each: `context_before` texts are `["filler i-2", "filler i-1"]` and `context_after` are `["filler i+1", "filler i+2"]` (for `i = 15`, before is `["filler 13","filler 14"]` and after `["filler 16","filler 17"]`; the twin at the same instant is absent). Decode the JSON with `decodeSearchResponse` as the neighbouring tests do.

Run it: it must PASS against the current code (it is a characterization test). Commit it alone: `test: pin search include_context windows per anchor`.

**Then change** `getContextBatch`:

- Delete the min..max window. For each anchor, issue the two LIMIT 2 queries exactly as `getContext` at `:444-470` does (before: `m.date < ? ORDER BY m.date DESC LIMIT 2`; after: `m.date > ? ORDER BY m.date ASC LIMIT 2`), or, to keep one query per chat, bind all anchor dates into one statement built from `UNION ALL` of per-anchor subselects:

```sql
SELECT anchor_date, side, msg_id, text, attributedBody, date, is_from_me, sender_handle FROM (
  SELECT ? AS anchor_date, 'before' AS side, m.ROWID AS msg_id, m.text, m.attributedBody, m.date, m.is_from_me, h.id AS sender_handle
  FROM message m JOIN chat_message_join cmj ON m.ROWID = cmj.message_id LEFT JOIN handle h ON m.handle_id = h.ROWID
  WHERE cmj.chat_id = ? AND m.date < ? AND m.associated_message_type = 0
  ORDER BY m.date DESC LIMIT 2
)
UNION ALL
SELECT ... 'after' ... WHERE cmj.chat_id = ? AND m.date > ? ... ORDER BY m.date ASC LIMIT 2
-- repeated per anchor
```

The per-chat `UNION ALL` form keeps the query count at one per chat (so the existing `<= 5` bound at `:369` holds unchanged) and is the recommended shape. SQLite accepts `ORDER BY ... LIMIT` inside a parenthesised subselect that is a `UNION ALL` operand only when written as `SELECT * FROM (SELECT ... ORDER BY ... LIMIT 2)`; use that wrapping. Cap anchors per statement at 100 (200 subselects, 600 bindings; SQLite's default variable limit is 32766) and chunk beyond that.

- Format each row once through `formatContextMessage`; do not format rows twice when two anchors share a neighbour (dedupe by `msg_id` in a `[Int64: SearchContextMessage]` cache per chat).
- Assemble `result["\(chatId):\(anchorDate)"]` with `before` reversed to ascending order (the query returns DESC) and `after` as returned.
- Handle NULL `date` the same way (`row.optionalInt(3) ?? 0`) so a NULL-date row still sorts as 0.

**Verify**:
- `cd swift && swift test --filter SearchToolTests` → 0 failures, including `testIncludeContextWindowsArePerAnchorAndExact` and `testIncludeContextQueryCountIsPerChatNotPerRow` (bound `<= 5` unchanged if you used `UNION ALL`; if you chose two queries per anchor, that test's bound must rise and you must say so in the commit body and STOP if it exceeds `2 * anchors + 3`).
- `grep -n "m.date >= ? AND m.date <= ?" swift/Sources/iMessageMax/Tools/SearchInternals.swift` → no matches.
- `grep -n "messages.filter { \$0.date" swift/Sources/iMessageMax/Tools/SearchInternals.swift` → no matches.

Commit: `perf: bound search context windows per anchor instead of min..max per chat`.

### Step 2: Hoist the detector and regexes; pre-truncate before normalizing excerpts

**Test first.** Create `swift/Tests/iMessageMaxTests/SummaryPreviewFormatterTests.swift` (`import XCTest`, `@testable import iMessageMax`, `final class SummaryPreviewFormatterTests: XCTestCase`) with:

1. `testCollapsesLinksAndWhitespace`: `formattedTextPreview(text: "see  https://www.example.com/x\n\nnow", attributedBody: nil, maxLength: 200)` → `"see [Link: example.com] now"`.
2. `testSyntheticPlaceholderIsNil`: `"[Photo] [Video]"` → `nil`; `"[Photo] and text"` → non-nil.
3. `testTruncateAppendsEllipsis`: 200-char text with `maxLength: 50` → 50 chars ending in `"..."`.
4. `testMakeExcerptCentresOnFirstMatch`: 1000-char text `"a" * 600 + "needle" + "b" * 400`, query `"needle"` → starts with `"..."`, contains `"needle"`, length `3 + 160 + 3`.
5. `testMakeExcerptWithoutQueryTakesHead`: 500-char text, no query → 160 chars + `"..."`.
6. `testMakeExcerptWithLinkStraddlingTheCut`: text = 700 `"x"` characters, a space, then `"https://www.example.com/path"` then 300 `"y"`; query `"y"`. Record the exact current output as the expectation (run once, paste the string). This pins the behaviour Step 2's caveat changes; see below.

Run: all six pass against current code. Commit: `test: characterize SummaryPreviewFormatter and search excerpts`.

**Then change** `SummaryPreviewFormatter.swift`:

```swift
    private static let linkDetector: NSDataDetector? =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let whitespaceRun = try! NSRegularExpression(pattern: "\\s+")
    private static let placeholderRun = try! NSRegularExpression(
        pattern: #"^(?:\[(?:Photo|Video|Audio|PDF|Attachment)\])+$"#)
```

`NSDataDetector` and `NSRegularExpression` are documented thread-safe for matching; a `static let` on an enum is fine under Swift 6 strict concurrency because both types are `@Sendable`-annotated in Foundation on macOS 15. If the compiler rejects the `static let` with a Sendable diagnostic, wrap the property type as `nonisolated(unsafe) static let` and add a one-line comment citing the thread-safety guarantee; do not fall back to per-call construction.

Rewrite `collapseURLs` to use `linkDetector` and `whitespaceRun.stringByReplacingMatches(in:options:range:withTemplate: " ")`; rewrite `isSyntheticAttachmentPlaceholderText` to use the two hoisted regexes (`whitespaceRun` with template `""`, then `placeholderRun.firstMatch(...) != nil`).

**Then change** `makeExcerpt` in `SearchInternals.swift:525-531`: before normalizing, cut the raw text to a bounded window. Keep the normalized-space semantics by locating the query in the *raw* lowercased text first:

```swift
        let excerptLength = 160
        let rawWindow = 4 * excerptLength     // 640 chars of raw text is enough for a 160-char excerpt plus collapsed links
        let source: String
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let r = text.lowercased().range(of: query.lowercased()) {
            let center = text.distance(from: text.startIndex, to: r.lowerBound)
            let start = max(0, center - rawWindow / 2)
            source = String(text.dropFirst(start).prefix(rawWindow))
        } else {
            source = String(text.prefix(rawWindow))
        }
        let normalized = SummaryPreviewFormatter.formattedTextPreview(text: source, attributedBody: nil, maxLength: Int.max) ?? source
```

then the existing logic from `guard normalized.count > 160` onward, unchanged, with one addition: if `start > 0` and the returned excerpt does not already begin with `"..."`, prefix `"..."`.

Caveat to document in a comment above the function: a URL that straddles the raw-window boundary is collapsed from its truncated form, so `[Link: host]` may become `[Link: link]` or the raw fragment may appear. The window is four times the excerpt, so this needs a URL longer than ~240 characters positioned exactly at the edge. Update test 6's expectation if it changed, and say in the commit body what the old and new strings were. Tests 4 and 5 must still pass unchanged.

**Verify**:
- `cd swift && swift test --filter "SummaryPreviewFormatterTests|SearchToolTests"` → 0 failures.
- `grep -n "NSDataDetector(" swift/Sources/iMessageMax/Utilities/SummaryPreviewFormatter.swift` → exactly 1 match, on the `static let` line.
- `grep -n 'options: .regularExpression' swift/Sources/iMessageMax/Utilities/SummaryPreviewFormatter.swift` → no matches.
- `grep -n "maxLength: Int.max" swift/Sources/iMessageMax/Tools/SearchInternals.swift` → 1 match (the call is still there, now on the bounded `source`).

Commit: `perf: build the link detector and preview regexes once; bound excerpt normalization to a 640-char window`.

### Step 3: is_group via EXISTS, gated on a measured plan improvement

**Measure first.** Get the real search SQL: add a temporary `Log.debug` (or a `print` to stderr) of the built SQL in `SearchInternals` just after the `QueryBuilder` produces it, run `swift build` then

```bash
cd swift && .build/debug/imessage-max --help >/dev/null   # confirm the binary runs
```

and exercise `search` with `is_group: true` through whatever harness is easiest (`swift test --filter SearchToolTests` with the log enabled prints it; or write a one-off test that calls `SearchTool.execute(... isGroup: true ...)`). Copy the SQL, substitute literal values for `?`, and run:

```bash
sqlite3 -readonly ~/Library/Messages/chat.db "EXPLAIN QUERY PLAN <sql with COUNT form>"
sqlite3 -readonly ~/Library/Messages/chat.db ".timer on" "<sql with COUNT form>" | tail -1
```

Then the same with the `EXISTS (... LIMIT 1 OFFSET 1)` form substituted. Remove the temporary log before committing.

Decision rule: proceed only if the `EXISTS` form shows either a different (cheaper) plan line for the subquery (`CORRELATED SCALAR SUBQUERY` → `CORRELATED SCALAR SUBQUERY` with `USING COVERING INDEX` where COUNT had none, or the subquery disappears into a semi-join) **or** the real time drops by at least 20% on a warm run (run each three times, compare the best). If neither, STOP and report both plans and timings; keep the COUNT.

**Then change** `SearchInternals.swift:127-137`:

```swift
        if let isGroupChat = isGroup {
            if isGroupChat {
                builder.where(
                    "EXISTS (SELECT 1 FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID LIMIT 1 OFFSET 1)",
                    [])
            } else {
                builder.where(
                    "EXISTS (SELECT 1 FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID LIMIT 1) AND NOT EXISTS (SELECT 1 FROM chat_handle_join chj2 WHERE chj2.chat_id = c.ROWID LIMIT 1 OFFSET 1)",
                    [])
            }
        }
```

Check the `builder.where` overloads (`QueryBuilder.swift`, and `CHANGELOG.md:30` notes it accepts an array of bindings) and use whichever accepts a clause with no parameters.

Add to `SearchToolTests.swift` `testIsGroupFilterMatchesCountSemantics`: three chats — 0 handles, 1 handle, 2 handles — each with one message containing `"grpword"`; `is_group: true` returns only the 2-handle chat's message; `is_group: false` returns only the 1-handle chat's message; `is_group: nil` returns all three. Write this test *before* the change and confirm it passes with the COUNT form (it pins the zero-participant behaviour).

**Verify**:
- `cd swift && swift test --filter SearchToolTests` → 0 failures.
- `grep -n "SELECT COUNT(\*) FROM chat_handle_join" swift/Sources/iMessageMax/Tools/SearchInternals.swift` → no matches.
- `grep -n "SELECT COUNT(\*) FROM chat_handle_join" swift/Sources/iMessageMax/Tools/FindChat.swift` → 3 matches (untouched).
- No stray debug logging: `git diff main -- swift/Sources | grep -n "print(\|Log.debug"` → no additions.

Commit: `perf: is_group search filter uses EXISTS with OFFSET 1 instead of a correlated COUNT` with the before/after plan lines and timings in the body.

## Test plan

- Step 1: `testIncludeContextWindowsArePerAnchorAndExact` (three anchors, one chat, reaction excluded, same-instant twin excluded). Existing `testIncludeContextQueryCountIsPerChatNotPerRow` and `testFuzzySearchMatchesTyposAndIncludesContext` must pass unchanged.
- Step 2: six tests in the new `SummaryPreviewFormatterTests.swift`; `testFlatSearchAddsExcerptForLongMessages` unchanged.
- Step 3: `testIsGroupFilterMatchesCountSemantics` (0/1/2 participants).
- Pattern to model on: `SearchToolTests.swift:316-370` (fixture building, `SearchTool.execute` argument list, `decodeSearchResponse`, query counting).
- Final: `cd swift && swift test` → 0 failures, count ≥ 370 + 8.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift build` exits 0
- [ ] `cd swift && swift test` exits 0 with 0 failures
- [ ] `grep -n "m.date >= ? AND m.date <= ?" swift/Sources/iMessageMax/Tools/SearchInternals.swift` → no matches
- [ ] `grep -c "NSDataDetector(" swift/Sources/iMessageMax/Utilities/SummaryPreviewFormatter.swift` → `1`
- [ ] `grep -c 'options: .regularExpression' swift/Sources/iMessageMax/Utilities/SummaryPreviewFormatter.swift` → `0`
- [ ] `test -f swift/Tests/iMessageMaxTests/SummaryPreviewFormatterTests.swift`
- [ ] Either `grep -c "SELECT COUNT(\*) FROM chat_handle_join" swift/Sources/iMessageMax/Tools/SearchInternals.swift` → `0`, or the plan status row says Step 3 was kept as COUNT with the measured plans quoted
- [ ] `grep -c "SELECT COUNT(\*) FROM chat_handle_join" swift/Sources/iMessageMax/Tools/FindChat.swift` → `3`
- [ ] `grep -rn "Task.sleep" swift/Sources` → no matches
- [ ] `git status --porcelain` lists only in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any "Current state" excerpt does not match the live file.
- The Step 1 characterization test fails against *current* code (the documented window semantics are wrong; the plan's target output is then undefined).
- The `UNION ALL` form is rejected by SQLite in the test fixture and the two-queries-per-anchor fallback pushes `testIncludeContextQueryCountIsPerChatNotPerRow` above `2 * anchors + 3`.
- Swift 6 strict concurrency rejects the hoisted `static let` and `nonisolated(unsafe)` is also rejected.
- Step 3's `EXPLAIN QUERY PLAN` / timing comparison shows no improvement (keep COUNT, report both).
- `~/Library/Messages/chat.db` cannot be opened read-only (Full Disk Access missing for the terminal); report and skip Step 3's measurement rather than changing the clause unmeasured.
- Plan 068 has landed and `SearchInternals.swift` line numbers have moved so that the excerpts here no longer locate the code by content.

## Maintenance notes

- **Context window shape is now the same as `getContext`** (two LIMIT 2 queries per anchor, folded into one statement per chat). If `get_context`'s neighbour rules change (plan 070 adds a `contains` window but does not change before/after), change both.
- **The excerpt window is 4× the excerpt length**. If `excerptLength` changes, `rawWindow` follows it automatically; if collapsed-link output gets longer than `[Link: host]`, revisit the multiplier.
- **Reviewer should scrutinize**: the per-anchor test's same-instant twin case (strict `<`/`>`), the dedupe-by-`msg_id` cache in Step 1 (a message that is "after" for anchor A and "before" for anchor B must format identically), and that the Step 3 commit body quotes real `EXPLAIN QUERY PLAN` output with no message text from the operator's database.
- **Deferred**: `getContext` (`:438+`) can be deleted or made to call `getContextBatch` with one anchor; left out to keep this plan's diff to the hot path. `FindChat`'s three COUNT subqueries were left because their driving table is `chat`.
