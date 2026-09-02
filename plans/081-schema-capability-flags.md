# Plan 081: Probe the chat.db schema at open and guard recently-added columns behind capability flags

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 42deb1f..HEAD -- swift/Sources/iMessageMax/Database/Database.swift swift/Sources/iMessageMax/Database/SchemaCapabilities.swift swift/Sources/iMessageMax/Tools/SearchInternals.swift swift/Sources/iMessageMax/Tools/GetContext.swift swift/Sources/iMessageMax/Tools/GetMessagesInternals.swift swift/Sources/iMessageMax/Tools/Diagnose.swift swift/Sources/iMessageMax/Server/ToolRegistry.swift swift/Tests/iMessageMaxTests/SchemaCapabilitiesTests.swift swift/Tests/iMessageMaxTests/GetMessagesToolTests.swift swift/Tests/iMessageMaxTests/SearchToolTests.swift swift/Tests/iMessageMaxTests/GetContextToolTests.swift swift/Tests/iMessageMaxTests/DiagnoseToolTests.swift swift/Tests/iMessageMaxTests/ResponseContractTests.swift README.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition. Plan 082 also edits
> `Diagnose.swift` and `DiagnoseToolTests.swift`; if it has landed, its
> diff there is expected drift: re-read those two files and continue.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MEDIUM (touches the SELECT lists of three read tools; the
  fallback literals must keep column positions identical or index-based row
  mapping silently reads the wrong column)
- **Depends on**: none. Soft ordering: land plan 082 first, because both
  plans edit `Diagnose.swift` and `DiagnoseToolTests.swift` and 082 is the
  smaller diff.
- **Category**: tech-debt
- **Planned at**: commit `42deb1f`, 2026-09-02. Baseline: `cd swift && swift build && swift test` passes with 433 tests, 0 failures.

## Why this matters

Every query in this server assumes the `chat.db` schema of macOS 15 and
later. If a column is missing, `sqlite3_prepare_v2` fails, `Database.query`
throws `DatabaseError.queryFailed("no such column: m.date_edited")`, and
`ToolErrorMapping.map` turns that into `query_failed` with the generic
"Internal error. Check the server log for details." message
(`ToolErrorMapping.swift:18-20`). The agent calling the tool learns nothing;
the operator has to read stderr. `Package.swift` declares
`platforms: [.macOS(.v15)]`, but the columns this codebase reads were added
across several releases: `thread_originator_guid` (macOS 11 inline replies),
`date_edited` (macOS 13 edits), `associated_message_emoji` (macOS 14 custom
emoji tapbacks). A user running the binary on an older Mac, or a future
macOS that renames or drops one of these, gets a hard failure on
`get_messages`, `search`, and `get_context`, the three most-called tools.

The reference implementation, openclaw/imsg, probes `PRAGMA table_info` on
`message`, `attachment`, `chat_message_join`, and `chat` when the store
opens, keeps the result in a `Sendable` struct of booleans, consults the
flags when building SQL (`schema.hasDateReadColumn ? "m.date_read" : "NULL"`),
and reports them to clients as `database.features`. After this plan, iMessage
Max does the same: a missing column degrades the response (no `reply_to`, no
`edited`, no custom-emoji reaction text) instead of failing it, and
`diagnose` says which columns are present so an agent can explain the
degradation.

## Current state

### How the database is opened

`Database` holds only a path and opens a fresh read-only connection for
every query. There is no pooled or cached handle, so "probe once at open"
means "probe once per `Database` instance, on the first successful open,
and cache the result".

`swift/Sources/iMessageMax/Database/Database.swift:5-17`:

```swift
// Safe as @unchecked Sendable because instances only hold an immutable path string.
// Every query opens its own short-lived read-only SQLite connection, so there is no
// shared mutable connection state crossing actor/task boundaries.
final class Database: @unchecked Sendable {
    static let defaultPath: String = {
        ("~/Library/Messages/chat.db" as NSString).expandingTildeInPath
    }()

    private let path: String

    init(path: String = Database.defaultPath) {
        self.path = path
    }
```

`Database.swift:56-81` (`query`) calls `openReadOnly()` at `:65`, prepares,
steps, and closes in `defer`. `openReadOnly()` at `:85-119` throws
`.notFound` when the file is missing and `.permissionDenied` when
`sqlite3_open_v2` fails, then sets `PRAGMA query_only = ON`.

One `Database()` is created per process for the HTTP service
(`iMessageMaxCommand.swift:34`) and per stdio server (`MCPServer.swift:17`);
`ToolRegistry.registerAll(on:db:resolver:)` (`ToolRegistry.swift:40-57`)
hands that instance to every tool. `ToolRegistry.swift:4` already
`import Synchronization` and uses `Mutex` (`:16`), which is the locking
primitive to reuse for the cache.

### The reference design (imsg, not visible to you; excerpts inlined)

`Sources/IMsgCore/MessageStoreSchema.swift`:

```swift
struct MessageStoreSchema: Sendable {
  let hasThreadOriginatorGUIDColumn: Bool
  let hasDateReadColumn: Bool
  let hasChatMessageJoinMessageDateColumn: Bool
  // ...19 flags total

  init(connection: Connection) throws {
    let messageColumns = try MessageStore.tableColumns(connection: connection, table: "message")
    let attachmentColumns = try MessageStore.tableColumns(connection: connection, table: "attachment")
    let chatMessageJoinColumns = try MessageStore.tableColumns(connection: connection, table: "chat_message_join")
    let chatColumns = try MessageStore.tableColumns(connection: connection, table: "chat")
    self.hasThreadOriginatorGUIDColumn = messageColumns.contains("thread_originator_guid")
    self.hasDateReadColumn = messageColumns.contains("date_read")
    self.hasChatMessageJoinMessageDateColumn = chatMessageJoinColumns.contains("message_date")
    // ...
  }

  /// Test-only: copy `base`, overriding whichever flags are passed.
  init(base: MessageStoreSchema, hasThreadOriginatorGUIDColumn: Bool? = nil, hasDateReadColumn: Bool? = nil, /* ... */) {
    self.hasThreadOriginatorGUIDColumn = hasThreadOriginatorGUIDColumn ?? base.hasThreadOriginatorGUIDColumn
    // ...
  }
}
```

`Sources/IMsgCore/MessageStore+Helpers.swift:12-21`:

```swift
  static func tableColumns(connection: Connection, table: String) throws -> Set<String> {
    let rows = try connection.prepareRowIterator("PRAGMA table_info(\(table))")
    var columns = Set<String>()
    while let row = try rows.failableNext() {
      if let name = try row.get(Expression<String?>("name")) {
        columns.insert(name.lowercased())
      }
    }
    return columns
  }
```

Consulted at SQL construction time, `Sources/IMsgCore/MessageStore+MessageRows.swift:107-122`:

```swift
    let audioMessageColumn = schema.hasAudioMessageColumn ? "m.is_audio_message" : "0"
    let threadOriginatorColumn =
      schema.hasThreadOriginatorGUIDColumn ? "m.thread_originator_guid" : "NULL"
    let dateReadColumn = schema.hasDateReadColumn ? "m.date_read" : "NULL"
```

Surfaced to clients, `Sources/imsg/RPCDatabaseResources.swift:16-43`: a
`RPCDatabaseCapabilities` struct whose `dictionary` becomes
`database.features` in the status snapshot
(`{"unread_state": true, "reply_context": true, ...}`).

### Columns this codebase reads, by file:line, with the fallback each needs

Live check on this machine (macOS 26.6.2, `sqlite3 -readonly
~/Library/Messages/chat.db "PRAGMA table_info(message)"`): `message` has 95
columns, including every name below. `chat` has `is_filtered`,
`account_id`, `account_login`, `last_addressed_handle`.
`chat_message_join` has `chat_id, message_id, message_date, index_state`.
`attachment` has `user_info`, `is_sticker`, `hide_attachment`.

**Guarded by this plan** (three `message` columns, all read by
index-mapped SELECT lists):

| Column | Read at | Fallback SQL |
|---|---|---|
| `m.thread_originator_guid` | `SearchInternals.swift:201` (search select), `:219` (has_replies EXISTS), `:607` (`contextSelectColumns`), `:621` (has_replies in context) | `NULL AS thread_originator_guid`; EXISTS becomes `0 AS has_replies` |
| | `GetContext.swift:176`, `:251`, `:315`, `:350` (four raw SELECTs) | `NULL AS thread_originator_guid` |
| | `GetMessagesInternals.swift:443` (page select), `:122-124` (reply-count GROUP BY) | `NULL AS thread_originator_guid`; skip the reply-count query |
| `m.date_edited` | `SearchInternals.swift:202`, `:607`; `GetContext.swift:177`, `:252`, `:316`, `:351`; `GetMessagesInternals.swift:444` | `0 AS date_edited` |
| `m.associated_message_emoji` | `GetMessagesInternals.swift:17` (reactions map) | `NULL AS associated_message_emoji` |

Every one of these is read positionally afterwards
(`SearchInternals.swift:635-636` `row.string(base + 7)` /
`row.optionalInt(base + 8)`; `GetContext.swift:196-197` `row.string(9)` /
`row.optionalInt(10)`, `:275-276`, `:336-337`, `:371-372`;
`GetMessagesInternals.swift:520-521` `row.string(11)` /
`row.optionalInt(12)`; `:35` `row.string(3)`). The fallback must therefore
be a literal **in the same position with the same alias**, never an omitted
column. `NULL` reads back as `nil` from `row.string` and `row.optionalInt`,
which is exactly what the existing `?? 0` / optional handling produces for
a message with no reply and no edit.

**Probed and reported, not guarded** (listed so `diagnose` can show them
and so the next plan knows where they are):

| Column | Read at | Why not guarded here |
|---|---|---|
| `c.is_filtered` | `ListChats.swift:309`, `:566`, `:598`, `:615`; `GetUnread.swift:262`, `:382`, `:530`, `:566`; `FindChat.swift:314`, `:318`; `SearchInternals.swift:238`, `:283` | Twelve predicate sites across four tools plus the `filtered_hidden` counts; a separate plan (see Maintenance notes) |
| `m.item_type`, `m.group_action_type`, `m.group_title`, `m.other_handle` | `GetMessagesInternals.swift:439-442`, `:449`; `ChatSummaryQueries.swift:286`, `:299`, `:306`, `:318` | Present since macOS 10.8; absence is not plausible |
| `cmj.message_date` | Not read. Mentioned only in a comment at `ChatSummaryQueries.swift:273` | Nothing to guard |
| `m.date_read`, `m.is_delivered`, `m.thread_originator_part`, `m.destination_caller_id`, `m.is_audio_message`, `m.balloon_bundle_id`, `m.payload_data`, `m.schedule_type` | Not read anywhere under `swift/Sources` (`grep -rn` prints nothing) | Nothing to guard; probed so a future reader has the flag |

