# Plan 041: Characterize the untested hot paths before the fixes that follow touch them

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 61e75d9..HEAD -- swift/Tests/iMessageMaxTests swift/Sources/iMessageMax/Database/AppleTime.swift swift/Sources/iMessageMax/Contacts/PhoneUtils.swift swift/Sources/iMessageMax/Utilities/TimelineCursor.swift swift/Sources/iMessageMax/Server/OriginValidationMiddleware.swift swift/Sources/iMessageMax/Tools/Send.swift swift/Sources/iMessageMax/Tools/SendVerifier.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: 040 (so CI can run the new tests). Must land **before** 042, 043, 045, 049, and 054, which change the code these tests pin.
- **Category**: tests
- **Planned at**: commit `61e75d9`, 2026-09-01

## Why this matters

Several pieces of logic that decide what an agent sees, or who a message goes to, have no direct tests: the `since`/`before` date parser used by six tools, phone normalization on the send path, both cursor codecs, the host-parsing branches of the DNS-rebinding defense, and the `mismatch` send status that means "your message went to the wrong chat". The plans that follow change every one of these. Without characterization tests first, a fix can silently change behaviour the current tests never observe.

This plan adds table-driven tests that pin **today's** behaviour where it is correct, and marks the known-bad cases with expectations for the correct behaviour so the follow-up plans turn them green. It also fixes one stale test comment and one inconsistent test-isolation hook.

## Current state

Files and their roles:

- `swift/Sources/iMessageMax/Database/AppleTime.swift` — `parse(_:) -> Int64?` (line 21) tries `parseRelative` (`24h`, `7d`, `2w`, `3m`), then `parseISO`, then `parseNatural` (`yesterday`, `today`, `this week`, `last month`, `3 days ago`, `last tuesday`). Returns `nil` on anything else. Callers pass `since.flatMap { AppleTime.parse($0) }` and **drop the filter silently** when it returns nil (`Tools/GetMessages.swift:259`, `Tools/SearchInternals.swift:80`, `Tools/GetUnread.swift:179`, `Tools/ListAttachments.swift:447`, `Tools/ListChats.swift:184`).
- `swift/Sources/iMessageMax/Contacts/PhoneUtils.swift` — `normalizeToE164`, `formatDisplay`, `isPhoneNumber`, `isEmail`. Whole file:

```swift
enum PhoneUtils {
    static func normalizeToE164(_ input: String) -> String? {
        let digits = input.filter { $0.isNumber }
        let hasPlus = input.hasPrefix("+")

        guard !digits.isEmpty else { return nil }

        if digits.count == 10 {
            return "+1\(digits)"
        } else if digits.count == 11 && digits.hasPrefix("1") {
            return "+\(digits)"
        } else if hasPlus {
            return "+\(digits)"
        } else if digits.count > 10 {
            return "+\(digits)"
        }

        return nil
    }
    // formatDisplay, isPhoneNumber (digits.count >= 10 && <= 15), isEmail follow
}
```

  Known bug (fixed by plan 043, **pinned here as an expected-correct case**): `"+4512345678"` (Danish number, 10 digits after `+`) currently returns `"+14512345678"` because the 10-digit branch runs before the `hasPlus` branch.

- `swift/Sources/iMessageMax/Utilities/TimelineCursor.swift` — `TimelineCursor.encode/decode` (`"date:messageId"`) and `ChatListCursor.encode/decode/encodeName/decodeName` (`"primary:chatId"`, `"primary:secondary:chatId"`, `"n:<name>:chatId"` where the name may itself contain colons and is split from the right with `lastIndex(of: ":")`).
- `swift/Sources/iMessageMax/Server/OriginValidationMiddleware.swift:72-98` — host-without-port extraction with four branches: bracketed IPv6 (`[::1]:8080` → `[::1]`), bare IPv6 (more than one colon → unchanged), hostname/IPv4 with digit-only port suffix (strip), and everything else (unchanged). Then `guard allowedHosts.contains(hostWithoutPort)` at line 100. The `requireOrigin` branch (line 43) returns 403 `"Origin header required"`.
- `swift/Tests/iMessageMaxTests/HTTPTransportIntegrationTests.swift:469-530` — the only middleware test, `testOriginMiddlewareRejectsBadOriginAndHost`. It builds `Request` values directly (see excerpt below) with authorities `"localhost"` and `"example.com"` only.
- `swift/Sources/iMessageMax/Tools/Send.swift:113-124` — `SendResponse.mismatch(...)` produces `status: "mismatch"`. `Send.swift:472-478` maps `VerificationResult.mismatch` to it. No test asserts `"mismatch"` on the response envelope (`grep -rn '"mismatch"' swift/Tests` → 0 hits).
- `swift/Tests/iMessageMaxTests/SendVerifierTests.swift:138-167` — has a stale comment claiming the fixture cannot insert `attributedBody`. The fixture has accepted `attributedBody: Data?` since `ToolTestSupport.swift:74`.
- `swift/Tests/iMessageMaxTests/ToolRegistryBindingTests.swift` — the only class using `ToolHandlerRegistry.shared` that never calls `resetForTesting()`. Sibling classes reset in `setUp`/`tearDown` or at the top of each test (`ToolRegistryTests.swift:7`).

