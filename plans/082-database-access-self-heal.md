# Plan 082: Recover from missing Full Disk Access without a restart, and make `make install` prove it

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 42deb1f..HEAD -- swift/Sources/iMessageMax/Database/Database.swift swift/Sources/iMessageMax/Tools/Diagnose.swift swift/Sources/iMessageMax/iMessageMaxCommand.swift swift/Sources/iMessageMax/Utilities/ClientErrorMessages.swift swift/Makefile swift/Tests/iMessageMaxTests/DatabaseErrorHandlingTests.swift swift/Tests/iMessageMaxTests/DiagnoseToolTests.swift README.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition. Plan 081 also edits
> `Diagnose.swift` and `DiagnoseToolTests.swift`; if it has landed, its
> diff there is expected drift: re-read those two files and continue.

## Status

- **Priority**: P1
- **Effort**: S-M
- **Risk**: LOW (no query or response shape changes; the code work is a
  longer `fix` string, one extra log line, tests that pin behavior the
  code already has, and a Makefile target)
- **Depends on**: none
- **Category**: reliability
- **Planned at**: commit `42deb1f`, 2026-09-02. Baseline: `cd swift && swift build && swift test` passes with 433 tests, 0 failures.

## Why this matters

### The incident

On 2026-09-01 the launchd service `local.imessage-max` ran for about 14
hours with `database.status=permission_denied` after a reinstall. Every
read tool on the plug lane failed with
`Cannot read the iMessage database (Full Disk Access may be missing). Run the diagnose tool.`
and `send` could not verify delivery. Only a manual re-grant of Full Disk
Access plus `launchctl kickstart` fixed it.

Timeline, reconstructed from the repository (the stderr log at
`~/Library/Logs/imessage-max.stderr.log` has no timestamps, see
`Utilities/Log.swift`, so wall-clock times come from git and the
operator):

| When | Evidence | What happened |
|---|---|---|
| 2026-09-01 evening | `make install` after the 063-078 wave (`plans/README.md:4`, `:67`) | Release binary rebuilt and the service restarted. The TCC grant did not follow the new binary. |
| Startup | `~/Library/Logs/imessage-max.stderr.log` line 522: `INFO Database: permission_denied` | `iMessageMaxCommand.swift:37-40` logged the state once and kept serving. Nothing in the log says what to do. |
| Overnight | stderr lines 473, 1315: `ERROR database error: Permission denied accessing /Users/robdezendorf/Library/Messages/chat.db. Grant Full Disk Access in System Settings.` | Each tool call re-opened the file, failed, and returned the sanitized `permission_denied` error. |
| 2026-09-02 ~11:00 | `docs/plans/2026-09-01-send-delivery-semantics.md:186-198` "Plug lane permission_denied", committed `2034eaa` 11:21 -0400 | Detected during the 078 probe. `IMessage__diagnose` on the plug lane: `process_id` 87132, `version` 1.5.0, `database.accessible=false`, `perm_full_disk` and `verified_send` `permission-gated`, contacts authorized (1666 handles). `launchctl print` and `lsof` on 8080 both show `/Users/robdezendorf/Documents/GitHub/imessage-max/swift/.build/release/imessage-max --http --port 8080`. |
| 2026-09-02 | operator | Re-granted Full Disk Access to the release binary, then `launchctl kickstart -k gui/$(id -u)/local.imessage-max`. Reads recovered. |

`plans/README.md:53` (row 078) records the spike that found it; the
spike's own verdict was "Do not treat this as a send-semantics bug."

### What the code already does, and what it does not

`Database` opens a fresh connection on every query and never caches a
failed open, so item (a) of the request, "every tool call re-attempts the
open after a permission failure", is already true. `diagnose` calls
`Database.checkAccess()` on every invocation, so item (b), "re-probes
live", is already true. Neither fact is pinned by a test, and neither
helped, because macOS only consults the Full Disk Access list when a
process is launched: the running PID 87132 could re-open the file ten
thousand times and be denied every time until it was restarted with the
grant in place. The 14 hours were lost to three gaps this plan closes:

1. Nobody looked. `make install` finishes with "Done. Finder opened to the
   binary; drag it into Full Disk Access if needed." (`Makefile:152`) and
   `make verify` only checks that `initialize` answers with the right
   version (`Makefile:95-147`). A service that answers `initialize` but
   cannot read `chat.db` passes.
2. The `fix` text says where the setting is but not which process to add,
   that a stale entry must be toggled, or that the service must be
   relaunched afterwards (`Diagnose.swift:121-122`).