### The SELECT lists as they exist today

`SearchInternals.swift:190-222` (inside `static func buildQuery(...)`, which
starts at `:172` and ends by returning `(String, [Any])`):

```swift
        let builder = QueryBuilder()
            .select(
                "m.ROWID as msg_id",
                "m.text",
                "m.attributedBody",
                "m.date",
                "m.is_from_me",
                "h.id as sender_handle",
                "c.ROWID as chat_id",
                "c.display_name as chat_display_name",
                "m.guid",
                "m.thread_originator_guid",
                "m.date_edited",
                """
                EXISTS (
                    SELECT 1 FROM message r
                    WHERE r.associated_message_type >= 2000
                    ...
                ) as has_reactions
                """,
                """
                EXISTS (
                    SELECT 1 FROM message r
                    WHERE r.thread_originator_guid = m.guid
                ) as has_replies
                """
            )
```

`buildQuery` is called from `Search.swift` (page query) and from the
`filtered_hidden` count path at `SearchInternals.swift:283`
(`chatFilterPredicate: "c.is_filtered != 0"`). Both callers have `db` in
scope.

`SearchInternals.swift:605-623`:

```swift
    static let contextSelectColumns = """
        m.ROWID as msg_id, m.text, m.attributedBody, m.date, m.is_from_me, h.id as sender_handle,
        m.guid, m.thread_originator_guid, m.date_edited,
        EXISTS (
            ...
        ) as has_reactions,
        EXISTS (
            SELECT 1 FROM message r
            WHERE r.thread_originator_guid = m.guid
        ) as has_replies
        """
```

used at `:585`, `:594` (UNION ALL context windows) and `:649`, `:660`
(`getContext`). It is a `static let`, so it must become a function of the
schema.

`GetContext.swift:165-182` (the first of four; the others at `:245-260`,
`:308-323`, `:343-358` have the same shape with a `LIMIT`):

```swift
                let sql = """
                    SELECT
                        m.ROWID as msg_id,
                        m.text,
                        m.attributedBody,
                        m.date,
                        m.is_from_me,
                        h.id as sender_handle,
                        c.ROWID as chat_id,
                        c.display_name as chat_name,
                        m.guid,
                        m.thread_originator_guid,
                        m.date_edited
                    FROM message m
```

All four sit inside `GetContext.execute(...)` (`:126-`), which has
`database: Database` in scope and catches `DatabaseError` at `:552`.

`GetMessagesInternals.swift:11-20` (`reactionsMap`):

```swift
    static func reactionsMap(db: Database, messageGuids: [String]) throws -> [String: [Reaction]] {
        guard !messageGuids.isEmpty else { return [:] }

        let placeholders = messageGuids.map { _ in "?" }.joined(separator: ", ")
        let sql = """
            SELECT m.associated_message_guid, m.associated_message_type, h.id,
                   m.associated_message_emoji, m.date
            FROM message m
```

`GetMessagesInternals.swift:92-135` (`replyLookup`): two queries, the second
at `:120-128` is `SELECT thread_originator_guid, COUNT(*) FROM message WHERE thread_originator_guid IN (...) GROUP BY 1`.

`GetMessagesInternals.swift:429-445` (`queryMessages` on the tool):

```swift
        let query = QueryBuilder()
            .select(
                "m.ROWID as id",
                "m.guid",
                "m.text",
                "m.attributedBody",
                "m.date",
                "m.is_from_me",
                "h.id as sender_handle",
                "m.item_type",
                "m.group_action_type",
                "m.group_title",
                "oh.id as other_handle_id",
                "m.thread_originator_guid",
                "m.date_edited"
            )
```

### diagnose

`Diagnose.swift:28-34`:

```swift
struct DiagnoseResult: Codable {
    struct DatabaseStatus: Codable {
        let accessible: Bool
        let status: String
        let path: String
        let fix: String?
    }
```

Registration at `:64` takes `(on server: Server, resolver: ContactResolver)`,
no database; `ToolRegistry.swift:56` calls
`DiagnoseTool.register(on: server, resolver: resolver)`. `execute` at
`:107-112` takes three injectable probes:

```swift
    static func execute(
        resolver: ContactResolver,
        dbProbe: DatabaseProbe = { Database.checkAccess() },
        contactsProbe: ContactsProbe = { ContactResolver.authorizationStatus() },
        automationProbe: AutomationProbe = { AutomationPermission.checkAutomationPermission() }
    ) async throws -> DiagnoseResult {
```

and builds the result at `:297-316` with
`database: .init(accessible: dbOk, status: dbStatus, path: ..., fix: databaseFix)`.
`ResponseContractTests.swift:223` constructs
`.init(accessible: true, status: "ok", path: "/tmp/chat.db", fix: nil)`
directly, so any new stored property on `DatabaseStatus` needs a default in
an explicit initializer or that test stops compiling.
`CapabilityContractTests.swift:139` pins `capabilities` to exactly 15 keys;
`database.features` is a new key under `database`, not under
`capabilities`, so the contract is untouched.