Exemplar test conventions (match these):

- Pure-function tests: `swift/Tests/iMessageMaxTests/HostBindingPolicyTests.swift` (loops over an array of inputs with a message per assertion).
- Fixture-backed tool tests: `SendToolExecuteTests.swift` builds `ToolTestDatabase` via `makeSendFixture()`, inserts rows with `fixture.insertMessage(rowId:guid:text:date:isFromMe:error:isSent:)`, joins with `joinChatMessage`, and decodes the tool result with `decodeJSONDictionary(from:)`. `testStubSendWithMatchingRowConfirms` (line 209) is the pattern for the mismatch test.
- Middleware tests build `Request(head: .init(method:scheme:authority:path:headerFields:), body: .init(buffer: ByteBuffer()))` and a `BasicRequestContext` from `ApplicationRequestContextSource(channel: EmbeddedChannel(), logger:)`, then call `middleware.handle(request, context:) { _, _ in Response(status: .ok) }`.
- Typedstream blobs for tests: `MessageTextExtractorTests.swift:8` has a private `typedstreamBlob(marker:lengthField:payload:)` helper building `[0x04, 0x0B] + marker + 5 filler bytes + length + payload`. Copy that helper (it is `private`) into the verifier test file rather than widening its access.
- Test files are XCTest, one `final class XxxTests: XCTestCase` per file, `@testable import iMessageMax`. Do **not** introduce Swift Testing (`import Testing`); the suite is XCTest-only by decision.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build tests | `cd swift && swift build --build-tests` | `Build complete!` |
| One class | `cd swift && swift test --filter AppleTimeParseTests` | `Executed N tests, with 0 failures` |
| Whole suite | `cd swift && swift test` | `Executed 278+N tests, with 0 failures` (278 is the baseline at `61e75d9`) |
| Count new tests | `grep -c "func test" swift/Tests/iMessageMaxTests/<File>.swift` | as stated per step |

## Scope

**In scope** (the only files you should modify):
- `swift/Tests/iMessageMaxTests/AppleTimeParseTests.swift` (create)
- `swift/Tests/iMessageMaxTests/PhoneUtilsTests.swift` (create)
- `swift/Tests/iMessageMaxTests/CursorCodecTests.swift` (create)
- `swift/Tests/iMessageMaxTests/OriginHostParsingTests.swift` (create)
- `swift/Tests/iMessageMaxTests/SendToolExecuteTests.swift` (add two tests)
- `swift/Tests/iMessageMaxTests/SendVerifierTests.swift` (add one test, fix one comment)
- `swift/Tests/iMessageMaxTests/ToolRegistryBindingTests.swift` (add setUp/tearDown)

**Out of scope** (do NOT touch, even though they look related):
- Any file under `swift/Sources/`. This plan writes tests only. Where a test documents a bug, it uses `XCTExpectFailure` so the suite stays green until the fixing plan lands (see Step 2).
- `swift/Tests/iMessageMaxTests/HTTPTransportIntegrationTests.swift` — leave the existing middleware test alone; the new cases go in their own file.
- `get_context` / `find_chat` behavioural coverage — deferred, see Maintenance notes.

## Git workflow

- Branch: `advisor/041-characterization-tests`
- One commit per step; conventional commits, type `test:`. Example: `test: pin AppleTime.parse across relative, ISO, and natural inputs`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: `AppleTimeParseTests.swift`

Create the file. Tests (all on `AppleTime.parse`, comparing the returned Apple-epoch nanoseconds via `AppleTime.toDate` back to a `Date` within a tolerance of 2 seconds against a value computed the same way in the test):