3. The startup log line `Database: permission_denied` gives no remediation
   and no timestamp.

The reference implementation, openclaw/imsg (not visible to you; excerpts
below), handles the same platform limitation the same way: never cache a
failed open, re-validate on every call, and put the remediation in the
error string.

## Current state

### Per-call open, no caching (`Database.swift:56-66`, `:85-106`)

```swift
    func query<T>(
        _ sql: String,
        params: [Any] = [],
        map: (SQLiteRow) throws -> T
    ) throws -> [T] {
        if Database.queryCountForTesting != nil {
            Database.queryCountForTesting! += 1
        }

        let conn = try openReadOnly()
        defer { sqlite3_close(conn) }
```

```swift
    private func openReadOnly() throws -> OpaquePointer {
        guard FileManager.default.fileExists(atPath: path) else {
            throw DatabaseError.notFound(path)
        }

        var db: OpaquePointer?
        let result = sqlite3_open_v2(
            "file:\(path)?mode=ro",
            &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
            nil
        )

        guard result == SQLITE_OK, let db = db else {
            if let db = db {
                sqlite3_close(db)
            }
            throw DatabaseError.permissionDenied(path)
        }
```

The class stores only `path` (`:13`). There is no state a failed open
could poison. `DatabaseErrorHandlingTests.testFailedOpensDoNotAccumulateSQLiteMemory`
(`:80-140`) already builds an unreadable temp file:

```swift
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("chat.db").path
        FileManager.default.createFile(atPath: path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)

        let db = Database(path: path)
```

and expects `DatabaseError.permissionDenied` from every query. Note the
file is empty: SQLite opens an empty file as a valid empty database once
it is readable, so `SELECT 1` succeeds after `chmod 644`. That is the
recovery half of the new test.

### Live probe in diagnose (`Diagnose.swift:107-127`)

```swift
    static func execute(
        resolver: ContactResolver,
        dbProbe: DatabaseProbe = { Database.checkAccess() },
        contactsProbe: ContactsProbe = { ContactResolver.authorizationStatus() },
        automationProbe: AutomationProbe = { AutomationPermission.checkAutomationPermission() }
    ) async throws -> DiagnoseResult {
        let processId = ProcessInfo.processInfo.processIdentifier
        let databasePath = Database.defaultPath

        let (dbOk, dbStatus) = dbProbe()

        var databaseFix: String? = nil
        if !dbOk {
            if dbStatus == "permission_denied" {
                databaseFix = "Grant Full Disk Access: System Settings -> Privacy & Security -> " +
                    "Full Disk Access -> Add your terminal app or the imessage-max executable"
            } else if dbStatus == "database_not_found" {
                databaseFix = "iMessage database not found. Ensure iMessage is set up and " +
                    "has sent/received at least one message."
            }
        }
```

`Database.checkAccess(path:)` (`Database.swift:21-49`) checks
`fileExists`, then `isReadableFile`, then `sqlite3_open_v2` read-only, and
returns `(false, "permission_denied")` for the last two. It is a static
function with no cache. The same `databaseFix` string is reused for
`capabilities.perm_full_disk.fix` (`:235-237`).
`DiagnoseToolTests.swift:9-22` defines injectable probes
(`dbAccessible`, `dbDenied`, `contactsAuthorized`, `automationGranted`)
and an `encodedResponse(dbProbe:)` helper;
`testResponseDoesNotContainHomeDirectory` (`:24-40`) asserts the JSON
never contains `NSHomeDirectory()`. Any path in the new `fix` string must
be tilde-abbreviated for the same reason.

### Startup log (`iMessageMaxCommand.swift:34-40`)

```swift
            let database = Database()
            let resolver = ContactResolver()

            let (dbOk, dbStatus) = Database.checkAccess()
            if !dbOk {
                Log.info("Database: \(dbStatus)")
            }
```

### Client-facing error (`ClientErrorMessages.swift`)

`permissionDenied = "Cannot read the iMessage database (Full Disk Access may be missing). Run the diagnose tool."`
This is what every read tool returns via `ToolErrorMapping.map`. It
correctly points at `diagnose`, so `diagnose`'s `fix` is the one string
that has to carry the full remediation. Leave `ClientErrorMessages` alone.

### `make verify` and `make install` (`swift/Makefile:95-153`)

