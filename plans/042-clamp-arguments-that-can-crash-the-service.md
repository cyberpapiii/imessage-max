# Plan 042: Clamp every tool argument that can trap the process

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 61e75d9..HEAD -- swift/Sources/iMessageMax/Database/AppleTime.swift swift/Sources/iMessageMax/Tools/SearchInternals.swift swift/Sources/iMessageMax/Tools/Search.swift swift/Sources/iMessageMax/Tools/GetMessages.swift swift/Sources/iMessageMax/Tools/GetMessagesInternals.swift swift/Sources/iMessageMax/Tools/FindChat.swift swift/Tests/iMessageMaxTests/AppleTimeParseTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: 041 (the AppleTime and limit characterization tests; this plan turns the skipped test on)
- **Category**: bug
- **Planned at**: commit `61e75d9`, 2026-09-01

## Why this matters

Four plain tool arguments crash the whole server process today. Swift integer conversion and multiplication trap on overflow, and the server runs as a launchd service shared by every MCP client on the machine, so one agent passing `since: "999999999h"`, `unanswered_hours: 9223372036854775807`, or `limit: -1` takes the service down for all of them until launchd restarts it. None of these need to be malicious; a model that miscounts hours is enough.

After this plan every numeric argument is clamped to a sane range before arithmetic, `AppleTime` saturates instead of trapping, and a test proves each former crash input now returns a normal response.

## Current state

**Crash 1: date conversion.** `swift/Sources/iMessageMax/Database/AppleTime.swift:16-18`:

```swift
static func fromDate(_ date: Date) -> Int64 {
    Int64(date.timeIntervalSinceReferenceDate * 1_000_000_000)
}
```

`Int64(Double)` traps when the Double is outside Int64's range (about ±292 years in nanoseconds). `parseRelative` (`:40-61`) accepts any digit string: `"999999999h"` is 3.6e15 seconds, times 1e9 overflows. `parseISO` accepts `"9999-01-01T00:00:00Z"` (2.5e11 s), which also overflows. `parseNatural` (`:106-123`) accepts `"999999999 days ago"`; `Calendar.date(byAdding:)` returns nil for absurd values on some inputs but not all. Callers: `Tools/GetMessages.swift:259-260`, `Tools/SearchInternals.swift:80,84`, `Tools/GetUnread.swift:179`, `Tools/ListAttachments.swift:447`, `Tools/ListChats.swift:184`, and `Tools/SendVerifier.swift:59` (which passes `Date()` and is safe).

**Crash 2: unanswered-hours window.** `swift/Sources/iMessageMax/Tools/SearchInternals.swift:195-201`:

```swift
static func hasReplyWithinWindow(db: Database, chatId: Int64, messageDate: Int64, hours: Int) throws -> Bool {
    let windowNs = Int64(hours) * 60 * 60 * 1_000_000_000
```

and the same expression at `Tools/GetMessagesInternals.swift:389-390`. `hours` comes unclamped from `Tools/Search.swift:237` (`arguments?["unanswered_hours"]?.intValue ?? 24`) and `Tools/GetMessages.swift:223`. Any value above 2,562,047 hours overflows the multiply. Negative values produce a negative window (no crash, wrong answer).

**Crash 3: find_chat limit.** `swift/Sources/iMessageMax/Tools/FindChat.swift:55`:

```swift
self.limit = arguments?["limit"]?.intValue ?? 5
```

never clamped. `FindChat.swift:334` does `Array(sorted.prefix(limit))`, which traps on a negative `limit`. `FindChat.swift:429` does `min(max(limit * 10, 50), 200)` where `limit * 10` overflows for `limit > Int.max / 10`.

**Crash 4: get_messages fetch multiplier.** `swift/Sources/iMessageMax/Tools/GetMessages.swift:216`:

```swift
let limit = min(args["limit"]?.intValue ?? defaultLimit, maxLimit)
```

has an upper bound (`maxLimit` = 200, line 8) but no lower bound. Line 266: `let fetchLimit = unanswered ? limit * 3 : limit`. A negative limit reaches `QueryBuilder.limit(_:)` at `GetMessagesInternals.swift:326` and then `LIMIT -N` in SQL (SQLite treats a negative LIMIT as "no limit", so this is a full-table scan, not a crash). `limit * 3` cannot overflow because of the `min`, but negative limits still need the lower bound.

Reference clamps already in the codebase, to copy: `Tools/ListChats.swift:173` and `Tools/Search.swift:306` both do `max(1, min(limit, 100))`.