### Fixture

`swift/Tests/iMessageMaxTests/ToolTestSupport.swift:156-176` creates
`message` with `thread_originator_guid TEXT` and
`date_edited INTEGER DEFAULT 0` and `associated_message_emoji TEXT`;
`insertMessage` (`:62-103`) writes all three. The fixture exposes
`execute(_ sql:)` (`:33-38`), and the system SQLite is 3.51.0
(`sqlite3 --version`), which supports `ALTER TABLE ... DROP COLUMN`
(added in 3.35). So a "column missing" variant is: build the normal
fixture, insert rows, then `try fixture.execute("ALTER TABLE message DROP COLUMN date_edited")`.
No fixture-schema change is required. `makeGetMessagesFixture()` lives at
`GetMessagesToolTests.swift:587`; `makeSearchFixture()` in
`SearchToolTests.swift`; `GetContextToolTests` reuses
`makeGetMessagesFixture()` and has an `unwrapSuccess` helper.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `cd swift && swift build` | ends in `Build complete!` |
| Focused | `cd swift && swift test --filter "SchemaCapabilitiesTests\|GetMessagesToolTests\|SearchToolTests\|GetContextToolTests\|DiagnoseToolTests\|ResponseContractTests\|CapabilityContractTests\|QueryCountTests"` | 0 failures |
| Whole suite | `cd swift && swift test` | 433 plus new tests, 0 failures |
| Live columns | `sqlite3 -readonly ~/Library/Messages/chat.db "PRAGMA table_info(message)" \| cut -d'\|' -f2 \| grep -E "thread_originator_guid\|date_edited\|associated_message_emoji"` | three lines |
| Launchd guard | `cd swift && swift test --filter LaunchdSafetyTests` | passes (no `Task.sleep` under `swift/Sources`) |

## Scope

In scope:

- New `swift/Sources/iMessageMax/Database/SchemaCapabilities.swift`:
  the flag struct, the PRAGMA probe, the test override initializer, the
  `features` dictionary, and the SQL-fragment helpers.
- `Database.swift`: a `Mutex`-guarded cache and `func schema() throws -> SchemaCapabilities`,
  plus an internal `init(path:schemaOverride:)` for tests.
- Flag-guarded SQL at the sites listed under "Guarded by this plan":
  `SearchInternals.swift`, `GetContext.swift`, `GetMessagesInternals.swift`.
- `diagnose`: `database.features` when the database is accessible; `db`
  threaded into `DiagnoseTool.register`; a new injectable `schemaProbe`.
- Tests: new `SchemaCapabilitiesTests.swift`; one degraded-fixture test
  each in `GetMessagesToolTests`, `SearchToolTests`, `GetContextToolTests`;
  two in `DiagnoseToolTests`.
- README: two sentences under `### diagnose`.

Out of scope:

- Guarding `c.is_filtered` (12 sites) or the group-event columns. Listed
  under Maintenance notes.
- Changing what any tool returns when every column is present. Responses
  on the live database must be byte-identical before and after.
- Changing `ToolErrorMapping`, `ClientErrorMessages`, or the fixture
  schema in `ToolTestSupport.swift`.
- `.mcp.json` (never), `Task.sleep` under `swift/Sources` (never;
  `LaunchdSafetyTests` enforces it), any new dependency.

## Git workflow

- Branch: `git checkout -b advisor/081-schema-capability-flags main`.
- Commit 1 (after Step 2): `feat(db): probe chat.db schema into SchemaCapabilities`
- Commit 2 (after Step 4): `feat(tools): guard thread_originator_guid, date_edited, associated_message_emoji behind schema flags`
- Commit 3 (after Step 5): `feat(diagnose): report database.features from the schema probe`
- Commit 4 (after Step 6): `docs: document database.features in diagnose`
- Conventional commits, matching `git log` (`feat(http): ...`, `fix: ...`, `docs: ...`).
- Do not push, do not merge.

## Steps

### Step 1: Tests first for the probe (red)

Create `swift/Tests/iMessageMaxTests/SchemaCapabilitiesTests.swift`:

- `testProbeReportsEveryFixtureColumnPresent`: `let fixture = try ToolTestDatabase()`;
  `let schema = try fixture.database().schema()`; assert
  `schema.messageThreadOriginatorGuid`, `schema.messageDateEdited`,
  `schema.messageAssociatedMessageEmoji`, `schema.chatIsFiltered` are all
  `true`, and `schema.messageDateRead`, `schema.chatMessageJoinMessageDate`
  are `false` (the fixture does not define them; this proves the probe
  reads the file rather than returning `.assumed`).
- `testProbeSeesDroppedColumn`: same fixture, then
  `try fixture.execute("ALTER TABLE message DROP COLUMN date_edited")`
  **before** creating the `Database`; `schema().messageDateEdited == false`
  and `messageThreadOriginatorGuid == true`.
- `testProbeIsCachedPerInstance`: create `Database`, call `schema()`, then
  drop `date_edited` through the fixture, call `schema()` again on the same
  instance: still `true` (cached). A fresh `fixture.database()` reports
  `false`.
- `testOverrideInitializerReplacesOnlyNamedFlags`:
  `SchemaCapabilities(base: .assumed, messageDateEdited: false)` has
  `messageDateEdited == false` and every other flag equal to `.assumed`.