`verify` loops up to `VERIFY_ATTEMPTS` (45) times, one second apart,
POSTing a legacy `initialize` to `http://127.0.0.1:$(PORT)`, parses
`result.serverInfo.version` with python3 and compares it to
`$(BINARY) --version`, then POSTs a modern `server/discover`, and exits 0
on the first full success. `install: sign restart verify` (`:149`) then
runs `open -R $(BINARY)` and prints the "drag it into Full Disk Access if
needed" line. `.PHONY` is at `:43`. `status` (`:155-178`) does one
`initialize` and prints the version. Nothing anywhere calls `tools/call`.

The legacy lane's `initialize` response carries an `Mcp-Session-Id`
header; `tools/call` with that header works without
`notifications/initialized` (`HTTPTransportIntegrationTests.swift:114-130`
does exactly this for `diagnose`). The response body has
`result.structuredContent` with the full `DiagnoseResult`
(`HTTPTransportIntegrationTests` asserts `structuredContent` is present),
so the Makefile can read `database.accessible` without parsing the
`content[0].text` string.

### launchd (`swift/launchd/local.imessage-max.plist`)

`KeepAlive` with `Crashed=true` and `SuccessfulExit=false`,
`ThrottleInterval` 30. A process that exits non-zero is relaunched after
30 seconds; a process that exits 0 stays down. Logs go to
`~/Library/Logs/imessage-max.stdout.log` and `.stderr.log`.

### Reference behavior (imsg, excerpts inlined)

`docs/permissions.md`:

> Full Disk Access is granted to the process that opens the database, not
> to the shell that launched it. ... macOS only re-reads Full Disk Access
> on launch; after changing the setting, relaunch the process.
>
> **Stale grants after updates.** If the entry is present but reads still
> fail, the grant is bound to a previous signature. Toggle the entry off
> and back on, or remove it and add the binary again.

`docs/troubleshooting.md`, "Reads return `unable to open database file`":

> 1. Confirm which process is opening the database (`imsg rpc status`
>    prints the executable path).
> 2. Add that exact executable under Full Disk Access.
> 3. If it is already listed, toggle it off and on.
> 4. Relaunch the process.
> 5. Bisect: `sqlite3 ~/Library/Messages/chat.db 'pragma quick_check;'`
>    from the same shell. If that also fails, the shell lacks the grant; if
>    it succeeds, the grant is missing from the process, not the user.

`Sources/imsg/RPCDatabaseResources.swift` (the parts that matter here):

```swift
actor RPCDatabaseResourceOwner {
  private var current: (identity: FileIdentity, store: MessageStore)?
  private let openAttemptLimit = 2

  /// Never caches a failed open; the next call tries again from scratch.
  func require() async throws -> MessageStore {
    let identity = try FileIdentity(path: path)   // (st_dev, st_ino)
    if let current, current.identity == identity { return current.store }
    var lastError: Error?
    for _ in 0..<openAttemptLimit {
      do {
        let store = try MessageStore(path: path)
        current = (identity, store)
        return store
      } catch { lastError = error }
    }
    current = nil
    throw RPCDatabaseError.unavailable(actionable(lastError))
  }

  func snapshot() async -> RPCDatabaseSnapshot {
    do {
      let store = try await require()
      return RPCDatabaseSnapshot(path: path, ready: true, features: store.capabilities.dictionary)
    } catch {
      return RPCDatabaseSnapshot(path: path, ready: false, error: "\(error)")
    }
  }
}

private func actionable(_ error: Error?) -> String {
  "unable to open \(path). Grant Full Disk Access to \(executablePath) "
    + "(System Settings > Privacy & Security > Full Disk Access), toggle it off and on "
    + "if already listed, then relaunch."
}
```

imsg keeps one open store and re-validates it by `(st_dev, st_ino)`
because `chat.db` can be replaced under it. iMessage Max opens per call,
which makes the identity check unnecessary: a replaced file is picked up
by the next open. The parts worth borrowing are "never cache a failed
open" (already true, pin it), `snapshot()` (already true, pin it), and the
`actionable` string (missing, add it).

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `cd swift && swift build` | ends in `Build complete!` |
| Focused | `cd swift && swift test --filter "DatabaseErrorHandlingTests\|DiagnoseToolTests\|CapabilityContractTests\|ResponseContractTests"` | 0 failures |
| Whole suite | `cd swift && swift test` | 433 plus new tests, 0 failures |
| Launchd guard | `cd swift && swift test --filter LaunchdSafetyTests` | passes (no `Task.sleep` under `swift/Sources`) |
| Service state | `cd swift && make status` | process line, version, signature, health |
| Does this shell have FDA | `sqlite3 -readonly ~/Library/Messages/chat.db 'pragma quick_check;'` | `ok`, or `unable to open database file` |
| Live diagnose over HTTP | see Step 4's target; `cd swift && make verify-db` | `✓ Database accessible` or a failure with remediation |
| Relaunch service | `launchctl kickstart -k gui/$(id -u)/local.imessage-max` | silent |