Repo conventions: tools validate arguments at the top of `execute`/`executeImpl` and return structured errors for invalid input rather than throwing. Clamping (not erroring) is the existing convention for out-of-range limits; keep it.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | `Build complete!` |
| Focused tests | `cd swift && swift test --filter "AppleTimeParseTests|SearchToolTests|GetMessagesToolTests|ProductOpenItemsTests"` | 0 failures |
| Whole suite | `cd swift && swift test` | 0 failures |
| Launchd rule | `cd swift && swift test --filter LaunchdSafetyTests` | 0 failures (you must not add `Task.sleep`) |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Database/AppleTime.swift`
- `swift/Sources/iMessageMax/Tools/Search.swift` (clamp `unansweredHours`)
- `swift/Sources/iMessageMax/Tools/GetMessages.swift` (clamp `limit` and `unansweredHours`)
- `swift/Sources/iMessageMax/Tools/FindChat.swift` (clamp `limit`)
- `swift/Sources/iMessageMax/Tools/SearchInternals.swift` and `swift/Sources/iMessageMax/Tools/GetMessagesInternals.swift` (defensive clamp inside `hasReplyWithinWindow`)
- `swift/Tests/iMessageMaxTests/AppleTimeParseTests.swift` (replace the skip with the real test)
- `swift/Tests/iMessageMaxTests/ArgumentClampTests.swift` (create)

**Out of scope** (do NOT touch, even though they look related):
- The search recall / find_chat predicate logic (`Search.swift:318`, `FindChat.swift:430-443`) — plan 045.
- Duplicating `hasReplyWithinWindow` — plan 054 merges the two copies; here just add the same one-line clamp to both.
- `ListChats`, `GetUnread`, `ListAttachments`, `GetContext` limits — they already clamp or take no limit; do not restructure them.
- Changing the client-visible response when a value is clamped. Silent clamping is the existing contract.

## Git workflow

- Branch: `advisor/042-argument-clamps`
- Conventional commits, type `fix:`. Example: `fix: saturate AppleTime.fromDate instead of trapping on out-of-range dates`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Saturating `AppleTime.fromDate` and bounded relative parsing

In `AppleTime.swift` replace `fromDate`:

```swift
/// Convert Date to Apple nanoseconds timestamp.
///
/// Saturates at the Int64 range instead of trapping: `Int64(Double)` crashes
/// on values outside ±9.2e18, which a relative bound like "999999999h" or an
/// ISO year 9999 reaches easily. A trap here takes down the launchd service.
static func fromDate(_ date: Date) -> Int64 {
    let nanoseconds = date.timeIntervalSinceReferenceDate * 1_000_000_000
    if nanoseconds >= Double(Int64.max) { return Int64.max }
    if nanoseconds <= Double(Int64.min) { return Int64.min }
    if nanoseconds.isNaN { return 0 }
    return Int64(nanoseconds)
}
```

(`Double(Int64.max)` rounds up to 2^63, which is why the comparison is `>=`.)

In `parseRelative`, after computing `seconds`, add a cap so relative bounds cannot exceed 100 years:

```swift
let maxRelativeSeconds: Double = 100 * 365 * 86400
let bounded = min(seconds, maxRelativeSeconds)
return Date().addingTimeInterval(-bounded)
```

In `parseNatural`, the `"N days/weeks/months ago"` branch: guard `num <= 36_500` (days), `<= 5_200` (weeks), `<= 1_200` (months) before calling `calendar.date(byAdding:)`; return nil otherwise. `Int(lower[numRange])` already returns nil for values that do not fit `Int`, so no further guard is needed there.

**Verify**: `cd swift && swift build` → `Build complete!`.

### Step 2: Turn on the skipped AppleTime test

In `swift/Tests/iMessageMaxTests/AppleTimeParseTests.swift`, replace the body of `testHugeRelativeValueDoesNotTrap`:

```swift
func testHugeRelativeValueDoesNotTrap() {
    for input in ["999999999h", "99999999999d", "9999-01-01T00:00:00Z", "0001-01-01T00:00:00Z", "999999999 days ago"] {
        let result = AppleTime.parse(input)
        // Either nil (rejected) or a finite Int64; the point is no trap.
        if let result {
            XCTAssertTrue(result <= Int64.max && result >= Int64.min, input)
        }
    }
    // A relative bound is capped at 100 years, not dropped.
    let capped = try? XCTUnwrap(AppleTime.parse("999999999h"))
    XCTAssertNotNil(capped)
}
```

**Verify**: `cd swift && swift test --filter AppleTimeParseTests` → `Executed 8 tests, with 0 failures`, no `skipped` line.

### Step 3: Clamp `unanswered_hours` at both entry points and inside the window helpers

`Search.swift:237`:

```swift
let unansweredHours = max(1, min(arguments?["unanswered_hours"]?.intValue ?? 24, 24 * 365))
```

`GetMessages.swift:223`:

```swift
let unansweredHours = max(1, min(args["unanswered_hours"]?.intValue ?? defaultUnansweredHours, 24 * 365))
```

Inside both `hasReplyWithinWindow` implementations (`SearchInternals.swift:201`, `GetMessagesInternals.swift:390`), replace the first line with:

```swift
let boundedHours = Int64(max(1, min(hours, 24 * 365)))
let windowNs = boundedHours * 3_600_000_000_000
```

(One year in hours times 3.6e12 is 3.15e16, far inside Int64.)

**Verify**: `cd swift && swift build` → `Build complete!`; `grep -n "24 \* 365" swift/Sources/iMessageMax/Tools/Search.swift swift/Sources/iMessageMax/Tools/GetMessages.swift swift/Sources/iMessageMax/Tools/SearchInternals.swift swift/Sources/iMessageMax/Tools/GetMessagesInternals.swift` → 4 matches.

### Step 4: Clamp `find_chat` and `get_messages` limits

`FindChat.swift:55`:

```swift
self.limit = max(1, min(arguments?["limit"]?.intValue ?? 5, 50))
```

(50 is generous: the tool returns "best matching chats" and the docs describe it as a small ranked list. Check the tool's `description` string in the same file; if it advertises a different maximum, use that number.)

`GetMessages.swift:216`:

```swift
let limit = max(1, min(args["limit"]?.intValue ?? defaultLimit, maxLimit))
```

**Verify**: `cd swift && swift build` → `Build complete!`.

### Step 5: Regression tests

Create `swift/Tests/iMessageMaxTests/ArgumentClampTests.swift`. Use `ToolTestDatabase` (see `SendToolExecuteTests.swift:59-75` for a fixture with two handles and two chats; copy that helper privately) and call each tool's `execute` with the hostile argument, asserting the call returns without trapping and yields a decodable JSON dictionary. Tests:

1. `testSearchWithHugeUnansweredHoursReturns` — `SearchTool` with `query: "hello", unanswered: true, unanswered_hours: Int.max`. Find `SearchTool`'s initializer and `execute` signature in `Search.swift` (it takes `db:` and `resolver:`; the `execute(arguments:)` entry is what the registry calls). Assert the result decodes and has no `"error"` key equal to `"internal_error"`.
2. `testGetMessagesWithNegativeLimitReturns` — `limit: -5, chat_id: "chat1"`; assert the result decodes and `messages` count is ≤ 1 (clamped to 1).
3. `testGetMessagesWithHugeUnansweredHoursReturns` — `unanswered: true, unanswered_hours: Int.max`.
4. `testFindChatWithNegativeLimitReturns` — `participants: ["+15550000001"], limit: -1`; assert decodes.
5. `testFindChatWithHugeLimitReturns` — `limit: Int.max`; assert decodes.
6. `testSinceWithHugeRelativeValueDoesNotDropFilterOrTrap` — `GetMessagesTool` with `since: "999999999h"`; assert the call returns.

Pattern for invoking a tool and decoding: `SendToolExecuteTests.swift:229-234` (`tool.execute(args:)` then `decodeJSONDictionary(from:)`). Other tools may expose `execute` with a different label; read each tool file's `func execute` and match it.

**Verify**: `cd swift && swift test --filter ArgumentClampTests` → `Executed 6 tests, with 0 failures`. To prove the tests bite, temporarily revert Step 4's `FindChat` clamp and re-run: `testFindChatWithNegativeLimitReturns` must crash the test process. Restore the clamp.

### Step 6: Full suite

**Verify**: `cd swift && swift test` → 0 failures, count = previous baseline + 6.

## Test plan

- New: `ArgumentClampTests` (6 methods) covering each former crash input per tool.
- Changed: `AppleTimeParseTests.testHugeRelativeValueDoesNotTrap` from skip to real assertion.
- Mutation check in Step 5 proves at least one test crashes without the fix.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` → 0 failures
- [ ] `grep -n "XCTSkip" swift/Tests/iMessageMaxTests/AppleTimeParseTests.swift` → no matches
- [ ] `grep -n "Int64(date.timeIntervalSinceReferenceDate \* 1_000_000_000)" swift/Sources` → no matches
- [ ] `grep -n "Int64(hours) \* 60 \* 60" swift/Sources` → no matches
- [ ] `grep -n 'intValue ?? 5$' swift/Sources/iMessageMax/Tools/FindChat.swift` → no matches
- [ ] `cd swift && swift test --filter LaunchdSafetyTests` → 0 failures
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Plan 041 has not landed (no `AppleTimeParseTests.swift` on the branch). Land 041 first.
- A tool's `execute` signature does not accept a `[String: Value]` dictionary the way `SendTool.execute(args:)` does, and you cannot find how the registry calls it within `swift/Sources/iMessageMax/Server/ToolRegistry.swift`. Report rather than guessing.
- The find_chat description advertises a maximum limit that conflicts with 50 and you are unsure which to honour.
- Any existing test asserts on the exact numeric behaviour of a limit you are clamping (for example, expects `limit: 0` to return an empty list). Report the test name; the contract decision is the operator's.

## Maintenance notes

- Every new tool argument that feeds arithmetic or `prefix`/`LIMIT` must be clamped at the parse site, following `max(lower, min(value, upper))`. The reviewer should reject any new `intValue ?? default` that reaches arithmetic unclamped.
- Plan 054 merges the two `hasReplyWithinWindow` copies. When it does, keep the bounded-hours line.
- Deferred: returning a structured `invalid_argument` error instead of clamping silently. Clamping matches the existing contract for `list_chats` and `search`; changing it is a product decision.