1. `testRelativeUnits` — table `["1h": 3600, "24h": 86400, "7d": 604800, "2w": 1209600, "1m": 2592000]`: each result is `Date()` minus that many seconds, within 2 s.
2. `testISO8601WithAndWithoutFractionalSeconds` — `"2026-01-15T10:30:00Z"` and `"2026-01-15T10:30:00.500Z"` both parse; `toDate` of the first equals `ISO8601DateFormatter().date(from:)` exactly.
3. `testNaturalKeywords` — `"yesterday"`, `"today"`, `"this week"`, `"this month"`, `"this year"`, `"last week"`, `"last month"`, `"last year"` all return non-nil, and `"today"` equals `Calendar.current.startOfDay(for: Date())` within 2 s.
4. `testNDaysAgo` — `"3 days ago"`, `"2 weeks ago"`, `"1 month ago"` return non-nil and are in the past.
5. `testLastWeekday` — for each of the seven weekday names, `"last <day>"` returns a date 1–7 days in the past whose `Calendar.current.component(.weekday, from:)` matches the requested day.
6. `testCaseAndWhitespaceInsensitiveNatural` — `"  Yesterday "` parses (the parser lowercases and trims).
7. `testGarbageReturnsNil` — `""`, `"soon"`, `"24 hours"`, `"h24"`, `"2026-13-45"` all return nil.
8. `testHugeRelativeValueDoesNotTrap` — wrap in `XCTExpectFailure("AppleTime.fromDate traps on out-of-range dates; fixed by plan 042", strict: true)` and assert `AppleTime.parse("999999999h")` is either nil or a finite Int64. **Caution:** at `61e75d9` this input crashes the process with an overflow trap, and `XCTExpectFailure` cannot catch a trap. So instead of calling it, this test must assert on the *precondition* that plan 042 introduces: skip it entirely for now. Implement as:

   ```swift
   func testHugeRelativeValueDoesNotTrap() throws {
       throw XCTSkip("Enable after plan 042: AppleTime.parse(\"999999999h\") traps at 61e75d9")
   }
   ```

   Plan 042 replaces the body with the real assertion.

**Verify**: `cd swift && swift test --filter AppleTimeParseTests` → `Executed 8 tests, with 0 failures` and one line containing `skipped`.

### Step 2: `PhoneUtilsTests.swift`

Create the file with these tests on `PhoneUtils`:

1. `testTenDigitUSNumberGetsCountryCode` — `"5551234567"` → `"+15551234567"`; `"(555) 123-4567"` → same.
2. `testElevenDigitWithLeadingOne` — `"15551234567"` → `"+15551234567"`; `"+1 555 123 4567"` → same.
3. `testInternationalWithPlusIsPreserved` — `"+447911123456"` → `"+447911123456"` (12 digits, passes today).
4. `testShortInternationalWithPlusIsNotRewrittenToUS` — `"+4512345678"` (Denmark) → `"+4512345678"`, `"+6591234567"` (Singapore) → `"+6591234567"`. These **fail today** (they return `+14512345678` / `+16591234567`). Wrap the whole body in:

   ```swift
   XCTExpectFailure("10 digits after '+' are rewritten to +1; fixed by plan 043", strict: true)
   ```

   `strict: true` means the test turns red again once plan 043 fixes the bug and the executor of 043 must remove the wrapper. That is the intended handshake.
5. `testEmptyOrNoDigitsReturnsNil` — `""`, `"abc"`, `"+"` → nil.
6. `testFormatDisplayUS` — `"+15551234567"` → `"+1 (555) 123-4567"`; `"+447911123456"` → unchanged.
7. `testIsPhoneNumberBounds` — 10 and 15 digits true; 9 and 16 false; `"alice@example.com"` false.
8. `testIsEmail` — `"a@b.co"` true; `"a@b"` false; `"ab.co"` false.

**Verify**: `cd swift && swift test --filter PhoneUtilsTests` → `Executed 8 tests, with 0 failures` (the expected-failure test counts as passing).

### Step 3: `CursorCodecTests.swift`

Create the file:

1. `testTimelineCursorRoundTrip` — `TimelineCursor.encode(date: 123, messageId: 456)` → `"123:456"`; `decode` of that → `TimelineCursor(date: 123, messageId: 456)`.
2. `testTimelineCursorNilDateEncodesNil` — `encode(date: nil, messageId: 1)` → nil.
3. `testTimelineCursorDecodeRejectsMalformed` — `"123"`, `"a:b"`, `"1:2:3"`, `""` → nil.
4. `testTimelineCursorSQLFragments` — `olderThanSQL` is `"(m.date < ? OR (m.date = ? AND m.ROWID < ?))"`, `olderThanParams` is `[date, date, messageId]` (compare as `[Int64]` after casting), and the same for `newerThan*` with `>`.
5. `testChatListCursorTwoAndThreePartRoundTrip` — `encode(primary: 10, secondary: nil, chatId: 5)` → `"10:5"`; `encode(primary: 10, secondary: 20, chatId: 5)` → `"10:20:5"`; both decode back.
6. `testChatListCursorNameWithColonsRoundTrips` — `encodeName(name: "Team: Ops: 2026", chatId: 7)` → `"n:Team: Ops: 2026:7"`; `decodeName` → `(name: "Team: Ops: 2026", chatId: 7)`; `decode` of the same string → nil (name cursors are not numeric cursors).
7. `testChatListCursorDecodeRejectsMalformed` — `"x:y"`, `"1:2:3:4"`, `"n:"`, `"n:name"` → nil from the applicable decoder.

**Verify**: `cd swift && swift test --filter CursorCodecTests` → `Executed 7 tests, with 0 failures`.

### Step 4: `OriginHostParsingTests.swift`

Create the file. Copy the request/context construction from `HTTPTransportIntegrationTests.swift:470-494` (imports: `XCTest`, `Hummingbird`, `HTTPTypes`, `NIOCore`, `NIOEmbedded`, `Logging`, `@testable import iMessageMax`; check the top of that file for the exact import list and copy it). Write a private helper:

```swift
private func status(forAuthority authority: String, origin: String? = nil) async throws -> HTTPResponse.Status
```

that builds a POST `/` request with the given authority and optional `Origin` header, runs `OriginValidationMiddleware<BasicRequestContext>()` with a next-handler returning `Response(status: .ok)`, and returns the response status. Then:

1. `testAllowedHostsWithPortAreAccepted` — `"localhost:8080"`, `"127.0.0.1:8080"`, `"[::1]:8080"` → `.ok`.
2. `testAllowedHostsWithoutPortAreAccepted` — `"localhost"`, `"127.0.0.1"`, `"[::1]"`, `"::1"` → `.ok`. If `"::1"` (bare) is **not** in `allowedHosts` and returns `.forbidden`, record that in the test with a comment and assert the observed status: the point is to pin the branch, not to change policy.
3. `testDisallowedHostsWithPortAreRejected` — `"evil.example:8080"`, `"evil.example"`, `"[2001:db8::1]:8080"`, `"10.0.0.1:8080"` → `.forbidden`.
4. `testNonNumericPortSuffixIsNotStripped` — `"localhost:notaport"` → `.forbidden` (the whole string stays and is not an allowed host).
5. `testMissingOriginIsAllowedByDefault` — authority `"localhost"`, no Origin → `.ok`.
6. `testRequireOriginRejectsMissingOrigin` — construct `OriginValidationMiddleware<BasicRequestContext>(requireOrigin: true)` (check the initializer's parameter name at the top of the middleware file and use it exactly), no Origin header → `.forbidden`, and the body contains `Origin header required`. Read the body with the same approach the existing test file uses to read response bodies, or, if none reads a body, collect it via `response.body` `collect(upTo:)`.

**Verify**: `cd swift && swift test --filter OriginHostParsingTests` → `Executed 6 tests, with 0 failures`.

### Step 5: Send `mismatch` and `sent` statuses end to end

In `SendToolExecuteTests.swift`, after `testStubSendWithMatchingRowConfirms`, add:

1. `testRowInDifferentChatProducesMismatchStatus` — same setup as `testStubSendWithMatchingRowConfirms`, but join the pre-inserted row to chat **2** (the group) instead of chat 1, and send to `"+15550000001"` (which resolves to the DM, chat 1). Assert `json["status"] as? String == "mismatch"`, and `json["message"] as? String` contains `"routing mismatch"`. Whether `actual_chat_id` is exposed in the JSON: check `SendResponse`'s `CodingKeys` in `Send.swift` first; assert on it only if the key exists.
2. `testFileSendWithoutVerificationRowReportsPendingOrSent` — read `Send.swift:51` and the `"sent"` and `"pending_confirmation"` constructors to find the path that yields `"sent"`; if `"sent"` is only reachable for a payload type the stub cannot exercise, write the test for the reachable status and name it accordingly. Do not fabricate a path.

**Verify**: `cd swift && swift test --filter SendToolExecuteTests` → all pass; `grep -c '"mismatch"' swift/Tests/iMessageMaxTests/SendToolExecuteTests.swift` → at least 1.

### Step 6: Verifier matches `attributedBody`-only rows

In `SendVerifierTests.swift`:

1. Replace the comment block at lines 138-142 and the inline comments at 147-148 and 163-166 so they no longer claim a fixture limitation. New wording: "Row stored with text = nil and no attributedBody: extractor returns nil, so the verifier cannot match." Keep the test's assertions unchanged.
2. Add `testAttributedBodyOnlyRowIsConfirmed`: copy the private `typedstreamBlob` helper from `MessageTextExtractorTests.swift:8-15` into this file, build `typedstreamBlob(lengthField: [11], payload: Array("Hello Alice".utf8))`, insert a row with `text: nil, attributedBody: blob` joined to chat 1, and assert `verifier.verify(intendedChatId: 1, handle: nil, sendTime: Date(), expectedText: "Hello Alice")` returns `.confirmed` (match on the enum case, ignoring the associated values, the way sibling tests do).

**Verify**: `cd swift && swift test --filter SendVerifierTests` → all pass, count up by 1. `grep -n "fixture limitation" swift/Tests/iMessageMaxTests/SendVerifierTests.swift` → no matches.

### Step 7: Registry reset discipline

In `ToolRegistryBindingTests.swift`, add inside the class:

```swift
override func setUp() {
    super.setUp()
    ToolHandlerRegistry.shared.resetForTesting()
}

override func tearDown() {
    ToolHandlerRegistry.shared.resetForTesting()
    super.tearDown()
}
```

Match the exact form used in `ModernDispatcherTests.swift:12-17` (read it first and mirror it, including `async` if that file's hooks are async).

**Verify**: `cd swift && swift test --filter "ToolRegistryBindingTests|ToolRegistryTests|ModernDispatcherTests|DualEraStdioTransportTests"` → all pass. Then run the whole suite twice, once serial and once `--parallel`, both 0 failures.

## Test plan

This plan is the test plan. Summary of additions: 8 + 8 + 7 + 6 + 2 + 1 = 32 new test methods across seven files, of which one is skipped and two are expected failures until plans 042 and 043 land.

Verification: `cd swift && swift test 2>&1 | tail -3` → `Executed 310 tests, with 0 failures` (278 + 32; adjust if the count of tests you actually wrote differs, and state the arithmetic in your report).

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` → 0 failures, total = 278 + number of new methods
- [ ] `cd swift && swift test --parallel` → 0 failures
- [ ] `ls swift/Tests/iMessageMaxTests/AppleTimeParseTests.swift swift/Tests/iMessageMaxTests/PhoneUtilsTests.swift swift/Tests/iMessageMaxTests/CursorCodecTests.swift swift/Tests/iMessageMaxTests/OriginHostParsingTests.swift` → all four exist
- [ ] `grep -rn "import Testing" swift/Tests` → no matches
- [ ] `grep -c "XCTExpectFailure" swift/Tests/iMessageMaxTests/PhoneUtilsTests.swift` → `1`
- [ ] `grep -n "fixture limitation" swift/Tests/iMessageMaxTests/SendVerifierTests.swift` → no matches
- [ ] `grep -c "resetForTesting" swift/Tests/iMessageMaxTests/ToolRegistryBindingTests.swift` → `2`
- [ ] `git status` shows no modified files under `swift/Sources/`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any input in Steps 1–4 that this plan says "passes today" fails. That means the code drifted or the plan misread it; report the input and the observed value rather than changing the expectation.
- `XCTExpectFailure(strict: true)` is unavailable on the toolchain (it has been in XCTest since Xcode 12.5; if the compiler rejects it, report the compiler line).
- The middleware initializer has no `requireOrigin`-style parameter (Step 4, case 6). Report and skip that one case with `XCTSkip` and a reason.
- Adding `resetForTesting` hooks to `ToolRegistryBindingTests` makes any other test class fail. That reveals hidden ordering coupling; report which class.
- You find yourself wanting to change a file under `swift/Sources/` to make a test pass.

## Maintenance notes

- Plans 042 and 043 must remove the `XCTSkip` / `XCTExpectFailure` wrappers when they fix the underlying bugs; a strict expected failure that starts passing fails the suite, which is the signal.
- Deferred from the audit, not planned: behavioural coverage for `get_context` and `find_chat` (the two highest-churn read tools, ~1100 lines guarded by five field-name assertions), argument-validation tables per tool (zero/negative/above-cap limits, invalid enum values), and an end-to-end stdio smoke test that pipes `initialize` into the built binary. Plan 042 adds limit-clamp tests for the tools it touches; the rest is a follow-up round.
- Reviewer should check that no expectation in these tests was "fixed" to match a bug the plan explicitly flags as a bug.