## Scope

In scope:

- Tests that pin the two behaviors the incident depends on:
  `Database` retries the open on the next query after a permission
  failure, and `diagnose` re-probes on every call.
- A longer `permission_denied` `fix` string in `Diagnose.swift` naming the
  process to grant, the stale-entry toggle, the relaunch command, and the
  `sqlite3` bisection line.
- The startup log line in `iMessageMaxCommand.swift` carrying the same
  remediation.
- `make verify-db` in `swift/Makefile`, wired into `install`.
- README: the Troubleshooting entry for permission failures, and the
  shell-level check.
- A manual experiment recorded in the execution notes (Step 6).

Out of scope:

- Any watchdog, self-restart, or periodic re-probe inside the process.
  See Maintenance notes for why.
- Connection caching, pooling, or file-identity tracking in `Database`.
- Changing `ClientErrorMessages.permissionDenied`, `ToolErrorMapping`, the
  15-key capability contract, or `DatabaseStatus`'s shape (plan 081 adds
  `features`; this plan adds nothing to the struct).
- Timestamps in `Log.swift` (Maintenance notes).
- CI (`build.yml` runs `swift test --skip-build` only; `verify-db` needs a
  running service with a real `chat.db` and stays local).
- `.mcp.json` (never), `Task.sleep` under `swift/Sources` (never;
  `LaunchdSafetyTests` enforces it).

## Git workflow

- Branch: `git checkout -b advisor/082-database-access-self-heal main`.
- Commit 1 (after Step 1): `test(db): pin retry-on-next-query and live diagnose re-probe after permission_denied`
- Commit 2 (after Step 3): `feat(diagnose): actionable Full Disk Access remediation in fix and startup log`
- Commit 3 (after Step 4): `build: add make verify-db and gate install on database access`
- Commit 4 (after Step 5): `docs: Full Disk Access troubleshooting and the verify-db check`
- Conventional commits, matching `git log`. Do not push, do not merge.

## Steps

### Step 1: Pin the existing recovery behavior (tests that pass today)

These are green on the current code. They exist so a future change that
adds caching to `Database` or a cached probe to `diagnose` fails a test
named after the incident.

`DatabaseErrorHandlingTests.swift`, new test after
`testFailedOpensDoNotAccumulateSQLiteMemory`:

```swift
    // MARK: - Recovery without restart (plan 082)

    /// 2026-09-01: the launchd service ran 14 h with permission_denied.
    /// The Database itself must never cache a failed open; once the file
    /// becomes readable the same instance must serve the next query.
    func testPermissionDeniedIsRetriedOnTheNextQuery() throws {
        try XCTSkipIf(getuid() == 0, "root ignores POSIX mode bits")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("self-heal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("chat.db").path
        FileManager.default.createFile(atPath: path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)

        let db = Database(path: path)

        XCTAssertThrowsError(try db.query("SELECT 1") { _ in 0 }) { error in
            guard case DatabaseError.permissionDenied = error else {
                return XCTFail("expected permissionDenied, got \(error)")
            }
        }
        XCTAssertEqual(Database.checkAccess(path: path).status, "permission_denied")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)

        let rows = try db.query("SELECT 1") { row in row.int(0) }
        XCTAssertEqual(rows, [1], "same Database instance must recover once the file is readable")
        XCTAssertEqual(Database.checkAccess(path: path).status, "accessible")
    }
```

`DiagnoseToolTests.swift`, new test:

```swift
    /// diagnose must probe on every call, never on first call only.
    func testDiagnoseReprobesOnEveryCall() async throws {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var calls = 0
            func next() -> (ok: Bool, status: String) {
                lock.lock(); defer { lock.unlock() }
                calls += 1
                return calls == 1 ? (false, "permission_denied") : (true, "accessible")
            }
        }
        let counter = Counter()
        let probe: DatabaseProbe = { counter.next() }

        let (first, _) = try await encodedResponse(dbProbe: probe)
        XCTAssertFalse(first.database.accessible)
        XCTAssertEqual(first.database.status, "permission_denied")
        XCTAssertEqual(first.capabilities["perm_full_disk"]?.state, "permission-gated")

        let (second, _) = try await encodedResponse(dbProbe: probe)
        XCTAssertTrue(second.database.accessible)
        XCTAssertEqual(second.database.status, "accessible")
        XCTAssertNil(second.database.fix)
        XCTAssertEqual(second.capabilities["perm_full_disk"]?.state, "supported")
        XCTAssertEqual(counter.calls, 2)
    }
```

