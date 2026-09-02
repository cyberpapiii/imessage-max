# Plan 063: Input hygiene — signed row ids, hand-built JSON, raw sqlite error text, and unchecked bind codes

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 639529e..HEAD -- swift/Sources/iMessageMax/Utilities/ChatIdentifier.swift swift/Sources/iMessageMax/Tools/GetUnread.swift swift/Sources/iMessageMax/Utilities/ToolErrorMapping.swift swift/Sources/iMessageMax/Database/Database.swift swift/Tests/iMessageMaxTests/ChatIdentifierTests.swift swift/Tests/iMessageMaxTests/GetUnreadToolTests.swift swift/Tests/iMessageMaxTests/ToolErrorMappingTests.swift swift/Tests/iMessageMaxTests/DatabaseErrorHandlingTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: 049 (landed; `ClientErrorMessages` and `ToolErrorMapping` exist)
- **Category**: bug / security
- **Planned at**: commit `639529e`, 2026-09-01

## Why this matters

Four small holes at the input and error edges of the tool layer. Each is a
one-commit fix with a test, and each is the kind of thing a reviewer expects
the codebase to already do given plan 049's stated promise that client-visible
error text never carries internal detail.

1. `ChatIdentifier.parseRowId` accepts `"-5"` and `"+5"` because `Int64(String)`
   accepts a sign. A negative row id never matches a chat, so the failure is
   "not found" rather than data exposure, but `send` routes through the same
   parser (`SendResolution.swift:44`) and a `+5` alias for `5` is not a
   contract anyone asked for. The doc comment says "Accepts `123` and
   `chat123`"; the code accepts more.
2. `get_unread` hand-builds its `chat_not_found` error JSON by string
   interpolation and puts the client's raw `chat_id` inside it. A `chat_id`
   containing a double quote or backslash produces invalid JSON on the wire.
   The same file already has the correct pattern six lines earlier
   (`UnreadError` through `FormatUtils.encodeJSON`).
3. `ToolErrorMapping.map` passes the raw `sqlite3_errmsg` text for
   `.queryFailed` and `.invalidData` straight to the client. That text names
   tables and columns of the operator's `chat.db` and, for `.invalidData`,
   whatever the thrower interpolated. `ClientErrorMessages.sanitized` already
   maps both cases to `internalError` and logs the detail; the mapping enum
   is the one path that forgot. Nine tools call it.
4. `Database.prepare` ignores the return code of every `sqlite3_bind_*`
   call. A bind that fails (index out of range when a caller passes more
   params than placeholders, or `SQLITE_TOOBIG` for a large blob) runs the
   statement with a NULL in that slot, silently returning wrong rows. Today
   `db.query("SELECT 1", params: [1])` returns one row instead of throwing.

## Current state

### (a) Sign prefix

`swift/Sources/iMessageMax/Utilities/ChatIdentifier.swift:3-10`:

```swift
enum ChatIdentifier {
    /// Accepts "123" and "chat123". Returns nil for anything else.
    static func parseRowId(_ raw: String) -> Int64? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let id = Int64(trimmed) { return id }
        if trimmed.hasPrefix("chat"), let id = Int64(trimmed.dropFirst(4)) { return id }
        return nil
    }
```

`Int64("-5")` is `-5` and `Int64("+5")` is `5`, so both branches accept a
sign. Callers: `SearchInternals.swift:108`, `GetChatDetails.swift:75`,
`GetContext.swift:200`, `GetUnread.swift:177`, `GetMessagesInternals.swift:132`
(via `resolve`), `ListAttachments.swift:163`, `SendResolution.swift:44`.

`swift/Tests/iMessageMaxTests/ChatIdentifierTests.swift` has four tests
(`testNumericRowId`, `testChatPrefix`, `testWhitespace`,
`testGarbageReturnsNil`). `testGarbageReturnsNil` covers `""`, `"   "`,
`"abc"`, `"chat"`, `"chatABC"`, `"iMessage;-;chat123"`. No sign case.

### (b) Hand-built JSON

`swift/Sources/iMessageMax/Tools/GetUnread.swift:175-181`:

```swift
var numericChatId: Int64?
if let chatId = params.chatId {
    numericChatId = ChatIdentifier.parseRowId(chatId)
    if numericChatId == nil {
        throw ToolError(content: [.plainText("{\"error\":\"chat_not_found\",\"message\":\"Chat not found: \(chatId)\"}")])
    }
}
```