- `testFeaturesDictionaryUsesTableDotColumnKeys`:
  `SchemaCapabilities.assumed.features["message.date_edited"] == true` and
  `features.count == 18` (the 18 columns in the two tables above: 14
  `message`, 1 `chat`, 1 `chat_message_join`, 2 `attachment`; adjust the
  number to what Step 2 defines and keep the test in sync).
- `testProbeOnUnreadableFileThrowsPermissionDenied`: temp file with
  `posixPermissions: 0` (copy the setup from
  `DatabaseErrorHandlingTests.testFailedOpensDoNotAccumulateSQLiteMemory`,
  `:84-92`); `XCTAssertThrowsError(try Database(path: path).schema())` with
  `case DatabaseError.permissionDenied`. Add `try XCTSkipIf(getuid() == 0)`
  first: root ignores mode bits.

**Verify**: `cd swift && swift build --build-tests` fails on the unknown
`SchemaCapabilities` / `schema()` names. Expected red.

### Step 2: `SchemaCapabilities` and the cached probe

Create `swift/Sources/iMessageMax/Database/SchemaCapabilities.swift`:

```swift
// Sources/iMessageMax/Database/SchemaCapabilities.swift
import Foundation
import SQLite3

/// Which optional chat.db columns exist on this machine. Probed once per
/// `Database` instance from `PRAGMA table_info` (plan 081, after imsg's
/// MessageStoreSchema). Consult the flags when building SQL; never read a
/// guarded column unconditionally.
struct SchemaCapabilities: Sendable, Equatable {
    // message
    let messageThreadOriginatorGuid: Bool
    let messageThreadOriginatorPart: Bool
    let messageDateEdited: Bool
    let messageAssociatedMessageEmoji: Bool
    let messageDateRead: Bool
    let messageIsDelivered: Bool
    let messageIsAudioMessage: Bool
    let messageBalloonBundleId: Bool
    let messagePayloadData: Bool
    let messageDestinationCallerId: Bool
    let messageScheduleType: Bool
    let messageItemType: Bool
    let messageGroupActionType: Bool
    let messageGroupTitle: Bool
    let messageOtherHandle: Bool
    // chat
    let chatIsFiltered: Bool
    // chat_message_join
    let chatMessageJoinMessageDate: Bool
    // attachment
    let attachmentUserInfo: Bool
    let attachmentHideAttachment: Bool

    /// The macOS 15 floor the code was written against: everything present.
    static let assumed = SchemaCapabilities(/* every flag true */)

    /// Probe an open connection. Throws `DatabaseError.queryFailed` if a
    /// PRAGMA cannot be prepared (a missing table reads as an empty set,
    /// not an error, so every flag for that table is false).
    init(probing conn: OpaquePointer) throws {
        let message = try Self.tableColumns(conn, table: "message")
        let chat = try Self.tableColumns(conn, table: "chat")
        let cmj = try Self.tableColumns(conn, table: "chat_message_join")
        let attachment = try Self.tableColumns(conn, table: "attachment")
        messageThreadOriginatorGuid = message.contains("thread_originator_guid")
        // ... one line per flag, lowercase names ...
    }

    /// Test-only: copy `base`, overriding the flags that are passed.
    init(base: SchemaCapabilities,
         messageThreadOriginatorGuid: Bool? = nil,
         messageDateEdited: Bool? = nil,
         messageAssociatedMessageEmoji: Bool? = nil,
         chatIsFiltered: Bool? = nil) {
        self.messageThreadOriginatorGuid = messageThreadOriginatorGuid ?? base.messageThreadOriginatorGuid
        // ... the four overridable flags; every other flag copies `base` ...
    }

    /// `"<table>.<column>": present`, for `diagnose`'s `database.features`.
    var features: [String: Bool] { [
        "message.thread_originator_guid": messageThreadOriginatorGuid,
        // ... one entry per flag ...
    ] }

    // MARK: SQL fragments. Same alias in the same position, so the
    // index-based row mappers do not move.

    var threadOriginatorGuidSQL: String {
        messageThreadOriginatorGuid ? "m.thread_originator_guid" : "NULL AS thread_originator_guid"
    }
    var dateEditedSQL: String {
        messageDateEdited ? "m.date_edited" : "0 AS date_edited"
    }
    var associatedMessageEmojiSQL: String {
        messageAssociatedMessageEmoji ? "m.associated_message_emoji" : "NULL AS associated_message_emoji"
    }
    /// The `has_replies` EXISTS subquery, or a literal 0.
    var hasRepliesSQL: String {
        messageThreadOriginatorGuid
            ? """
              EXISTS (
                  SELECT 1 FROM message r
                  WHERE r.thread_originator_guid = m.guid
              ) AS has_replies
              """
            : "0 AS has_replies"
    }

    private static func tableColumns(_ conn: OpaquePointer, table: String) throws -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(conn)))
        }
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1) {   // column 1 of table_info is `name`
                names.insert(String(cString: c).lowercased())
            }
        }
        return names
    }
}
```

`table` is one of four literals defined in this file; never interpolate a
caller-supplied string into the PRAGMA.

In `Database.swift`:

- `import Synchronization`.
- Add `private let schemaCache: Mutex<SchemaCapabilities?>` and an
  internal initializer:

```swift
    init(path: String = Database.defaultPath) {
        self.path = path
        self.schemaCache = Mutex(nil)
    }

    /// Test-only: skip the probe and use `schema` as the answer.
    init(path: String, schemaOverride: SchemaCapabilities) {
        self.path = path
        self.schemaCache = Mutex(schemaOverride)
    }

    /// The probed schema, cached after the first successful open. A failed
    /// open throws and caches nothing, so the next call probes again.
    func schema() throws -> SchemaCapabilities {
        if let cached = schemaCache.withLock({ $0 }) { return cached }
        let conn = try openReadOnly()
        defer { sqlite3_close(conn) }
        let probed = try SchemaCapabilities(probing: conn)
        schemaCache.withLock { $0 = probed }
        return probed
    }
```

- Update the class comment at `:5-7`: the instance now also holds a
  `Mutex`-guarded cache, which is why `@unchecked Sendable` still holds.

Do not probe inside `query`; tools call `schema()` explicitly when they
build SQL, which keeps `QueryCountTests` bounds meaningful (`schema()` is
not counted by `queryCountForTesting`, and must not be: it opens a
connection but runs no tool query).

**Verify**: `cd swift && swift test --filter "SchemaCapabilitiesTests\|DatabaseErrorHandlingTests"`
→ all green, 6 new tests. Commit 1.

### Step 3: Degraded-fixture tests for the three tools (red)

- `GetMessagesToolTests.testMissingReplyAndEditColumnsDegradeToPlainMessages`:
  `let fixture = try makeGetMessagesFixture()`, then
  `try fixture.execute("ALTER TABLE message DROP COLUMN thread_originator_guid")`,
  `try fixture.execute("ALTER TABLE message DROP COLUMN date_edited")`,
  `try fixture.execute("ALTER TABLE message DROP COLUMN associated_message_emoji")`.
  `GetMessagesTool(db: fixture.database(), resolver: makeSeededResolver())`,
  `execute(args: ["chat_id": .string("chat20")])`: succeeds, `messages.count == 4`
  (same as `testExactChatIdReturnsMessagesAndGeneratedChatName`), and no
  message dictionary contains `reply_to`, `reply_count`, or `edited`.
- `GetMessagesToolTests.testSchemaOverrideIsConsultedEvenWhenColumnsExist`:
  normal fixture (columns present, and insert one message with
  `threadOriginatorGuid: "gm200"` and one with `dateEdited: 5`), but
  `Database(path: fixture.path, schemaOverride: SchemaCapabilities(base: .assumed, messageThreadOriginatorGuid: false, messageDateEdited: false))`.
  The response has no `reply_to` and no `edited` keys. This is the imsg
  `init(base:)` pattern: it proves the SQL reads the flag, not the file.
- `SearchToolTests.testMissingReplyAndEditColumnsDegradeSearch`: `makeSearchFixture()`,
  drop the same three columns, run the `SearchTool.execute(query: "costa trip", ...)`
  call from `testAnyWordVsMatchAll` (`SearchToolTests.swift:9-22`) with
  `includeContext: true`; assert the same three result ids and no
  `reply_to` / `edited` keys anywhere in the decoded JSON string
  (`XCTAssertFalse(json.contains("\"reply_to\""))`).
- `GetContextToolTests.testMissingReplyAndEditColumnsDegradeContext`:
  `makeGetMessagesFixture()`, drop the three columns,
  `GetContext.execute(messageId: "msg_202", before: 5, after: 5, database:, resolver:)`
  succeeds with `response.message.id == "msg_202"` and `before`/`after`
  ids as in `testMessageIdReturnsBeforeAndAfterInDateOrder`.

Insert rows **before** dropping columns; `insertMessage` writes all three.

**Verify**: `cd swift && swift test --filter "GetMessagesToolTests\|SearchToolTests\|GetContextToolTests"`
→ the four new tests fail with `query_failed` / `internal_error` (the
current behavior). Expected red. If they pass, the drop did not happen;
STOP.

### Step 4: Flag-guarded SQL

`SearchInternals.swift`:

- `buildQuery(...)` (`:172`): add a parameter `schema: SchemaCapabilities`.
  Replace `"m.thread_originator_guid"` (`:201`) with
  `schema.threadOriginatorGuidSQL`, `"m.date_edited"` (`:202`) with
  `schema.dateEditedSQL`, and the `has_replies` EXISTS literal (`:215-221`)
  with `schema.hasRepliesSQL`. The `has_reactions` EXISTS stays.
- Both callers pass `schema: try db.schema()` (the page query in
  `Search.swift` and the count at `SearchInternals.swift:283`). The `try`
  goes inside the existing `do` that already catches `DatabaseError`
  (`Search.swift:513` maps it).
- `static let contextSelectColumns` (`:605`) becomes
  `static func contextSelectColumns(_ schema: SchemaCapabilities) -> String`
  with `\(schema.threadOriginatorGuidSQL), \(schema.dateEditedSQL),` in
  place of `m.thread_originator_guid, m.date_edited,` and
  `\(schema.hasRepliesSQL)` in place of the trailing EXISTS. Update the four
  call sites (`:585`, `:594`, `:649`, `:660`) to pass a `schema` obtained
  once per request from `db.schema()`. Note `hasRepliesSQL` already ends in
  `AS has_replies`; keep the comma before it and drop the old alias.