`encodedResponse(dbProbe:)` is the file's existing private helper (`:14-22`).
`DatabaseProbe` is `@Sendable`, so the closure captures a class with its
own lock rather than a `var`.

**Verify**: `cd swift && swift test --filter "DatabaseErrorHandlingTests\|DiagnoseToolTests"`
→ both new tests pass on unmodified source. If
`testPermissionDeniedIsRetriedOnTheNextQuery` fails on the recovery half,
check whether the test process is root (`id -u`); otherwise STOP, the
open path has changed. Commit 1.

### Step 2: Test for the new fix text (red)

`DiagnoseToolTests.swift`:

```swift
    /// The fix must say which process to grant, what to do about a stale
    /// entry, that the grant only applies to newly launched processes, and
    /// how to bisect between "this user lacks FDA" and "this process lacks FDA".
    func testPermissionDeniedFixIsActionable() async throws {
        let (result, json) = try await encodedResponse(dbProbe: DiagnoseToolTests.dbDenied)
        let fix = try XCTUnwrap(result.database.fix)

        XCTAssertTrue(fix.contains("Full Disk Access"), fix)
        XCTAssertTrue(fix.contains("toggle it off and on"), fix)
        XCTAssertTrue(fix.contains("launchctl kickstart -k gui/$(id -u)/local.imessage-max"), fix)
        XCTAssertTrue(fix.contains("pragma quick_check"), fix)
        XCTAssertTrue(fix.contains("newly launched"), fix)
        XCTAssertEqual(result.capabilities["perm_full_disk"]?.fix, fix,
                       "perm_full_disk.fix must carry the same remediation")

        XCTAssertFalse(json.contains(NSHomeDirectory()), "fix must not leak the home directory: \(json)")
    }
```

**Verify**: `cd swift && swift test --filter DiagnoseToolTests/testPermissionDeniedFixIsActionable`
→ fails on `toggle it off and on`. Expected red.

### Step 3: The fix string and the startup log

In `Diagnose.swift`, add a helper on `DiagnoseTool` and use it at
`:120-122`:

```swift
    /// The process that opens chat.db is the one that needs the grant. For
    /// the launchd service that is the release binary; for stdio it is the
    /// binary the MCP client spawned. Tilde-abbreviated: diagnose must not
    /// echo the username (DiagnoseToolTests.testResponseDoesNotContainHomeDirectory).
    static var executableForGrant: String {
        let raw = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "imessage-max"
        return (raw as NSString).abbreviatingWithTildeInPath
    }

    static func fullDiskAccessFix(executable: String = executableForGrant) -> String {
        "Full Disk Access is missing for the process reading chat.db (\(executable)). "
            + "1) System Settings -> Privacy & Security -> Full Disk Access -> add that executable "
            + "(or the app that launches it, such as Terminal). "
            + "2) If it is already listed, toggle it off and on: a grant bound to an older "
            + "code signature looks present but does not work. "
            + "3) The grant applies only to newly launched processes; relaunch this server: "
            + "launchctl kickstart -k gui/$(id -u)/local.imessage-max (or `make restart` in swift/), "
            + "or reconnect the MCP client for stdio. "
            + "4) To bisect, run sqlite3 -readonly ~/Library/Messages/chat.db 'pragma quick_check;' "
            + "from a terminal: 'ok' means the terminal has access and this process does not; "
            + "'unable to open database file' means the user lacks it everywhere."
    }
```

Replace the two-line assignment at `:121-122` with
`databaseFix = fullDiskAccessFix()`. The `database_not_found` branch is
unchanged. `permFullDiskFix` at `:237` already reuses `databaseFix`.

`Bundle.main.executablePath` for a SwiftPM executable is the binary's
absolute path (`.../swift/.build/release/imessage-max` for the service);
`abbreviatingWithTildeInPath` turns the
`/Users/<name>/Documents/...` prefix into `~/Documents/...`. Under
`swift test` it is the xctest bundle path, which is also under the home
directory and also abbreviates cleanly; that is what the
`NSHomeDirectory()` assertion checks.

In `iMessageMaxCommand.swift:37-40`:

```swift
            let (dbOk, dbStatus) = Database.checkAccess()
            if !dbOk {
                Log.info("Database: \(dbStatus)")
                if dbStatus == "permission_denied" {
                    Log.info(DiagnoseTool.fullDiskAccessFix())
                }
            }
```

`Log.info` writes to stderr, which launchd redirects to
`~/Library/Logs/imessage-max.stderr.log`. `Log.swift`'s format has no
timestamp; do not add one here (Maintenance notes).

**Verify**: `cd swift && swift test --filter "DiagnoseToolTests\|CapabilityContractTests\|ResponseContractTests\|HTTPTransportIntegrationTests"`
→ 0 failures, including `testResponseDoesNotContainHomeDirectory`.
`grep -c "fullDiskAccessFix" swift/Sources/iMessageMax/Tools/Diagnose.swift swift/Sources/iMessageMax/iMessageMaxCommand.swift`
→ `Diagnose.swift:2` (definition and use), `iMessageMaxCommand.swift:1`.
Commit 2.

### Step 4: `make verify-db`

Add to `swift/Makefile` after the `verify` target (`:147`) and before
`install` (`:149`):

```make
verify-db: ## Call diagnose over HTTP and fail if the service cannot read chat.db
	@URL="http://127.0.0.1:$(PORT)"; \
	INIT=$$(curl -si "$$URL" -X POST \
		-H "Content-Type: application/json" \
		-H "Accept: application/json, text/event-stream" \
		-d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"verify-db","version":"1.0"}}}' 2>/dev/null) \
		|| { echo "✗ Server not responding on $$URL"; exit 1; }; \
	SESSION=$$(printf '%s' "$$INIT" | tr -d '\r' | awk 'tolower($$1)=="mcp-session-id:" {print $$2}'); \
	if [ -z "$$SESSION" ]; then echo "✗ initialize returned no Mcp-Session-Id header"; exit 1; fi; \
	BODY=$$(curl -sf "$$URL" -X POST \
		-H "Content-Type: application/json" \
		-H "Accept: application/json, text/event-stream" \
		-H "Mcp-Session-Id: $$SESSION" \
		-d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"diagnose","arguments":{}}}' 2>/dev/null) \
		|| { echo "✗ tools/call diagnose failed"; exit 1; }; \
	printf '%s' "$$BODY" | python3 -c '\
import sys, json; \
r = json.load(sys.stdin)["result"]; \
db = r["structuredContent"]["database"]; \
ok = db.get("accessible") is True; \
print(("✓ Database accessible: " if ok else "✗ Database NOT accessible: ") + db.get("status", "?") + " (" + db.get("path", "?") + ", pid " + str(r["structuredContent"].get("process_id")) + ")"); \
fix = db.get("fix"); \
print("  " + fix) if (not ok and fix) else None; \
sys.exit(0 if ok else 1)'
```

Then:

- `install: sign restart verify verify-db` at `:149`.
- Add `verify-db` to `.PHONY` at `:43`.
- In `install` (`:149-153`): keep `open -R $(BINARY)` out of the success
  path. Replace the recipe with a single `@echo "Done. Database access verified."`.
  Move the Finder hint into `verify-db`'s failure path: after the python
  block, add `|| { echo "  Run: open -R $(BINARY)   # then drag it into Full Disk Access, then make restart"; exit 1; }`
  so a failed check prints the remediation and exits 1 before `install`
  reaches its epilogue.

Tabs, not spaces, for recipe lines. `$$` inside recipes is a literal `$`.
The `Accept` header must include `text/event-stream` or the legacy lane
rejects the request (same headers `verify` uses at `:106-107`).

`HTTPTransportIntegrationTests.swift:114-130` is the Swift version of the
same call sequence (initialize, read `Mcp-Session-Id`, `tools/call`
`diagnose` with the header) and is the reference for what the server
accepts. If the server also requires `MCP-Protocol-Version` on the second
call, `HTTPTransportIntegrationTests` will show it; copy whatever headers
that test sends.

**Verify** (needs the service running; `make status` shows it):

1. `cd swift && make verify-db` → prints `✓ Database accessible: accessible (~/Library/Messages/chat.db, pid <n>)` and exits 0 (`echo $?` → `0`).
2. Negative path, without touching FDA: run the debug binary on a spare
   port with a path it cannot read is not possible (the path is fixed), so
   instead run it from a shell that lacks Full Disk Access. If every
   shell on this Mac has FDA, simulate with the same binary as a
   different user is out of scope; in that case run the python parser
   alone against a canned body:
   `printf '%s' '{"result":{"structuredContent":{"process_id":1,"database":{"accessible":false,"status":"permission_denied","path":"~/x","fix":"F"}}}}' | python3 -c '<the same script>'; echo $?`
   → prints `✗ Database NOT accessible: permission_denied (~/x, pid 1)`, `  F`, exit `1`.