The sanctioned pattern is in the same file, `GetUnread.swift:136-140`:

```swift
} catch let error as DatabaseError {
    let mapped = ToolErrorMapping.map(error, context: "get_unread")
    let payload = UnreadError(error: mapped.code, message: mapped.message)
    throw ToolError(content: [.plainText(try FormatUtils.encodeJSON(payload))])
}
```

`UnreadError` is declared at `GetUnread.swift:49-52` as
`struct UnreadError: Codable { let error: String; let message: String }`.

### (c) Raw sqlite text to the client

`swift/Sources/iMessageMax/Utilities/ToolErrorMapping.swift:10-21`:

```swift
static func map(_ error: DatabaseError, context _: String) -> Mapped {
    switch error {
    case .notFound:
        return Mapped(code: "database_not_found", message: ClientErrorMessages.databaseNotFound)
    case .permissionDenied:
        return Mapped(code: "permission_denied", message: ClientErrorMessages.permissionDenied)
    case .queryFailed(let msg):
        return Mapped(code: "query_failed", message: msg)
    case .invalidData(let msg):
        return Mapped(code: "invalid_data", message: msg)
    }
}
```

Compare `swift/Sources/iMessageMax/Utilities/ClientErrorMessages.swift:12-22`,
which logs the detail and returns `internalError` for the same two cases.
The `context` parameter of `map` is currently unused (`context _:`); it is
the natural log prefix.

`swift/Tests/iMessageMaxTests/ToolErrorMappingTests.swift:18-28` pins the
current behavior: `testQueryFailed` asserts `mapped.message == "boom"` and
`testInvalidData` asserts `"bad blob"`. Both assertions must flip.

Callers of `ToolErrorMapping.map` (nine, none need to change):
`FindChat.swift:209`, `GetAttachment.swift:255`,
`GetActiveConversations.swift:123`, `GetContext.swift:438`,
`GetUnread.swift:137`, `GetChatDetails.swift:136`,
`ListAttachments.swift:194`, `ListChats.swift:510`, `Search.swift:431`.

### (d) Unchecked bind codes

`swift/Sources/iMessageMax/Database/Database.swift:133-157`:

```swift
for (index, param) in params.enumerated() {
    let idx = Int32(index + 1)
    switch param {
    case let value as Bool:
        sqlite3_bind_int64(stmt, idx, value ? 1 : 0)
    case let value as Int:
        sqlite3_bind_int64(stmt, idx, Int64(value))
    case let value as Int64:
        sqlite3_bind_int64(stmt, idx, value)
    case let value as String:
        sqlite3_bind_text(stmt, idx, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    case let value as Double:
        sqlite3_bind_double(stmt, idx, value)
    case let value as Data:
        _ = value.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, idx, ptr.baseAddress, Int32(value.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    case is NSNull:
        sqlite3_bind_null(stmt, idx)
    default:
        sqlite3_finalize(stmt)
        throw DatabaseError.invalidData(
            "Unsupported SQL parameter type at index \(index): \(type(of: param))"
        )
    }
}
```

Every `sqlite3_bind_*` returns an `Int32` that is discarded (Swift does not
warn because the C functions are not `@discardableResult`-annotated in the
way Swift functions are; the result is silently dropped). The `default`
branch shows the established cleanup shape: finalize, then throw.

`swift/Tests/iMessageMaxTests/DatabaseErrorHandlingTests.swift` already
imports `SQLite3`, builds a `ToolTestDatabase`, and has the pattern
`XCTAssertThrowsError(try db.query(..., params: [...]) { _ in 0 }) { error in guard case DatabaseError.invalidData = error else { XCTFail(...) } }`
(`testUnsupportedParamTypeThrows`, `:23-35`).

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `cd swift && swift build` | `Build complete!` |
| Focused (a) | `cd swift && swift test --filter ChatIdentifierTests` | 0 failures |
| Focused (b) | `cd swift && swift test --filter GetUnreadToolTests` | 0 failures |
| Focused (c) | `cd swift && swift test --filter "ToolErrorMappingTests\|ClientErrorMessagesTests"` | 0 failures |
| Focused (d) | `cd swift && swift test --filter DatabaseErrorHandlingTests` | 0 failures |
| Whole suite | `cd swift && swift test` | 0 failures (baseline 370 tests at `639529e`) |
| Launchd rule | `cd swift && swift test --filter LaunchdSafetyTests` | 0 failures |