- `mapContextRow` (`:625-640`) is unchanged: positions 7, 8, 10 still hold
  `thread_originator_guid`, `date_edited`, `has_replies`.

`GetContext.swift`:

- At the top of the `do` block inside `execute` (before `:165`), add
  `let schema = try database.schema()`.
- In each of the four SELECTs (`:176-177`, `:251-252`, `:315-316`,
  `:350-351`) replace the two lines
  `m.thread_originator_guid,` / `m.date_edited` with
  `\(schema.threadOriginatorGuidSQL),` / `\(schema.dateEditedSQL)`.
- Row mapping at `:196-197`, `:275-276`, `:336-337`, `:371-372` unchanged.

`GetMessagesInternals.swift`:

- `reactionsMap(db:messageGuids:)` (`:11`): `let schema = try db.schema()`
  and interpolate `\(schema.associatedMessageEmojiSQL)` in place of
  `m.associated_message_emoji` at `:17`.
- `replyLookup(db:pageGuids:pageIdByGuid:originatorGuids:)` (`:92`): first
  line `guard try db.schema().messageThreadOriginatorGuid else { return ReplyLookup(originatorIdByGuid: [:], replyCountByGuid: [:]) }`.
  With the column absent no row can carry an originator guid and the
  reply-count query at `:120-128` would fail to prepare.
- `queryMessages(...)` (`:419`): `let schema = try db.schema()` before the
  builder; replace `"m.thread_originator_guid"` (`:443`) and
  `"m.date_edited"` (`:444`) with `schema.threadOriginatorGuidSQL` and
  `schema.dateEditedSQL`. Mapping at `:518-521` unchanged.

Search for any other literal use before moving on:
`grep -rn "m.thread_originator_guid\|m.date_edited\|m.associated_message_emoji" swift/Sources` must
show only `SchemaCapabilities.swift`, plus the `r.thread_originator_guid`
inside `hasRepliesSQL`.

**Verify**: `cd swift && swift test --filter "SchemaCapabilitiesTests\|GetMessagesToolTests\|SearchToolTests\|GetContextToolTests\|QueryCountTests\|SearchRecallTests\|ResponseContractTests"`
→ 0 failures, the four Step 3 tests green, no existing test edited. If
`QueryCountTests` fails because a bound moved, that means `schema()` was
wired through `query`; undo that, do not raise the bound. Commit 2.

### Step 5: `database.features` in diagnose (test first)

Tests in `DiagnoseToolTests.swift`, using the file's existing injected
probes:

- `testFeaturesReportedWhenDatabaseAccessible`: call
  `DiagnoseTool.execute(resolver:, dbProbe: dbAccessible, contactsProbe:, automationProbe:, schemaProbe: { SchemaCapabilities(base: .assumed, messageDateEdited: false) })`;
  `result.database.features?["message.date_edited"] == false` and
  `?["message.thread_originator_guid"] == true`; the encoded JSON contains
  `"features"`.
- `testFeaturesOmittedWhenDatabaseDenied`: `dbProbe: dbDenied`,
  `schemaProbe: { XCTFail("must not probe a denied database"); return nil }`;
  `result.database.features == nil` and the JSON does not contain
  `"features"`.

Implementation in `Diagnose.swift`:

- `typealias SchemaProbe = @Sendable () -> SchemaCapabilities?` next to the
  other probe typealiases (`:22-26`).
- `DatabaseStatus` gains `let features: [String: Bool]?` and an explicit
  `init(accessible:status:path:fix:features: [String: Bool]? = nil)` so
  `ResponseContractTests.swift:223` compiles unchanged. Synthesized
  `Codable` omits a nil optional, matching how `fix` already behaves.
- `execute` gains `schemaProbe: SchemaProbe = { nil }` as the last
  parameter. After `let (dbOk, dbStatus) = dbProbe()` (`:116`):
  `let features = dbOk ? schemaProbe()?.features : nil`. Pass `features:`
  into `.init(...)` at `:301-308`.
- `register(on:resolver:)` (`:64`) becomes `register(on:db:resolver:)` and
  the handler calls
  `execute(resolver: resolver, schemaProbe: { try? db.schema() })`.
  `try?` is deliberate: a probe failure must not turn a working `diagnose`
  into an error; the flags just go missing.
- `ToolRegistry.swift:56`: `DiagnoseTool.register(on: server, db: db, resolver: resolver)`.

**Verify**: `cd swift && swift test --filter "DiagnoseToolTests\|CapabilityContractTests\|ResponseContractTests\|HTTPTransportIntegrationTests"`
→ 0 failures; `CapabilityContractTests` still asserts exactly 15
`capabilities` keys without edits. Commit 3.

### Step 6: Docs

`README.md` under `### diagnose` (`:359-366`), after the `capabilities.verified_send`
sentence, add:

> `database.features` lists which optional `chat.db` columns exist on this
> Mac, keyed `table.column` (for example `message.date_edited`). When one is
> `false`, the tools that read it degrade instead of failing: no `reply_to`
> or `reply_count` without `message.thread_originator_guid`, no `edited`
> without `message.date_edited`, no custom-emoji reaction text without
> `message.associated_message_emoji`.