3. `make -n install` → lists `verify-db` after `verify`.
4. `cd swift && swift test --filter LaunchdSafetyTests` → passes (the
   Makefile is not scanned, but confirm the target added no `sleep`
   inside Swift sources by accident).

Commit 3.

### Step 5: README

Under `## Troubleshooting` (`README.md:398`), replace the
`### "Database not found" error` entry (`:405-407`) with two entries:

```markdown
### "Cannot read the iMessage database" / `permission_denied`

Full Disk Access is missing for the **process that opens chat.db**, which
is the `imessage-max` binary itself for the launchd service, or the app
that spawns it for stdio clients. Run `diagnose`; `database.fix` names the
executable and the steps:

1. System Settings → Privacy & Security → Full Disk Access → add that
   executable (or its launching app).
2. If it is already listed, toggle it off and on. A grant bound to an
   earlier code signature looks present but does not work; `make
   setup-signing` gives the binary a stable identity so rebuilds keep it.
3. The grant applies only to newly launched processes. Relaunch:
   `launchctl kickstart -k gui/$(id -u)/local.imessage-max` or `cd swift && make restart`.
4. Bisect from a terminal: `sqlite3 -readonly ~/Library/Messages/chat.db 'pragma quick_check;'`.
   `ok` means your terminal has access and the server process does not;
   `unable to open database file` means the grant is missing for your user.

`make install` now ends with `make verify-db`, which calls `diagnose` over
HTTP and fails if `database.accessible` is false. Run it on its own after
changing Full Disk Access:

    cd swift && make verify-db

### "Database not found" error

`~/Library/Messages/chat.db` does not exist. Sign in to iMessage and send or
receive one message.
```

Also, under `### 1. Grant Full Disk Access` (`:164`), append one
sentence: "After changing the grant, relaunch the server; macOS applies
Full Disk Access only to processes started after the change."

**Verify**: `grep -c "verify-db" README.md` → 2 or more;
`grep -n "quick_check" README.md` → one hit in Troubleshooting.
`cd swift && swift build && swift test` → 436 tests (433 + 3), 0
failures. Commit 4.

### Step 6: Manual experiment, recorded, no code change

The plan's premise is that a running process cannot recover when the
grant changes underneath it. Confirm it once on this Mac and write the
result into the `plans/README.md` status row, because if macOS 26 behaves
differently the Maintenance-notes watchdog becomes worth building.

1. `cd swift && make status` → note the pid. `make verify-db` → `✓`.
2. System Settings → Privacy & Security → Full Disk Access → toggle
   `imessage-max` **off**. Do not restart the service.
3. `make verify-db` → record the result. Expected on macOS 15-26: still
   `✓` (the open file descriptor path is not re-checked for a live
   process) or `✗ permission_denied`; either way note it.
4. Toggle the entry back **on**. Do not restart. `make verify-db` →
   record. Expected: if step 3 showed `✗`, step 4 still shows `✗` until
   relaunch, which is the incident.
5. `launchctl kickstart -k gui/$(id -u)/local.imessage-max`, wait for
   `make verify` to pass, `make verify-db` → `✓` with a new pid.

If step 4 shows `✓` without a relaunch, the platform now applies grants
to running processes and the README wording in Step 5 item 3 should say
"usually" instead of "only"; note it in the status row rather than
rewriting the README in this plan.

## Test plan

- 3 new tests: `DatabaseErrorHandlingTests.testPermissionDeniedIsRetriedOnTheNextQuery`,
  `DiagnoseToolTests.testDiagnoseReprobesOnEveryCall`,
  `DiagnoseToolTests.testPermissionDeniedFixIsActionable`.
- Unchanged and green: `testResponseDoesNotContainHomeDirectory` (guards
  the executable path in the new fix), `testFailedOpensDoNotAccumulateSQLiteMemory`,
  `CapabilityContractTests` (15 keys), `ResponseContractTests`,
  `HTTPTransportIntegrationTests`, `LaunchdSafetyTests`.
- Shell-level: `make verify-db` positive path against the live service;
  parser negative path against the canned body; `make -n install` order.
- Manual: Step 6, recorded in the status row.

## Done criteria