## Scope

### In scope

- `swift/Sources/iMessageMax/Utilities/ChatIdentifier.swift`
- `swift/Sources/iMessageMax/Tools/GetUnread.swift` (lines 175-181 only)
- `swift/Sources/iMessageMax/Utilities/ToolErrorMapping.swift`
- `swift/Sources/iMessageMax/Database/Database.swift` (`prepare` only)
- `swift/Tests/iMessageMaxTests/ChatIdentifierTests.swift`
- `swift/Tests/iMessageMaxTests/GetUnreadToolTests.swift`
- `swift/Tests/iMessageMaxTests/ToolErrorMappingTests.swift`
- `swift/Tests/iMessageMaxTests/DatabaseErrorHandlingTests.swift`

### Out of scope

- The GUID-substring fallback in `ChatIdentifier.resolve` (plan 049 already
  escaped it; its permissiveness is a product decision, not hygiene).
- Other hand-built JSON strings elsewhere in `swift/Sources`. Run
  `grep -rn '\\"error\\":' swift/Sources/iMessageMax/Tools` after Step 2 and
  list any additional hits in the report; do not fix them here.
- Changing the nine `ToolErrorMapping.map` call sites. The signature is
  unchanged.
- `sqlite3_step` and `sqlite3_column_*` handling in `Database.query`; the
  step loop already throws on non-`SQLITE_DONE`.
- Any Contacts, HTTP, or session code.

## Git workflow

- Branch: `advisor/063-input-hygiene` from current `main`.
- One commit per lettered item, test-first where the item is a bug fix
  (every item here is): a failing-test commit, then the fix commit. Eight
  commits is fine; squashing test and fix into one commit per item is also
  acceptable if the test is visibly present in the diff.
- Commit messages (conventional):
  - `test: reject signed row ids in ChatIdentifier`
  - `fix: reject sign prefixes in ChatIdentifier.parseRowId`
  - `test: get_unread chat_not_found must be valid JSON`
  - `fix: encode get_unread chat_not_found through UnreadError`
  - `test: ToolErrorMapping hides sqlite detail from clients`
  - `fix: map queryFailed and invalidData to the fixed internal-error text`
  - `test: Database.prepare surfaces failed binds`
  - `fix: check sqlite3_bind_* return codes in Database.prepare`
- The executor does not merge or push. Report the branch name.

Standing rules:

- Never `Task.sleep` in `swift/Sources`; `LaunchdSafetyTests` enforces it.
  Nothing in this plan needs a timer.
- Never touch `.mcp.json`.
- Never commit secrets. Test fixtures use synthetic `+1555...` handles.

## Steps

### Step 1: Sign prefix (a)

Test first. In `ChatIdentifierTests.swift` add:

```swift
func testSignPrefixReturnsNil() {
    for raw in ["-5", "+5", "chat-5", "chat+5", " -5 "] {
        XCTAssertNil(ChatIdentifier.parseRowId(raw), "parseRowId(\(raw)) must be nil")
    }
}
```

Run `swift test --filter ChatIdentifierTests` and confirm the new test
fails on `"-5"` and `"+5"` (and `"chat-5"`, `"chat+5"`). Commit.

Fix in `ChatIdentifier.swift`: parse only unsigned decimal digits. One
shape that keeps the function readable:

```swift
static func parseRowId(_ raw: String) -> Int64? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    let digits = trimmed.hasPrefix("chat") ? trimmed.dropFirst(4) : Substring(trimmed)
    guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
    return Int64(digits)
}
```

(`isNumber` alone admits non-ASCII digits such as `٣`; `Int64.init` would
reject them anyway, but the double guard makes intent explicit. Keep
`Int64(digits)` returning nil on overflow.) Update the doc comment to
"Accepts unsigned decimal `123` and `chat123`."

**Verify**: `swift test --filter ChatIdentifierTests` → 0 failures, 5 tests.
`swift test --filter "GetUnreadToolTests|GetMessagesToolTests|SendResolutionTests|ListAttachmentsToolTests"` → 0 failures (the callers). Commit.

### Step 2: Hand-built JSON (b)

Test first. In `GetUnreadToolTests.swift` add a test that passes a
`chat_id` containing a quote and a backslash and asserts the thrown
`ToolError` content is parseable JSON with `error == "chat_not_found"`:

```swift
func testChatNotFoundErrorIsValidJSON() async throws {
    let fixture = try ToolTestDatabase(name: "unread-badid")
    let tool = GetUnread(database: fixture.database(), contactResolver: makeSeededResolver())
    let hostile = "abc\"\\def"
    do {
        _ = try await tool.execute(
            params: GetUnread.Parameters(chatId: hostile, since: "all", format: .summary, limit: 5)
        )
        XCTFail("expected ToolError")
    } catch let error as ToolError {
        guard case .plainText(let text)? = error.content.first else {
            return XCTFail("expected plainText content")
        }
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["error"] as? String, "chat_not_found")
        XCTAssertEqual(object["message"] as? String, "Chat not found: \(hostile)")
    }
}
```

Check the exact `Parameters` memberwise initializer label order in
`GetUnread.swift` before writing the call (`Parameters(chatId:since:format:limit:)`
at `639529e`). Run the focused filter and confirm the test fails with a
`JSONSerialization` error. Commit.

Fix `GetUnread.swift:178-180`:

```swift
if numericChatId == nil {
    let payload = UnreadError(error: "chat_not_found", message: "Chat not found: \(chatId)")
    throw ToolError(content: [.plainText(try FormatUtils.encodeJSON(payload))])
}
```

**Verify**: `swift test --filter GetUnreadToolTests` → 0 failures.
`grep -n 'plainText("{' swift/Sources/iMessageMax/Tools/GetUnread.swift` → no matches. Commit.

### Step 3: Raw sqlite text (c)

Test first. Edit `ToolErrorMappingTests.swift:18-28`:

```swift
func testQueryFailed() {
    let mapped = ToolErrorMapping.map(.queryFailed("no such table: message"), context: "test")
    XCTAssertEqual(mapped.code, "query_failed")
    XCTAssertEqual(mapped.message, ClientErrorMessages.internalError)
    XCTAssertFalse(mapped.message.contains("message"), "sqlite detail must not reach the client")
}

func testInvalidData() {
    let mapped = ToolErrorMapping.map(.invalidData("bad blob at /Users/me/x"), context: "test")
    XCTAssertEqual(mapped.code, "invalid_data")
    XCTAssertEqual(mapped.message, ClientErrorMessages.internalError)
}
```

Note the `contains("message")` assertion is against the word in the
sqlite text, and `internalError` is "Internal error. Check the server log
for details." which does not contain it. Run the filter; both tests must
fail. Commit.

Fix `ToolErrorMapping.swift:16-19`. Keep the codes (clients branch on
them), log the detail with the context, return the fixed string:

```swift
case .queryFailed(let msg):
    Log.error("\(context): query failed: \(msg)")
    return Mapped(code: "query_failed", message: ClientErrorMessages.internalError)
case .invalidData(let msg):
    Log.error("\(context): invalid data: \(msg)")
    return Mapped(code: "invalid_data", message: ClientErrorMessages.internalError)
```

This requires renaming the parameter from `context _: String` to
`context: String`. All nine callers already pass a label, so no call site
changes. Update the doc comment on `map` to say the two failure cases log
detail and return `ClientErrorMessages.internalError`.

**Verify**: `swift build` → `Build complete!` with no unused-parameter
warning. `swift test --filter ToolErrorMappingTests` → 0 failures.
`grep -n "message: msg" swift/Sources/iMessageMax/Utilities/ToolErrorMapping.swift` → no matches. Commit.

### Step 4: Bind return codes (d)

Test first. In `DatabaseErrorHandlingTests.swift` add:

```swift
func testExtraParameterFailsBindInsteadOfRunning() throws {
    let fixture = try ToolTestDatabase()
    let db = fixture.database()
    // One placeholder-less statement, one param: sqlite3_bind_int64 returns
    // SQLITE_RANGE. At 639529e the code ignores it and returns one row.
    XCTAssertThrowsError(
        try db.query("SELECT 1", params: [1]) { _ in 0 }
    ) { error in
        guard case DatabaseError.queryFailed = error else {
            return XCTFail("expected queryFailed, got \(error)")
        }
    }
}
```

Run `swift test --filter DatabaseErrorHandlingTests`; the new test fails
because the query succeeds. Commit.

Fix `Database.swift:133-157`. Capture every bind's return code and check it
after the switch, finalizing on failure the way the `default` branch does:

```swift
for (index, param) in params.enumerated() {
    let idx = Int32(index + 1)
    let rc: Int32
    switch param {
    case let value as Bool:
        rc = sqlite3_bind_int64(stmt, idx, value ? 1 : 0)
    case let value as Int:
        rc = sqlite3_bind_int64(stmt, idx, Int64(value))
    case let value as Int64:
        rc = sqlite3_bind_int64(stmt, idx, value)
    case let value as String:
        rc = sqlite3_bind_text(stmt, idx, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    case let value as Double:
        rc = sqlite3_bind_double(stmt, idx, value)
    case let value as Data:
        rc = value.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, idx, ptr.baseAddress, Int32(value.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    case is NSNull:
        rc = sqlite3_bind_null(stmt, idx)
    default:
        sqlite3_finalize(stmt)
        throw DatabaseError.invalidData(
            "Unsupported SQL parameter type at index \(index): \(type(of: param))"
        )
    }
    guard rc == SQLITE_OK else {
        let message = String(cString: sqlite3_errmsg(conn))
        sqlite3_finalize(stmt)
        throw DatabaseError.queryFailed("bind failed at index \(index): \(message)")
    }
}
```

Read `sqlite3_errmsg` before `sqlite3_finalize`; finalize can reset it.
The error text goes through Step 3's mapping, so the client sees the
fixed string and the operator sees the bind index in the log.

**Verify**: `swift test --filter DatabaseErrorHandlingTests` → 0 failures.
`swift test` → 0 failures (every tool test exercises `prepare`). Commit.

### Step 5: Full suite

**Verify**: `cd swift && swift test` → 0 failures, test count ≥ 374
(baseline 370 + four new tests). `swift test --filter LaunchdSafetyTests` → 0 failures.

## Test plan

- `ChatIdentifierTests` +1 (`testSignPrefixReturnsNil`).
- `GetUnreadToolTests` +1 (`testChatNotFoundErrorIsValidJSON`).
- `ToolErrorMappingTests` 2 assertions flipped, 0 new tests.
- `DatabaseErrorHandlingTests` +1 (`testExtraParameterFailsBindInsteadOfRunning`).
- Whole suite green; no test outside these four files changes.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` → 0 failures
- [ ] `grep -c "Int64(trimmed)" swift/Sources/iMessageMax/Utilities/ChatIdentifier.swift` → `0`
- [ ] `grep -n 'plainText("{' swift/Sources/iMessageMax/Tools/GetUnread.swift` → no matches
- [ ] `grep -c "ClientErrorMessages.internalError" swift/Sources/iMessageMax/Utilities/ToolErrorMapping.swift` → `2`
- [ ] `grep -n "context _:" swift/Sources/iMessageMax/Utilities/ToolErrorMapping.swift` → no matches
- [ ] `grep -c "rc = sqlite3_bind_" swift/Sources/iMessageMax/Database/Database.swift` → `7`
- [ ] `grep -n "guard rc == SQLITE_OK" swift/Sources/iMessageMax/Database/Database.swift` → one match
- [ ] `git diff --stat main..HEAD` lists only the eight in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any existing test outside the four test files fails after Step 1. That
  means a caller relies on signed input; report the test name and the input.
- After Step 3, a test asserts on raw sqlite text in a tool response
  (`grep -rn "no such\|syntax error\|SQL logic" swift/Tests`). Report it;
  do not weaken the mapping.
- After Step 4, any test in the whole suite throws `bind failed`. That is a
  real caller passing more params than placeholders, which this plan just
  surfaced. Report the query text and stop; the caller fix is a separate
  commit the reviewer should see.
- `Log.error` is not reachable from `ToolErrorMapping.swift` (it is used in
  `ClientErrorMessages.swift` in the same module, so this should not happen).

## Maintenance notes

- `ToolErrorMapping.map` and `ClientErrorMessages.sanitized` must agree on
  what `.queryFailed` and `.invalidData` say to a client. A reviewer can
  check with `grep -n "internalError" swift/Sources/iMessageMax/Utilities/ToolErrorMapping.swift swift/Sources/iMessageMax/Utilities/ClientErrorMessages.swift` → three matches (one definition, two uses in each file).
- Every `sqlite3_bind_*` in `Database.swift` assigns to `rc`. New parameter
  types added to the switch must follow the same shape.
- Error JSON goes through a `Codable` payload and `FormatUtils.encodeJSON`.
  `grep -rn 'plainText("{' swift/Sources` should stay empty.