**Verify**: `grep -c "database.features" README.md` → 1.
`cd swift && swift build && swift test` → 433 plus new tests (expected 445:
6 schema, 2 get_messages, 1 search, 1 get_context, 2 diagnose), 0 failures.
Commit 4.

### Step 7: Live sanity check (no code change)

Build and run the debug binary in stdio mode against the live database:

```bash
cd swift && swift build
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"diagnose","arguments":{}}}' \
  | ./.build/debug/imessage-max 2>/dev/null | grep -o '"features":{[^}]*}'
```

Expected: one `features` object with every `message.*` key `true`,
`chat.is_filtered` `true`, `chat_message_join.message_date` `true`. If the
terminal lacks Full Disk Access the call reports `permission_denied` and no
`features`; that is plan 082's territory, not a failure of this plan. Then
call `get_messages` for a chat known to contain a reply (the 076 execution
record names chat2151) and confirm `reply_to` still appears: the guard must
not have removed the feature where the column exists.

## Test plan

- 12 new tests: `SchemaCapabilitiesTests` (6), `GetMessagesToolTests` (2),
  `SearchToolTests` (1), `GetContextToolTests` (1), `DiagnoseToolTests` (2).
- Structural patterns: `DatabaseErrorHandlingTests` for the unreadable-file
  setup; `GetMessagesToolTests.testExactChatIdReturnsMessagesAndGeneratedChatName`
  for tool invocation; `DiagnoseToolTests` for injected probes.
- Existing `QueryCountTests`, `SearchRecallTests`, `ResponseContractTests`,
  `CapabilityContractTests`, `HTTPTransportIntegrationTests` unchanged and
  green.
- Manual live check per Step 7.

## Done criteria

- [ ] `swift/Sources/iMessageMax/Database/SchemaCapabilities.swift` exists; `grep -c "PRAGMA table_info" swift/Sources/iMessageMax/Database/SchemaCapabilities.swift` is 1.
- [ ] `grep -n "func schema()" swift/Sources/iMessageMax/Database/Database.swift` finds the method; `grep -n "schemaOverride" swift/Sources/iMessageMax/Database/Database.swift` finds the test initializer.
- [ ] `grep -rn "m.thread_originator_guid\|m.date_edited\|m.associated_message_emoji" swift/Sources` prints only lines in `SchemaCapabilities.swift`.
- [ ] `grep -rn "Task.sleep(" swift/Sources` prints nothing.
- [ ] `grep -n "features" swift/Sources/iMessageMax/Tools/Diagnose.swift` shows the property, the probe, and the assignment.
- [ ] `git diff main -- swift/Tests/iMessageMaxTests/ToolTestSupport.swift swift/Tests/iMessageMaxTests/CapabilityContractTests.swift swift/Tests/iMessageMaxTests/QueryCountTests.swift` is empty.
- [ ] `cd swift && swift test` reports 445 tests (433 + 12), 0 failures.
- [ ] Four commits on `advisor/081-schema-capability-flags`, not pushed.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- The drift check shows in-scope changes and the excerpts no longer match
  (other than plan 082's expected edits to `Diagnose.swift` and
  `DiagnoseToolTests.swift`).
- `ALTER TABLE message DROP COLUMN ...` fails in the fixture (`sqlite3_exec`
  error mentioning "near DROP"). The linked SQLite is older than 3.35;
  report the version from `sqlite3 --version` and stop. Do not rewrite the
  fixture schema to work around it.
- Step 3's red tests pass before Step 4. The column drop did not take
  effect or the tool is not reading the column; find out which and report.
- `QueryCountTests` needs a bound raised. The probe leaked into the counted
  path.
- A `ResponseContractTests` or `CapabilityContractTests` case needs an edit
  to pass.
- Step 7 shows `reply_to` or `edited` missing on the live database for a
  message that had them before the change (compare against `main`'s build).

## Maintenance notes

- Adding a guard for another column: add the flag and its `...SQL` helper
  to `SchemaCapabilities`, replace the literal at the read site, keep the
  alias and position, add a `DROP COLUMN` test. The `features` count test
  in `SchemaCapabilitiesTests` must be bumped in the same commit.
- Deferred, in order of plausibility:
  1. `chat.is_filtered` (plan 074): 12 sites in `ListChats.swift`,
     `GetUnread.swift`, `FindChat.swift`, `SearchInternals.swift`. Fallback
     is to omit the predicate and report `filtered_hidden: 0`. Worth its own
     plan because the predicate is built four different ways.
  2. `message.item_type`, `group_action_type`, `group_title`, `other_handle`
     (plan 073 group events, `GetMessagesInternals.swift:439-449`,
     `ChatSummaryQueries.swift:286-318`): present since macOS 10.8; guard
     only if a report proves otherwise.
  3. `attachment.hide_attachment`, `attachment.user_info`: probed here but
     not read anywhere yet.
- `schema()` caches for the life of the `Database` instance, which is the
  life of the process. A macOS upgrade under a running launchd service will
  not be noticed until restart; that matches the rest of the process
  (contacts, code signature). If plan 082's file-identity re-validation ever
  lands in `Database`, clear `schemaCache` when the identity changes.
- Reviewer focus: every replaced literal keeps `AS <alias>` in the same
  position; `mapContextRow`, `GetContext`'s tuple mappers, and
  `queryMessages`'s `MessageRow` mapper are untouched; `schema()` is never
  called inside `Database.query`.