- [ ] `grep -n "testPermissionDeniedIsRetriedOnTheNextQuery" swift/Tests/iMessageMaxTests/DatabaseErrorHandlingTests.swift` finds the test; it passes without root.
- [ ] `grep -n "testDiagnoseReprobesOnEveryCall\|testPermissionDeniedFixIsActionable" swift/Tests/iMessageMaxTests/DiagnoseToolTests.swift` finds both.
- [ ] `grep -n "toggle it off and on\|launchctl kickstart -k\|pragma quick_check" swift/Sources/iMessageMax/Tools/Diagnose.swift` finds all three in `fullDiskAccessFix`.
- [ ] `grep -n "fullDiskAccessFix" swift/Sources/iMessageMax/iMessageMaxCommand.swift` finds the startup log call.
- [ ] `grep -n "^verify-db:" swift/Makefile` finds the target; `grep -n "^install:" swift/Makefile` shows `sign restart verify verify-db`; `.PHONY` lists `verify-db`.
- [ ] `cd swift && make verify-db; echo $?` → `✓ Database accessible ...` and `0` with the service running and granted.
- [ ] `grep -rn "Task.sleep(" swift/Sources` prints nothing.
- [ ] `git diff main -- swift/Sources/iMessageMax/Utilities/ClientErrorMessages.swift swift/Sources/iMessageMax/Utilities/ToolErrorMapping.swift swift/Tests/iMessageMaxTests/CapabilityContractTests.swift` is empty.
- [ ] `cd swift && swift test` reports 436 tests (433 + 3), 0 failures.
- [ ] Four commits on `advisor/082-database-access-self-heal`, not pushed.
- [ ] `plans/README.md` status row updated, including the Step 6 result.

## STOP conditions

- The drift check shows in-scope changes and the excerpts no longer match
  (other than plan 081's expected edits to `Diagnose.swift` and
  `DiagnoseToolTests.swift`).
- Step 1's `testPermissionDeniedIsRetriedOnTheNextQuery` fails on the
  recovery half while not running as root. `Database` has grown state
  that outlives a failed open; that is the bug this plan assumes does not
  exist, and it needs its own diagnosis.
- `testResponseDoesNotContainHomeDirectory` fails after Step 3. The
  executable path did not abbreviate (for example, the binary lives
  outside the home directory and the tilde form is the absolute path,
  which is fine, or `NSHomeDirectory()` differs from `~`, which is not).
  Report the two strings; do not weaken the assertion.
- `make verify-db` cannot get an `Mcp-Session-Id` from `initialize`, or
  `tools/call` returns `Missing Mcp-Session-Id header` even with the
  header set. Compare with `HTTPTransportIntegrationTests.swift:114-130`
  and report the headers the server wants; do not fall back to parsing
  `content[0].text`.
- `make verify-db` reports `✗` on this Mac with Full Disk Access
  granted and the service freshly restarted. That is a live recurrence of
  the incident, not a plan problem; stop and report the `fix` text so the
  operator can act on it.
- Anything in this plan tempts you to add a timer, a background task, or
  a sleep inside `swift/Sources`. Do not.

## Maintenance notes

- Why no in-process watchdog: the process cannot tell "grant missing"
  from "grant present but I was launched before it", and a blind periodic
  `exit(1)` to make launchd relaunch it (KeepAlive `Crashed=true`,
  `ThrottleInterval` 30) would drop every live HTTP session every N
  minutes for the case where the grant is still missing. The right
  trigger is the operator's `make install` / `make verify-db`, which now
  fails loudly. If a self-restart is ever wanted, gate it on
  `Database.checkAccess()` flipping from denied to accessible in the
  process, which cannot happen for a live process under current TCC
  semantics; Step 6's recorded result is the evidence either way.
- `Log.swift` prints no timestamps, which is why the incident timeline
  above leans on git. A `docs`-sized follow-up: prefix each line with
  ISO-8601 UTC from `Date()` formatting, no dependencies, and update any
  test that matches log lines exactly (`grep -rn "Log\." swift/Tests`).
- `make verify-db` runs after `verify`, which already waited for the
  server, so it does not loop. If a future `restart` returns before the
  port is bound, keep the wait in `verify` and leave `verify-db` single-shot.
- If plan 081 lands, `database.features` appears in the same
  `structuredContent`; `verify-db` reads only `database.accessible` and
  is unaffected.
- The `fullDiskAccessFix` string names `local.imessage-max`, the launchd
  label from `Makefile` `LAUNCHD_LABEL`. If the label changes, change
  both; `testPermissionDeniedFixIsActionable` pins the current one.
