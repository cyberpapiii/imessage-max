# Plan 001: Make Database.swift report errors instead of swallowing them

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 57a2ff3..HEAD -- swift/Sources/iMessageMax/Database/Database.swift swift/Tests/iMessageMaxTests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `57a2ff3`, 2026-06-11

## Why this matters

`Database.query()` is the single read path for every MCP tool in this server (it reads the user's iMessage database, `~/Library/Messages/chat.db`). Today, if SQLite returns an error partway through stepping a result set (lock timeout, corruption, I/O error), the loop simply exits and the partial result array is returned as if it were complete — an AI agent consuming the response has no way to know messages are missing. Two smaller issues live in the same file: the `PRAGMA query_only = ON` safety setting is executed without checking it succeeded (and leaks the error-message allocation on failure), and the parameter binder silently binds `NULL` for any Swift type it doesn't recognize, which would turn a future caller bug into silently-wrong query results instead of a loud failure.

## Current state

- `swift/Sources/iMessageMax/Database/Database.swift` — the only file to modify. It is a `final class Database: @unchecked Sendable` that opens a short-lived read-only SQLite connection per query.
- `swift/Sources/iMessageMax/Database/Errors.swift` — defines `DatabaseError` with cases `notFound(String)`, `permissionDenied(String)`, `queryFailed(String)`, `invalidData(String)`. Reuse these; do not add new error types.

The silent step loop (`Database.swift:54-70`):

```swift
    func query<T>(
        _ sql: String,
        params: [Any] = [],
        map: (SQLiteRow) throws -> T
    ) throws -> [T] {
        let conn = try openReadOnly()
        defer { sqlite3_close(conn) }

        let stmt = try prepare(conn, sql: sql, params: params)
        defer { sqlite3_finalize(stmt) }

        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            try results.append(map(SQLiteRow(stmt)))
        }
        return results
    }
```

The unchecked PRAGMA (`Database.swift:104-109`):

```swift
        // Safety settings
        sqlite3_busy_timeout(db, 1000)
        var errMsg: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, &errMsg)

        return db
```

The silent default bind (`Database.swift:125-144`, inside `prepare`):

```swift
        for (index, param) in params.enumerated() {
            let idx = Int32(index + 1)
            switch param {
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
                sqlite3_bind_null(stmt, idx)
            }
        }
```

Conventions: errors are thrown as `DatabaseError` with the SQLite message via `String(cString: sqlite3_errmsg(conn))` — see the existing `execute()` at `Database.swift:72-83` for the pattern. Match it.

Note: the connection is opened with `SQLITE_OPEN_READONLY`, so the PRAGMA is defense-in-depth, not the primary write guard. Don't "fix" this by removing the read-only open flag.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| All tests | `cd swift && swift test` | exit 0, all pass |
| One test class | `cd swift && swift test --filter DatabaseErrorHandlingTests` | all pass |

## Scope

**In scope** (the only files you should modify/create):
- `swift/Sources/iMessageMax/Database/Database.swift`
- `swift/Tests/iMessageMaxTests/DatabaseErrorHandlingTests.swift` (create)
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- `swift/Sources/iMessageMax/Database/Errors.swift` — existing cases suffice.
- `swift/Sources/iMessageMax/Database/QueryBuilder.swift`, `SQLiteRow.swift` — unrelated.
- Any tool file. If a tool fails to compile after your change, that is a STOP condition, not an invitation to edit tools.

## Git workflow

- Branch: `advisor/001-database-error-handling`
- Commit style: lowercase conventional prefix, matching `git log` (e.g. `fix: propagate server errors instead of leaking continuation`). One commit is fine.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 0: Verify no caller passes an unhandled param type

The strict binder in Step 3 throws on unrecognized types. First confirm no existing call site would start throwing:

```bash
grep -rn "params:" swift/Sources/iMessageMax/ | grep -v "params: \[\]" | head -50
```

Inspect each call site's array elements. Every element must be `Int`, `Int64`, `String`, `Double`, `Data`, or `NSNull`. Watch specifically for `Bool` values and for Optionals passed directly (e.g. `params: [maybeName]` where `maybeName: String?`). If you find any, STOP and report which call sites.

**Verify**: your grep review found only the six supported types → proceed.

### Step 1: Throw when the step loop ends abnormally

In `query<T>`, capture the final `sqlite3_step` result and throw unless it is `SQLITE_DONE`:

```swift
        var results: [T] = []
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            try results.append(map(SQLiteRow(stmt)))
            stepResult = sqlite3_step(stmt)
        }
        guard stepResult == SQLITE_DONE else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(conn)))
        }
        return results
```

**Verify**: `cd swift && swift build` → exit 0.

### Step 2: Check the PRAGMA result and free the error message

In `openReadOnly()`, replace the unchecked `sqlite3_exec` call:

```swift
        sqlite3_busy_timeout(db, 1000)
        var errMsg: UnsafeMutablePointer<CChar>?
        let pragmaResult = sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, &errMsg)
        if pragmaResult != SQLITE_OK {
            let detail = errMsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errMsg)
            sqlite3_close(db)
            throw DatabaseError.queryFailed("Failed to enforce read-only mode: \(detail)")
        }
```

Note the `sqlite3_close(db)` before throwing — the caller's `defer` has not been armed yet because `openReadOnly()` hasn't returned.

**Verify**: `cd swift && swift build` → exit 0.

### Step 3: Make the binder strict

Replace the `default:` case in `prepare()` and add `Bool` support. The statement must be finalized before throwing (the caller's `defer { sqlite3_finalize(stmt) }` is only armed after `prepare` returns):

```swift
            case let value as Bool:
                sqlite3_bind_int64(stmt, idx, value ? 1 : 0)
            case is NSNull:
                sqlite3_bind_null(stmt, idx)
            default:
                sqlite3_finalize(stmt)
                throw DatabaseError.invalidData(
                    "Unsupported SQL parameter type at index \(index): \(type(of: param))"
                )
```

(Keep the existing Int/Int64/String/Double/Data cases unchanged. Place the `Bool` case BEFORE the `Int` case — on some Swift/ObjC bridging paths a `Bool` can match `as Int`, so order matters; with `Bool` first the behavior is deterministic.)

**Verify**: `cd swift && swift build` → exit 0, and `cd swift && swift test` → all existing tests still pass.

### Step 4: Add tests

Create `swift/Tests/iMessageMaxTests/DatabaseErrorHandlingTests.swift`, modeled structurally on the existing test support (`swift/Tests/iMessageMaxTests/ToolTestSupport.swift` provides `ToolTestDatabase`, a temp-file SQLite fixture with the chat.db schema; get a `Database` with `fixture.database()`):

- `testQueryReturnsRowsOnHappyPath` — insert a handle via `fixture.insertHandle(rowId: 1, handle: "+15550000001")`, query `SELECT id FROM handle`, assert 1 row.
- `testUnsupportedParamTypeThrows` — call `db.query("SELECT 1 WHERE 1 = ?", params: [["array", "is", "unsupported"]]) { _ in 0 }` and assert it throws `DatabaseError.invalidData` (use `XCTAssertThrowsError` and pattern-match the error).
- `testBoolParamBindsAsInteger` — `db.query("SELECT 1 WHERE ? = 1", params: [true]) { _ in 0 }` returns 1 row; `params: [false]` returns 0 rows.
- `testQueryAgainstMissingDatabaseThrowsNotFound` — `Database(path: "/nonexistent/nope.sqlite")`, assert `query` throws `DatabaseError.notFound`.

(A mid-step SQLITE_ERROR is impractical to trigger deterministically in a unit test; Step 1 is covered by code review plus the happy-path regression. Do not contrive a corruption test.)

**Verify**: `cd swift && swift test --filter DatabaseErrorHandlingTests` → 4 tests pass.

## Test plan

Covered in Step 4. Full-suite regression: `cd swift && swift test` → all pass (the strict binder must not break any existing tool test — if one fails, Step 0 missed a call site: STOP and report it).

## Done criteria

- [ ] `cd swift && swift build` exits 0
- [ ] `cd swift && swift test` exits 0; the 4 new tests exist and pass
- [ ] `grep -n "default:" swift/Sources/iMessageMax/Database/Database.swift` shows the default case throws (no silent `sqlite3_bind_null` default)
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The code at the cited lines doesn't match the "Current state" excerpts.
- Step 0 finds a call site passing Optionals, `Bool` wrapped in odd containers, or any unsupported type.
- An existing test fails after Step 3 (means a call site relies on the silent-NULL behavior).
- The fix appears to require touching `Errors.swift` or any tool file.

## Maintenance notes

- Any future param type (e.g. `Date`) must be added as an explicit case — the binder now throws on unknowns by design.
- Reviewer should scrutinize: the `Bool`-before-`Int` case ordering, and that both early-throw paths (`prepare` default case, PRAGMA failure) clean up their SQLite resources before throwing.
- Deferred: reusing one connection per tool call instead of per query (see plan 003's maintenance notes).
