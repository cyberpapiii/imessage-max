# 080: Live inbox — `get_messages_since` cursor pull, then a chat.db watcher that pushes `notifications/imessage/new_messages`

> **Executor instructions.** Read this whole file before touching code. Work
> on branch `advisor/080-live-inbox` cut from `main`. Follow the steps in
> order; every step ends with a **Verify** command and the exact output you
> must see before moving on. Layer 1 (steps 1–8) must ship. Layer 2 (steps
> 9–13) is optional and gated: start it only after step 8 is green and
> committed, and stop at the first STOP condition. Never `Task.sleep` in
> `swift/Sources` (`LaunchdSafetyTests` fails the build on it; use
> `AsyncTimeout.sleep` or a `DispatchSourceTimer`). Never touch `.mcp.json`.
> Do not push, tag, or merge; the operator merges.
>
> **Drift check (run first).** This plan was written against commit
> `42deb1f`. Before starting, run:
>
> ```bash
> git diff --stat 42deb1f..HEAD -- \
>   swift/Sources/iMessageMax/Tools/GetMessages.swift \
>   swift/Sources/iMessageMax/Tools/GetMessagesInternals.swift \
>   swift/Sources/iMessageMax/Tools/GetUnread.swift \
>   swift/Sources/iMessageMax/Tools/Diagnose.swift \
>   swift/Sources/iMessageMax/Server/ToolRegistry.swift \
>   swift/Sources/iMessageMax/Server/SessionManager.swift \
>   swift/Sources/iMessageMax/Server/HTTPTransport.swift \
>   swift/Sources/iMessageMax/Server/SSEConnection.swift \
>   swift/Sources/iMessageMax/Server/Version.swift \
>   swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift \
>   swift/Sources/iMessageMax/iMessageMaxCommand.swift \
>   swift/Tests/iMessageMaxTests/ToolTestSupport.swift \
>   swift/Tests/iMessageMaxTests/ToolRegistryTests.swift \
>   swift/Tests/iMessageMaxTests/ToolRegistryBindingTests.swift \
>   swift/Tests/iMessageMaxTests/CapabilityContractTests.swift \
>   swift/Tests/iMessageMaxTests/HTTPTransportIntegrationTests.swift \
>   swift/Tests/iMessageMaxTests/HTTPTransportLiveSocketTests.swift \
>   README.md AGENTS.md CHANGELOG.md using-imessage-max/SKILL.md \
>   docs/validation/2026-04-09-release-checklist.md
> ```
>
> If the output is empty, proceed. If any file listed has changed, re-read
> that file and re-derive the line numbers quoted below before editing; the
> excerpts here are for orientation, the working tree is the truth. If
> `GetMessagesInternals.swift` or `Diagnose.swift` changed in a way that
> removes a symbol this plan relies on (`MessageRow`, `MessageAnnotations`,
> `getAttachmentsMap`, `Capability`), STOP and report.

## Status

- **Priority:** P2
- **Effort:** M for layer 1 alone; L with layer 2
- **Risk:** Medium. Layer 1 is a new read-only tool with no changes to
  existing tool behavior, but it bumps the registered tool count from 12 to
  13, which touches five test/doc sites. Layer 2 adds a long-lived kqueue
  watcher and a server-initiated MCP notification to the launchd service;
  the risk is a lingering timer or file descriptor, which is why it is
  gated and has its own STOP conditions.
- **Depends on:** none (plan 074 `is_filtered` already merged at `34590a5`;
  plan 076 reaction/reply/edit annotations already merged at `bec239e`).
- **Category:** feature (new tool), transport (layer 2)
- **Planned at:** commit `42deb1f`, 2026-09-02. Baseline:
  `cd swift && swift build && swift test` passes with 433 tests, 0 failures.

## Why this matters

Every read tool in iMessage Max answers "what does the inbox look like
now": `get_unread` (unread in a window), `get_messages` (one chat, newest
first, `date:rowid` cursor), `get_active_conversations`. None of them
answers "what arrived since I last looked, across every chat, in arrival
order, without gaps or repeats". An agent that wants to keep up with the
inbox today has to poll `get_unread` and diff by message id, which misses
anything the user already read on their phone, and re-reads reactions and
junk it cannot distinguish from new traffic. `diagnose` honestly reports
`"live_inbox": {"state": "unavailable"}` (`Tools/Diagnose.swift:290`).

`chat.db` already has the primitive we need: `message.ROWID` is a monotonic
insert cursor. The `imsg` CLI (github.com/steipete/imsg, cloned for this
plan) built its `messages.after` RPC and its `watch` subscription on exactly
that cursor and learned the sharp edges the hard way: rows whose
`chat_message_join` has not landed yet (chat id unknown), reaction rows
interleaved with messages, the cursor needing to advance past rows that
were consumed but not returned, and the WAL/SHM files being rotated out
from under a kqueue watch. This plan ports those lessons into a pull tool
first (works on every transport, including the stateless modern lane) and
a push notification second (legacy session lane over SSE only).

Live numbers from this Mac's `chat.db` on 2026-09-02, read-only
(`MAX(ROWID) = 234006`, 228,740 rows):

- Of the last 5,000 rowids: 3,410 plain messages, 1,368 reactions
  (`associated_message_type` 2000–3006), 117 URL-balloon rows.
- 41 rows among the last 5,000 have **no** `chat_message_join` row at all,
  the newest being 233615. These are permanent orphans, not in-flight
  inserts. A cursor that refuses to pass unresolved rows forever would stall
  on them, which is why the grace window below exists.
- 20 recent joined messages sit in `is_filtered != 0` chats (junk/RCS
  short codes) vs 3,349 in shown chats. `is_filtered` is an integer flag
  with values 0/1/2/3/4/36/52/68 on this machine; plan 074's predicate
  `c.is_filtered = 0` is the one to reuse.
- 26 cases in the last 5,000 where `ROWID + 1` has an earlier `date` than
  `ROWID`. ROWID order is arrival order, not send-time order; the tool
  documents that it returns arrival order.
- 0 URL-balloon rows in the last 5,000 duplicate a preceding plain-text
  row. imsg's URL-balloon dedupe targets a transient double-insert seen
  during live watching, not something visible at rest, so layer 1 does not
  implement it (see Maintenance notes).

## Current state

### `get_messages` is chat-scoped, date-descending, and session-grouped

`swift/Sources/iMessageMax/Tools/GetMessages.swift:240`:

```swift
        guard chatId != nil || participants != nil else {
            throw ToolError.invalidInput("Provide chat_id or participants")
        }
```

and the cursor is a `date:rowid` pair produced by `TimelineCursor`
(`GetMessagesInternals.swift:658-661`), with `queryMessages` ordering
`m.date DESC, m.ROWID DESC` (`GetMessagesInternals.swift:419-524`, select
list below). Adding a `since_rowid` mode to this tool would mean a third
cursor format, a second sort order, and an escape hatch from the
chat_id/participants requirement, all inside a 487-line file. **Decision:
ship a separate `get_messages_since` tool** and reuse the internals.

The `queryMessages` select list and `MessageRow` shape to reuse
(`GetMessagesInternals.swift:200-213` and `:419-450`):

```swift
struct MessageRow {
    let id: Int
    let guid: String
    let text: String?
    let date: Int64?
    let isFromMe: Bool
    let senderHandle: String?
    let itemType: Int
    let groupActionType: Int
    let groupTitle: String?
    let otherHandle: String?
    let threadOriginatorGuid: String?
    let dateEdited: Int64
}
```

```swift
            .select(
                "m.ROWID as id", "m.guid", "m.text", "m.attributedBody", "m.date",
                "m.is_from_me", "h.id as sender_handle", "m.item_type",
                "m.group_action_type", "m.group_title", "oh.id as other_handle_id",
                "m.thread_originator_guid", "m.date_edited"
            )
            .from("message m")
            .join("chat_message_join cmj ON m.ROWID = cmj.message_id")
            .leftJoin("handle h ON m.handle_id = h.ROWID")
            .leftJoin("handle oh ON m.other_handle = oh.ROWID")
            .where("m.associated_message_type = 0")
```

Annotation helpers already batched per page, all callable from a new tool
(`GetMessagesInternals.swift`):

```swift
// :11
static func reactionsMap(db: Database, messageGuids: [String]) throws -> [String: [Reaction]]
// :92
static func replyLookup(db: Database, pageGuids: [String], pageIdByGuid: [String: Int], originatorGuids: [String]) throws -> ReplyLookup
// :177
static func render(_ rows: [Reaction], reactorName: (String?) -> String) -> [String]?
// :530 (instance method on GetMessagesTool)
func getAttachmentsMap(messageIds: [Int]) throws -> [Int: [AttachmentRow]]
// :566 (instance method on GetMessagesTool)
func extractLinks(from text: String) -> [String]
```

`getAttachmentsMap` and `extractLinks` are instance methods of
`GetMessagesTool`; step 2 lifts them to `static` (or a small
`MessageQueryHelpers` enum) so `GetMessagesSinceTool` can call them without
instantiating `GetMessagesTool`. Text rendering for rows with `NULL text`
goes through the same `attributedBody` path `get_messages` uses at
`GetMessages.swift:329-439` (find the call that turns `attributedBody` into
`text`; it is `MessageTextExtractor`, reuse it verbatim).

### `get_unread` already has the cross-chat message shape

`swift/Sources/iMessageMax/Tools/GetUnread.swift:37-44`:

```swift
    struct UnreadMessageItem: Codable {
        let id: String
        let chat: ChatReference
        let from: String
        let text: String?
        let ago: String
        let ts: String
    }
```

with `ChatReference` at `Models/ResponsePrimitives.swift:19-22`
(`let id: String; let name: String`), the `limit + 1` / `more` pattern at
`GetUnread.swift:268`, and the plan-074 predicate at `:259-261`:

```swift
        if !includeFiltered {
            queryBuilder = queryBuilder.where("c.is_filtered = 0")
        }
```

### Tool registration and the 12-tool count

`swift/Sources/iMessageMax/Server/ToolRegistry.swift:40-57` registers the
twelve tools; `GetMessagesTool.register` is line 49. Sites that pin the
count or the sorted name list, all of which must move to 13:

- `swift/Tests/iMessageMaxTests/ToolRegistryTests.swift:15-30` (sorted names)
- `swift/Tests/iMessageMaxTests/ToolRegistryBindingTests.swift:60`
  (`getTools().count, 12`)
- `swift/Tests/iMessageMaxTests/HTTPTransportIntegrationTests.swift:60`
  (`XCTAssertEqual(tools.count, 12)`)
- `README.md:25` ("12 tools"), `AGENTS.md:119` ("12 MCP tools across 16
  files") and `AGENTS.md:226` ("Twelve core tools" table)
- `docs/validation/2026-04-09-release-checklist.md:35`
  ("`tools/list` returns 12 tools")

### Diagnose hard-codes `live_inbox: unavailable`

`swift/Sources/iMessageMax/Tools/Diagnose.swift:107-112` and `:271-295`:

```swift
    func execute(
        resolver: ContactResolver,
        dbProbe: ...,
        contactsProbe: ...,
        automationProbe: ...
    ) async throws -> [Tool.Content] {
```

```swift
            "live_inbox": Capability(state: "unavailable"),
```

`swift/Tests/iMessageMaxTests/CapabilityContractTests.swift:68` asserts
`live_inbox == "unavailable"` and `:124-145` pins the 15-key capability
set; `ResponseContractTests.swift:236` carries a diagnose fixture.

### Server-initiated notifications: what exists today

Per-session SDK `Server` on the legacy lane
(`Server/SessionManager.swift:148-157`):

```swift
        let server = Server(
            name: Version.name,
            version: Version.current,
            title: Version.title,
            instructions: Version.instructions,
            capabilities: Version.serverCapabilities
        )
        await ToolRegistry.registerAll(on: server, db: database, resolver: resolver)
```

Its transport adapter forwards anything the `Server` sends
(`SessionManager.swift:363-366`):

```swift
    func send(_ data: Data) async throws {
        guard isConnected else { return }
        await responseHandler(IconMetadata.injectServerIcons(into: data))
    }
```

`HTTPTransport.handleServerResponse` (`Server/HTTPTransport.swift:647-679`)
routes a payload with a pending request id back to its POST; anything else
(a notification has no `id`) is broadcast on the session's open SSE GET
stream as `event: message` via `SSEConnectionManager.broadcast`
(`Server/SSEConnection.swift:164-169`):

```swift
    func broadcast(sessionId: String, event: String) {
        guard let connectionIds = sessionConnections[sessionId] else { return }
        for connectionId in connectionIds {
            channels[connectionId]?.send(event)
        }
    }
```

so a notification for a session with no open GET is dropped silently,
which is the behavior we want. swift-sdk 0.12.1
(`swift/.build/checkouts/swift-sdk/Sources/MCP/Server/Server.swift:379-390`
and `Base/Messages.swift:300-330`):

```swift
public func notify<N: Notification>(_ notification: Message<N>) async throws
```

```swift
public protocol Notification: Hashable, Codable, Sendable {
    associatedtype Parameters: Hashable, Codable, Sendable = Empty
    static var name: String { get }
}
public struct Message<N: Notification>: Hashable, Codable, Sendable {
    public let method: String
    public let params: N.Parameters
    public init(method: String, params: N.Parameters)
}
```

`SessionManagerTests.testTerminateStopsServer` already calls
`session.server.notify(Message<InitializedNotification>(method:params:))`,
proving the call compiles against a session server. `activeSessionIds()`
(`SessionManager.swift:260`) enumerates sessions. The modern stateless lane
(`Server/ModernProtocol.swift`) has no session and no stream; it cannot
receive notifications and must poll `get_messages_since`. `IconMetadata.
injectServerIcons` only rewrites payloads that carry `result.protocolVersion`,
so it is a no-op for notifications.

Timer primitives allowed in Sources: `AsyncTimeout.sleep(_ duration:)`
(`Utilities/AsyncTimeout.swift:15`, Dispatch-backed, cancellation-safe) and
Dispatch sources. `SessionManager.startCleanupTask` (`:280-288`) is the
canonical periodic loop:

```swift
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                await AsyncTimeout.sleep(interval)
                await self?.cleanupExpiredSessions()
            }
        }
```

HTTP mode startup (`iMessageMaxCommand.swift:31-64`) builds `Database()`,
`ContactResolver()`, `HTTPTransport(host:port:database:resolver:)`, calls
`transport.connect()`, then `waitForTermination()`. That is where the
watcher is started in layer 2.

### Test fixture

`swift/Tests/iMessageMaxTests/ToolTestSupport.swift` provides
`ToolTestDatabase(name:)` (a real sqlite file under
`FileManager.default.temporaryDirectory`, deleted in `deinit`), with
`insertHandle`, `insertChat(rowId:guid:displayName:serviceName:isFiltered:)`,
`joinChatHandle`, `insertMessage(rowId:guid:text:date:isFromMe:...)`,
`joinChatMessage(chatId:messageId:)`, `execute(_ sql:)`, `path`, and
`database() -> Database`. `makeSeededResolver()` maps `+15550000001` to
Alice Smith, `...02` Bob Brown, `...03` Chris Green.
`decodeJSONDictionary(from: [Tool.Content])` and `decodeJSONArray` decode
tool output. `GetMessagesToolTests.makeGetMessagesFixture()` (`:587`) uses
base date `1_000_000_000_000` and reaction rows 400–402 with types
2000/2006/2007; copy that shape.

## Reference: what imsg does (inlined; the executor cannot see the clone)

imsg `Sources/IMsgCore/MessageStore+MessagesAfter.swift` (paraphrased,
Swift):

```swift
struct MessagesAfterPage { let messages: [Message]; let nextRowID: Int; let hasMore: Bool }

func messagesAfterPage(sinceRowID: Int, chatID: Int?, limit: Int, includeReactions: Bool) throws -> MessagesAfterPage {
    let physicalLimit = limit + 1
    let rows = try scan(sinceRowID: sinceRowID, chatID: chatID, limit: physicalLimit, includeReactions: includeReactions)
    var messages: [Message] = []
    var consumedRowID = sinceRowID
    for row in rows {
        if messages.count == limit { return MessagesAfterPage(messages: messages, nextRowID: consumedRowID, hasMore: true) }
        consumedRowID = row.rowID          // every physical row consumed advances the cursor
        if let message = yield(row) { messages.append(message) }
    }
    return MessagesAfterPage(messages: messages, nextRowID: consumedRowID, hasMore: false)
}
```

SQL (`MessagesAfterQuery`):

```sql
SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.date, m.is_from_me,
       m.handle_id, h.id AS sender, cmj.chat_id, m.associated_message_type, ...
FROM message m
LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
LEFT JOIN handle h ON m.handle_id = h.ROWID
WHERE m.ROWID > ?
  [AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000 OR m.associated_message_type > 3006)]
  [AND cmj.chat_id = ?]
ORDER BY m.ROWID ASC
LIMIT ?
```

`docs/rpc.md` for `messages.after`: `since_rowid` is exclusive; `limit`
default 100, max 500; result `{messages, next_rowid, has_more}`;
"`next_rowid` is the authoritative physical scan cursor and may advance past
the final returned message"; cursors are scoped to one database instance.

`MessageWatcher.swift` (the parts that matter):

```swift
final class MessageWatcher {
    private let unresolvedChatRetryLimit = 20
    private let queue = DispatchQueue(label: "imsg.watch")
    private var watchedFilePaths: [String] { [path, path + "-wal", path + "-shm"] }
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var identities: [String: FileWatchIdentity] = [:]   // (st_dev, st_ino)

    private func refreshFileSources() {
        for filePath in watchedFilePaths {
            let identity = FileWatchIdentity(path: filePath)  // stat(); nil when the file is absent
            if identities[filePath] == identity { continue }
            sources[filePath]?.cancel()
            sources[filePath] = identity.flatMap { _ in makeSource(path: filePath) }
            identities[filePath] = identity
        }
    }

    private func makeSource(path: String) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in self?.refreshFileSources(); self?.schedulePoll() }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    // Debounce: one poll per debounceInterval no matter how many events land.
    private func schedulePoll() {
        guard !pending else { return }
        pending = true
        queue.asyncAfter(deadline: .now() + debounceInterval) { [weak self] in
            self?.pending = false; self?.poll()
        }
    }

    // Always-on fallback: poll every 5 s and re-check file identities,
    // because kqueue misses writes when the WAL is rotated or when Messages
    // checkpoints through a path we are not watching.
    private func scheduleFallbackPoll() { ... every 5 s: refreshFileSources(); poll() ... }

    private func poll() {
        let batch = try store.messagesAfter(rowID: cursor, ...)
        cursor = max(cursor, batch.maxScannedRowID)
        for row in batch.rows { yieldDecision(row) }   // chatID <= 0: retry up to 20 polls, then skip
    }
}
```

`docs/watch.md`: kqueue on `chat.db`, `chat.db-wal`, `chat.db-shm`, plus
the containing directory; an always-on fallback poll that refreshes the
file watches; `watch.subscribe` debounce 500 ms (RPC) / 250 ms (CLI). imsg
also warns that a cancelled `asyncAfter` work item still occupies the queue
until its deadline, which this repo already hit (`SessionManager.swift:91-93`);
use `DispatchSourceTimer` instead, which can be cancelled for real.

`MessageStore.maxRowID()` is `SELECT MAX(ROWID) FROM message`.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `cd swift && swift build` | `Build complete!` |
| Full suite | `cd swift && swift test` | `Executed N tests, with 0 failures` (N ≥ 433 + new) |
| One test class | `cd swift && swift test --filter GetMessagesSinceToolTests` | all pass |
| Launchd safety | `cd swift && swift test --filter LaunchdSafetyTests` | pass |
| Tool count | `cd swift && swift test --filter 'ToolRegistryTests\|ToolRegistryBindingTests\|HTTPTransportIntegrationTests'` | pass |
| Live max rowid (read-only) | `sqlite3 -readonly ~/Library/Messages/chat.db "SELECT MAX(ROWID) FROM message;"` | an integer ≥ 234006 |
| Live smoke (layer 1) | `swift/.build/debug/imessage-max --help` then an MCP call; see step 8 | messages after the cursor |

## Scope

**In:**

- New tool `get_messages_since` in
  `swift/Sources/iMessageMax/Tools/GetMessagesSince.swift` (+ tests in
  `swift/Tests/iMessageMaxTests/GetMessagesSinceToolTests.swift`).
- Lifting `getAttachmentsMap` / `extractLinks` to static helpers so two
  tools share them (no behavior change to `get_messages`).
- Fixture: `ToolTestDatabase.insertMessage` gains `balloonBundleId:` and the
  `message` table gains `balloon_bundle_id TEXT` (needed so the select list
  that includes the column does not fail against the fixture).
- Registration, tool-count tests, README, AGENTS.md, SKILL.md, release
  checklist, CHANGELOG.
- Layer 2 (optional): `swift/Sources/iMessageMax/Server/MessageWatcher.swift`,
  `SessionManager.notifyAllSessions`, `HTTPTransport` wiring,
  `iMessageMaxCommand` startup, `Diagnose` `live_inbox` state, the
  `NewMessagesNotification` type, and tests.

**Out:**

- URL-balloon dedupe (0 live duplicates; Maintenance note).
- Notifications on the modern stateless lane (impossible by design; those
  clients poll).
- Notifications on the stdio lane (`MCPServerWrapper`). Easy to add later
  through the same `NewMessagesNotification` type; not in this plan to keep
  layer 2 bounded.
- `resources/subscribe`, `listen`, or any MCP resources capability.
- Any change to `get_messages` output or cursor format.
- Marking messages read, or any write to `chat.db`.

## Git workflow

```bash
git checkout main && git pull --ff-only
git checkout -b advisor/080-live-inbox
```

Commits, in order (conventional commits; one per step group):

1. `test: fixture gains balloon_bundle_id and a get_messages_since test file` (step 1)
2. `refactor: lift attachment and link helpers off GetMessagesTool` (step 2)
3. `feat: add get_messages_since ROWID cursor tool` (steps 3–5)
4. `test: move tool-count assertions to 13` (step 6)
5. `docs: document get_messages_since` (step 7)
6. (layer 2) `feat: MessageWatcher kqueue + fallback poll on chat.db` (steps 9–10)
7. (layer 2) `feat: push notifications/imessage/new_messages to SSE sessions` (steps 11–12)
8. (layer 2) `feat: diagnose reports live_inbox supported when the watcher runs` (step 13)
9. `docs: plans/README.md row for 080` (final)

## Steps

### Layer 1 — `get_messages_since`

#### Step 1: Fixture support and a failing test file

Edit `swift/Tests/iMessageMaxTests/ToolTestSupport.swift`:

- In the `message` CREATE TABLE (`:156-176`) add `balloon_bundle_id TEXT`
  after `date_edited INTEGER DEFAULT 0`.
- In `insertMessage` add parameter `balloonBundleId: String? = nil` after
  `dateEdited: Int64 = 0`, bind it as `\(balloonValue)` in both the column
  list and the VALUES list (same pattern as `groupTitleValue`).

Create `swift/Tests/iMessageMaxTests/GetMessagesSinceToolTests.swift` with
one fixture builder and the first test. Fixture (base date `let base:
Int64 = 1_000_000_000_000`, all dates `base + rowid * 1_000_000_000` so
they are strictly increasing and, importantly, far in the past relative to
`Date()` so the unresolved-grace tests below can treat them as "old"):

| rowid | chat | kind | notes |
|---|---|---|---|
| 100 | 1 (Alice DM, `is_filtered 0`) | text "one" from handle 1 | |
| 101 | 1 | text "two" is_from_me | |
| 102 | 1 | reaction `associated_message_type 2000` on 100 | must be skipped |
| 103 | 2 (group "Weekend", `is_filtered 0`, handles 1,2) | text "three" from handle 2 | |
| 104 | 3 (`is_filtered 1`, guid `SMS;-;90210`) | text "junk" from handle 3 | hidden by default |
| 105 | none | text "orphan" from handle 1, **no** `chat_message_join` | unresolved |
| 106 | 2 | text "four" from handle 1 | |
| 107 | 1 | `balloon_bundle_id = "com.apple.messages.URLBalloonProvider"`, text "https://example.com" | returned as a normal message |

First test:

```swift
func testReturnsMessagesAfterCursorInRowidOrder() async throws {
    let fixture = try makeSinceFixture()
    let tool = GetMessagesSinceTool(db: fixture.database(), resolver: makeSeededResolver())
    let result = try await tool.execute(args: ["since_rowid": .int(100), "limit": .int(50)])
    let json = try decodeJSONDictionary(from: result)
    let messages = try decodeJSONArray(json["messages"])
    XCTAssertEqual(messages.map { $0["id"] as? String }, ["msg_101", "msg_103", "msg_106", "msg_107"])
    XCTAssertEqual(json["has_more"] as? Bool, false)
}
```

(102 is a reaction, 104 is in a filtered chat, 105 is an orphan older than
the grace window: all three are consumed, none returned. Step 5 covers the
young-orphan case.)

**Verify:**

```bash
cd swift && swift build --build-tests 2>&1 | grep -E "error: cannot find 'GetMessagesSinceTool'" | head -1
```

Expected: one line naming `GetMessagesSinceTool` (the test fails to compile
because the tool does not exist yet). Commit the fixture change and the test
file together.

#### Step 2: Lift shared helpers

In `swift/Sources/iMessageMax/Tools/GetMessagesInternals.swift`, change
`func getAttachmentsMap(messageIds:)` (`:530`) and `func extractLinks(from:)`
(`:566`) so they are callable without a `GetMessagesTool` instance. The
least disruptive way: add

```swift
enum MessageQueryHelpers {
    static func attachmentsMap(db: Database, messageIds: [Int]) throws -> [Int: [AttachmentRow]] { /* body moved here */ }
    static func extractLinks(from text: String) -> [String] { /* body moved here */ }
}
```

and turn the two instance methods into one-line forwarders so
`GetMessages.swift` does not change. Also confirm how `GetMessages.swift`
turns `attributedBody` into text when `m.text` is NULL (grep for
`MessageTextExtractor` in `GetMessagesInternals.swift`); note the exact
call, you will reuse it in step 3.

**Verify:**

```bash
cd swift && swift build && swift test --filter GetMessagesToolTests 2>&1 | tail -1
```

Expected: `Executed <n> tests, with 0 failures` and no diff in behavior.

#### Step 3: The tool — schema, response type, registration

Create `swift/Sources/iMessageMax/Tools/GetMessagesSince.swift`. Mirror the
structure of `GetMessages.swift` (`actor`, `static func register`,
`execute(args:)` wrapping `ToolError`, `executeImpl`). Contract:

**Input** (`InputSchema.object(properties:)`, same helpers as
`GetMessages.swift:144-196`):

| name | type | required | meaning |
|---|---|---|---|
| `since_rowid` | integer | no | exclusive cursor. Omit it (or pass `-1`) to get **no messages and the current cursor**: `messages: []`, `next_rowid = MAX(ROWID)`, `has_more: false`. This is the "start from now" helper; no separate tool. |
| `chat_id` | string | no | `123` or `chat123` via `ChatIdentifier.parseRowId` (`Utilities/ChatIdentifier.swift:5`); a non-numeric value is `ToolError.invalidInput`. Restricts to one chat. |
| `limit` | integer | no | default 100, clamp 1…500. |
| `include_filtered` | boolean | no | default false; true includes `is_filtered != 0` chats (plan 074 semantics). |
| `include_reactions` | boolean | no | default true; attaches reaction strings to returned messages (never returns reaction rows themselves). |

**Output** (`OutputSchema.object`, Codable struct):

```swift
struct GetMessagesSinceResponse: Codable {
    struct Item: Codable {
        let id: String            // "msg_<rowid>"
        let rowid: Int            // raw cursor value for this row
        let chat: ChatReference   // id "chat<rowid>", name via ChatIdentity (same producer as get_unread)
        let from: String          // "me", contact name, or formatted handle (IdentityDisplayFormatter.displayName)
        let text: String?
        let ts: String            // TimeUtils.formatISO
        let reactions: [String]?  // same rendering as get_messages
        let attachments: [...]?   // same shape as get_messages MessageInfo.attachments
        let links: [String]?
        let reply_to: String?
        let reply_count: Int?
        let edited: Bool?
        let event: ...?           // same typed event as get_messages for item_type != 0 (plan 073)
    }
    let since_rowid: Int
    let messages: [Item]
    let next_rowid: Int           // authoritative; pass back as since_rowid
    let has_more: Bool
    let current_rowid: Int        // MAX(ROWID) at scan start
    let stalled: Bool             // true when a young unresolved row blocked the cursor; retry after ~1 s
    let filtered_hidden: Int      // messages skipped because their chat is filtered (0 when include_filtered)
}
```

Reuse `MessageInfo`'s nested attachment/event types from
`GetMessages.swift:17-108` rather than redefining them (make them
non-private if needed). Order returned messages by `rowid` ascending.

Description text for the schema (agents read this): "Messages across all
chats with ROWID greater than since_rowid, in arrival order. Pass the
returned next_rowid back as since_rowid to page or poll. next_rowid may be
larger than the last returned message's rowid because consumed rows
(reactions, filtered chats, orphans) advance it. Omit since_rowid to get
only the current cursor. Cursors are only valid against this Mac's
chat.db."

Register in `swift/Sources/iMessageMax/Server/ToolRegistry.swift` right
after line 49 (`GetMessagesTool.register`), and add the name to whatever
sorted-name or catalog list `ToolRegistry` keeps (read the file; if it has
a static `names` array, add `"get_messages_since"` in sorted position).

**Verify:**

```bash
cd swift && swift build 2>&1 | tail -1
```

Expected: `Build complete!`. (Tests still fail; the query comes next.)

#### Step 4: The scan query and cursor arithmetic

Inside `executeImpl`:

1. `let currentRowid = try db.query("SELECT COALESCE(MAX(ROWID), 0) FROM message") { $0.int(0) }.first ?? 0`.
2. If `since_rowid` is absent or `< 0`: return `since_rowid: currentRowid,
   messages: [], next_rowid: currentRowid, has_more: false, current_rowid:
   currentRowid, stalled: false, filtered_hidden: 0`.
3. Otherwise build the scan with `QueryBuilder` (same API as
   `GetUnread.swift:243-266`). Written out as SQL so the intent is
   unambiguous:

```sql
SELECT m.ROWID AS id, m.guid, m.text, m.attributedBody, m.date, m.is_from_me,
       h.id AS sender_handle, m.item_type, m.group_action_type, m.group_title,
       oh.id AS other_handle_id, m.thread_originator_guid, m.date_edited,
       (SELECT MIN(cmj.chat_id) FROM chat_message_join cmj WHERE cmj.message_id = m.ROWID) AS chat_id,
       c.display_name AS chat_display_name,
       c.is_filtered AS chat_is_filtered
FROM message m
LEFT JOIN handle h ON m.handle_id = h.ROWID
LEFT JOIN handle oh ON m.other_handle = oh.ROWID
LEFT JOIN chat c ON c.ROWID = (SELECT MIN(cmj2.chat_id) FROM chat_message_join cmj2 WHERE cmj2.message_id = m.ROWID)
WHERE m.ROWID > ?              -- since_rowid
  AND m.ROWID <= ?             -- currentRowid, so the page is a closed range
  AND m.associated_message_type = 0
  [AND chat_id = ?]            -- chat filter, when given (use the subselect expression, not the alias, inside WHERE if SQLite rejects the alias)
ORDER BY m.ROWID ASC
LIMIT ?                        -- limit + 1
```

`MIN(chat_id)` collapses the 2 live messages joined to more than one chat
into one row instead of two. Do **not** put `c.is_filtered = 0` in SQL:
filtered rows must be *seen* so the cursor can consume them and
`filtered_hidden` can count them. Reactions stay excluded in SQL because
they are never returned and never need counting.

4. Walk the rows in order with `var consumed = sinceRowid`,
   `var items: [Row] = []`, `var stalled = false`, `var hidden = 0`:

```
for row in rows {
    if items.count == limit { hasMore = true; break }          // the +1 row is not consumed
    if row.chatId == nil {
        let age = Date().timeIntervalSince(AppleTime.toDate(row.date))
        if age < unresolvedJoinGrace {  // 30 s constant, `static let unresolvedJoinGrace: TimeInterval = 30`
            stalled = true; hasMore = true; break               // do NOT advance past it
        }
        consumed = row.id; continue                             // permanent orphan: skip and consume
    }
    consumed = row.id
    if !includeFiltered && row.chatIsFiltered != 0 { hidden += 1; continue }
    items.append(row)
}
nextRowid = hasMore ? consumed : currentRowid
```

Why `nextRowid = currentRowid` when the page is not full: every row in
`(consumed, currentRowid]` was either returned, consumed, or excluded by
the SQL reaction predicate, so jumping to `currentRowid` is safe and stops
a poller from re-scanning trailing reaction rows forever. When `stalled`
is true, `hasMore` is true and `next_rowid` is the last consumed rowid
(possibly equal to `since_rowid`), which tells the caller "wait, then call
again with the same cursor".

Orphan rows with a **NULL date** (imsg saw these): treat as old (skip and
consume).

5. Annotate the kept rows using the helpers: `MessageAnnotations.reactionsMap`
   (only when `include_reactions`), `MessageAnnotations.replyLookup`,
   `MessageQueryHelpers.attachmentsMap`, `MessageQueryHelpers.extractLinks`,
   the `MessageTextExtractor` call from step 2 for NULL text, and the plan
   073 event mapping for `item_type != 0` (copy the branch from
   `GetMessages.swift` that builds `event`). Resolve `from` with
   `IdentityDisplayFormatter.displayName(handle:resolver:)`
   (`Utilities/IdentityDisplayFormatter.swift:16`); resolve chat names the
   way `get_unread` does (look at how it builds `ChatReference.name` from
   `chat_display_name` plus participants; reuse
   `ChatSummaryQueries.participantsByChat(db:chatIds:resolver:)`
   (`Utilities/ChatSummaryQueries.swift:28`) once per page, not per row).
6. Encode with `FormatUtils.encodeJSON` like the other tools.

**Verify:**

```bash
cd swift && swift test --filter GetMessagesSinceToolTests 2>&1 | tail -1
```

Expected: `Executed 1 test, with 0 failures`.

#### Step 5: The remaining cursor-semantics tests

Add to `GetMessagesSinceToolTests.swift` (each must be red before the
matching code exists; most will pass immediately after step 4, which is
fine, but run them individually and confirm they exercise the branch by
temporarily breaking the code once if unsure):

1. `testOmittedCursorReturnsCurrentRowidOnly`: no `since_rowid`; expect
   `messages == []`, `next_rowid == 107`, `current_rowid == 107`,
   `has_more == false`.
2. `testReactionRowsAreNeverReturnedButReactionsAreAttached`: `since_rowid
   99`; `msg_100` has `reactions == ["👍 Alice Smith"]`-style entry (match
   the exact token `get_messages` uses for type 2000, see
   `ReactionType.emoji`); no item has `id == "msg_102"`.
3. `testFilteredChatRowsAreConsumedAndCounted`: `since_rowid 103, limit 1`;
   104 is filtered and consumed, 105 is an old orphan and consumed, 106 is
   returned. With `limit 1` the page holds
   `["msg_106"]`, `filtered_hidden == 1`, `has_more == true`, and
   `next_rowid == 106`. Then `since_rowid 106` returns `["msg_107"]`,
   `has_more == false`, `next_rowid == 107`.
4. `testIncludeFilteredReturnsJunkChat`: `since_rowid 103, include_filtered
   true`; `msg_104` present with `chat.id == "chat3"`, `filtered_hidden == 0`.
5. `testNextRowidAdvancesPastConsumedTrailingRows`: insert reaction row
   108 (type 2000 on 107) and a filtered-chat row 109 (chat 3). `since_rowid
   106` returns `["msg_107"]` and `next_rowid == 109` (not 107), `has_more
   == false`.
6. `testLimitPlusOneDoesNotConsumeTheOverflowRow`: `since_rowid 99, limit
   2`; returns `["msg_100", "msg_101"]`, `has_more == true`, `next_rowid ==
   101` (102 was **not** consumed because the loop broke before reading it).
7. `testYoungUnresolvedRowStallsTheCursor`: insert row 110 with **no**
   join and `date: AppleTime.fromDate(Date())`. `since_rowid 107` returns
   `messages == []`, `stalled == true`, `has_more == true`, `next_rowid ==
   107`.
8. `testOldUnresolvedRowIsSkippedAndConsumed`: `since_rowid 104` returns
   `["msg_106", "msg_107"]` and `next_rowid == 107`; no item is `msg_105`.
9. `testChatFilterRestrictsAndStillAdvances`: `since_rowid 99, chat_id
   "chat2"` returns `["msg_103", "msg_106"]`, `next_rowid == 107`
   (`currentRowid`, because the page was not full).
10. `testInvalidChatIdIsInvalidInput`: `chat_id "nope"` throws
    `ToolError.invalidInput` (match how `GetMessagesToolTests` asserts the
    error kind).
11. `testLimitIsClamped`: `limit 0` behaves as 1, `limit 9999` as 500
    (assert via a fixture of 501 tiny rows only if cheap; otherwise assert
    the clamp helper directly).
12. `testQueryCountIsBounded`: using `Database.queryCountForTesting` the
    way `GetMessagesToolTests` does, assert the tool issues a fixed number
    of queries for a 5-message page (max rowid + scan + reactions + reply
    originators + reply counts + attachments + participants = 7; pin the
    number you measure, and explain it in a comment).

**Verify:**

```bash
cd swift && swift test --filter GetMessagesSinceToolTests 2>&1 | tail -1
```

Expected: `Executed 13 tests, with 0 failures`. Commit steps 3–5.

#### Step 6: Move the tool count to 13

- `ToolRegistryTests.swift:15-30`: insert `"get_messages_since"` in sorted
  position (after `"get_messages"`).
- `ToolRegistryBindingTests.swift:60`: `12` → `13`.
- `HTTPTransportIntegrationTests.swift:60`: `12` → `13`.
- Search for any other `12` pinned to tool count:
  `grep -rn "count, 12\|== 12\|12 tools" swift/Tests README.md AGENTS.md docs`.

**Verify:**

```bash
cd swift && swift test 2>&1 | tail -1
```

Expected: `Executed 446 tests, with 0 failures` (433 + 13). Commit.

#### Step 7: Docs

- `README.md`: `:25` "12 tools" → "13 tools". Add a `### get_messages_since`
  section directly after `### get_messages` (`:244`) using the same layout
  as the neighbors: purpose, parameters table, example request, example
  response (copy the JSON shape from step 3 with two messages), and a
  "Polling recipe" paragraph: call once without `since_rowid`, store
  `next_rowid`, then call with it on whatever cadence; when `stalled` is
  true wait about one second and retry with the same cursor; never compare
  `next_rowid` to message ids.
- `AGENTS.md:119` count and `:226` "Twelve core tools" table: add a row for
  `get_messages_since` and fix the count words.
- `using-imessage-max/SKILL.md`: in the tool selection list (`:80-91`) add
  "Keeping up with new messages across all chats → `get_messages_since`
  (store `next_rowid`)". In the catch-up flow (`:26-36`) add one line:
  "If you already hold a `next_rowid` from a previous turn, call
  `get_messages_since` with it instead of `get_unread`." Check
  `using-imessage-max/references/workflows.md` for a catch-up workflow and
  mirror the same sentence if one exists.
- `docs/validation/2026-04-09-release-checklist.md:35`: 12 → 13.
- `CHANGELOG.md`: add a `## Unreleased` heading above `## 1.6.0` with
  `### Added` `- get_messages_since: ROWID-cursor pull of new messages
  across chats (plan 080).`

**Verify:**

```bash
grep -n "get_messages_since" README.md AGENTS.md using-imessage-max/SKILL.md CHANGELOG.md docs/validation/2026-04-09-release-checklist.md | wc -l
```

Expected: a number ≥ 6. Also `grep -rn "12 tools\|Twelve core" README.md AGENTS.md docs` returns nothing. Commit.

#### Step 8: Live smoke (read-only, manual)

Build and run the HTTP server on a spare port, initialize a session, call
the tool twice. Use the curl recipe from
`docs/validation/2026-04-09-release-checklist.md` for `initialize` and
`tools/call`. First call with no `since_rowid`: expect `next_rowid` equal
to `sqlite3 -readonly ~/Library/Messages/chat.db "SELECT MAX(ROWID) FROM
message;"`. Then call with `since_rowid` set to that value minus 50: expect
messages in ascending rowid order, no reactions as items, `filtered_hidden
≥ 0`, and `next_rowid == current_rowid`. Record the two numbers in the
plans/README.md row (step 14).

**Verify:** the second response's `messages` are ascending by `rowid` and
`next_rowid == current_rowid`. Layer 1 is complete here.

### Layer 2 — watcher and push notification (optional; gate: step 8 done and committed)

#### Step 9: `MessageWatcher` with a failing test

Create `swift/Sources/iMessageMax/Server/MessageWatcher.swift`:

```swift
import Foundation

/// Watches chat.db (and its -wal/-shm siblings and directory) with kqueue
/// through DispatchSource, debounces to one poll per `debounce`, and always
/// runs a fallback poll every `fallbackInterval` that also re-checks file
/// identities (st_dev, st_ino) and re-registers sources after rotation.
/// Fires `onNewRows(maxRowid)` when SELECT MAX(ROWID) FROM message grows.
/// No Task.sleep: all timing is DispatchSourceTimer on a private queue.
final class MessageWatcher: @unchecked Sendable {
    struct FileIdentity: Equatable { let device: UInt64; let inode: UInt64 }

    init(databasePath: String,
         debounce: DispatchTimeInterval = .milliseconds(250),
         fallbackInterval: DispatchTimeInterval = .seconds(5),
         onNewRows: @escaping @Sendable (Int64) -> Void)

    func start() throws     // seeds lastMax from MAX(ROWID), registers sources, arms the fallback timer
    func stop()             // cancels every source and timer; safe to call twice
    var isRunning: Bool     // read under the queue (sync)
    func watchedIdentitiesForTesting() -> [String: FileIdentity?]
    func pollNowForTesting()
}
```

Implementation rules:

- Private serial `DispatchQueue(label: "imessage-max.watcher")`; all state
  mutated on it.
- `watchedPaths = [path, path + "-wal", path + "-shm"]` plus the parent
  directory. Directory source uses the same event mask; its handler only
  calls `refreshFileSources()` then `schedulePoll()`.
- `makeSource`: `open(path, O_EVTONLY)`; on failure return nil (file may
  not exist yet, the -wal often appears only after the first write);
  `DispatchSource.makeFileSystemObjectSource(fileDescriptor:eventMask:
  [.write, .extend, .rename, .delete], queue:)`; cancel handler `close(fd)`.
- `refreshFileSources()`: `stat` each path; compare `FileIdentity`; when it
  differs, cancel the old source and create a new one; when the file is
  gone, cancel and store nil.
- Debounce: one `DispatchSourceTimer` (`debounceTimer`) created lazily;
  `schedulePoll()` calls `debounceTimer.schedule(deadline: .now() +
  debounce)`; the timer's handler runs `poll()`. Rescheduling a
  DispatchSourceTimer replaces its deadline, so a burst of events yields one
  poll.
- Fallback: a repeating `DispatchSourceTimer` at `fallbackInterval` whose
  handler runs `refreshFileSources(); poll()`.
- `poll()`: open a fresh read-only `Database(path:)` query for `MAX(ROWID)`
  (same `Database.query` API the tools use; `Database` opens a fresh
  connection per query, so no long-lived handle); if `> lastMax`, set
  `lastMax` and call `onNewRows(lastMax)`. Swallow and `Log.warning` query
  errors (the db can be mid-checkpoint); never crash the service.
- `stop()` cancels timers and sources and sets `isRunning = false`.

Create `swift/Tests/iMessageMaxTests/MessageWatcherTests.swift`. Use
`ToolTestDatabase` (a real file) and switch it to WAL so the sibling files
exist: `try fixture.execute("PRAGMA journal_mode=WAL;")`. Helper: wait for
a condition with a bounded Dispatch-backed loop, never `Task.sleep`:

```swift
private func waitUntil(_ timeout: Duration = .seconds(3), _ condition: @escaping @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        await AsyncTimeout.sleep(.milliseconds(50))
    }
    return condition()
}
```

Tests:

1. `testFiresWhenARowIsInserted`: start watcher with a `Mutex<[Int64]>`
   collector; `insertMessage(rowId: 5, ...)`; `waitUntil { collected.last ==
   5 }` is true. `stop()`.
2. `testDebouncesABurstIntoOnePoll`: insert 20 rows in one `execute` batch;
   after the wait, the collector holds one value (20) or at most two, never
   twenty. Assert `collected.count <= 2`.
3. `testReregistersAfterWalRotation`: start; read
   `watchedIdentitiesForTesting()[path + "-wal"]`; run
   `PRAGMA wal_checkpoint(TRUNCATE);` then rename the -wal file aside with
   `FileManager.moveItem`, insert a row (SQLite recreates the -wal), then
   `pollNowForTesting()` and assert the identity for `-wal` changed and the
   insert was reported. If SQLite refuses the rename on this OS, skip that
   sub-assertion with `throw XCTSkip(...)` and keep the fire assertion; do
   not spend more than 30 minutes on it.
4. `testStopIsIdempotentAndLeavesNoTimers`: `start(); stop(); stop()`;
   `isRunning == false`; then insert a row and assert `waitUntil(.seconds(1))
   { !collected.isEmpty }` is **false**.
5. In `LaunchdSafetyTests` nothing changes, but run it: the new file must
   not contain `Task.sleep(`.

**Verify:**

```bash
cd swift && swift test --filter 'MessageWatcherTests|LaunchdSafetyTests' 2>&1 | tail -1
```

Expected: `Executed 5 tests, with 0 failures` (4 + the launchd scan, adjust
if the launchd class has more than one test).

#### Step 10: Start the watcher in HTTP mode

In `swift/Sources/iMessageMax/iMessageMaxCommand.swift:31-64` (HTTP branch),
after `transport.connect()`: build
`MessageWatcher(databasePath: Database.defaultPath, onNewRows: { rowid in
Task { await transport.notifyNewMessages(maxRowid: rowid) } })`, call
`try watcher.start()` inside `do/catch` that logs `Log.warning` and
continues without a watcher (never fail startup because of it), and call
`watcher.stop()` before returning from `waitForTermination()`. Keep a
strong reference for the lifetime of the command. `transport.notifyNewMessages`
is created in step 11; stub it as a no-op first so this compiles.

**Verify:**

```bash
cd swift && swift build 2>&1 | tail -1 && grep -n "MessageWatcher" Sources/iMessageMax/iMessageMaxCommand.swift | head -3
```

Expected: `Build complete!` and three lines (construction, start, stop).

#### Step 11: The notification type and the fan-out

Add to `swift/Sources/iMessageMax/Server/ServerExtensions.swift` (or a new
`Server/NewMessagesNotification.swift`):

```swift
import MCP

/// Server-initiated, one per watcher poll that saw growth. Carries the new
/// MAX(ROWID) so a client can call get_messages_since with its stored cursor.
struct NewMessagesNotification: MCP.Notification {
    static let name = "notifications/imessage/new_messages"
    struct Parameters: Hashable, Codable, Sendable {
        let max_rowid: Int64
    }
}
```

In `SessionManager` add:

```swift
    /// Sends `notification` to every live session. Errors are per-session
    /// and swallowed: a session whose Server has stopped just drops it.
    func notifyAllSessions<N: MCP.Notification>(_ notification: Message<N>) async -> Int {
        var delivered = 0
        for session in sessions.values {
            do { try await session.server.notify(notification); delivered += 1 }
            catch { Log.warning("notify \(N.name) to session \(session.id.prefix(8)) failed: \(error)") }
        }
        return delivered
    }
```

In `HTTPTransport` add:

```swift
    func notifyNewMessages(maxRowid: Int64) async {
        _ = await sessionManager.notifyAllSessions(
            Message<NewMessagesNotification>(
                method: NewMessagesNotification.name,
                params: .init(max_rowid: maxRowid)))
    }
```

Delivery path is already there: `Server.notify` → `SessionTransportAdapter
.send` → `handleServerResponse` (no id) → `sseManager.broadcast`. Sessions
with no open GET drop it inside `broadcast` (guard on
`sessionConnections[sessionId]`). Verify that `handleServerResponse` really
does fall through to broadcast for a payload without `id`; if it instead
logs and drops, add the broadcast branch there.

Test in `SessionManagerTests`:
`testNotifyAllSessionsReachesEverySessionResponseHandler`: create two
sessions, `setResponseHandler` collecting `(sessionId, data)` into a
`Mutex`-guarded array, call `notifyAllSessions`, assert the returned count
is 2 and each collected payload decodes to JSON with `method ==
"notifications/imessage/new_messages"` and `params.max_rowid == 42` and no
`id` key.

**Verify:**

```bash
cd swift && swift test --filter SessionManagerTests 2>&1 | tail -1
```

Expected: `Executed <n+1> tests, with 0 failures`.

#### Step 12: End-to-end over SSE

In `swift/Tests/iMessageMaxTests/HTTPTransportLiveSocketTests.swift`, add
`testNewMessagesNotificationReachesOpenSSEGet` using the existing
`withLiveTransport(channelIdleTimeout:body:)` helper and the raw-socket
pattern of `testSSEGetSurvivesChannelIdleTimeout` (`:37-95`): initialize
over POST, open the GET with `Accept: text/event-stream` and the session
id, `await AsyncTimeout.sleep(.milliseconds(200))` so the GET registers,
then `await transport.notifyNewMessages(maxRowid: 4242)`, then read from
the GET socket with a 2 s receive timeout until the buffer contains
`notifications/imessage/new_messages`. Assert it also contains
`"max_rowid":4242` and is framed as `event: message`.

Also assert the negative: a second session with **no** GET open receives
nothing and `notifyAllSessions` still returns 2 (delivery to the adapter
succeeded; the SSE layer dropped it). That proves the silent-drop path.

**Verify:**

```bash
cd swift && swift test --filter HTTPTransportLiveSocketTests 2>&1 | tail -1
```

Expected: `Executed <n+1> tests, with 0 failures`. Commit steps 9–12
(two commits as listed in Git workflow).

#### Step 13: Diagnose reports the watcher

Add a tiny shared state so `Diagnose` can see the watcher without
threading it through `ToolRegistry.registerAll`:

```swift
// Server/LiveInboxState.swift
import Synchronization
enum LiveInboxState {
    private static let running = Mutex(false)
    static func set(running value: Bool) { running.withLock { $0 = value } }
    static var isRunning: Bool { running.withLock { $0 } }
}
```

`MessageWatcher.start()` calls `LiveInboxState.set(running: true)`, `stop()`
sets false. `Diagnose.execute` gains `liveInboxProbe: @Sendable () -> Bool
= { LiveInboxState.isRunning }` and emits
`Capability(state: probe() ? "supported" : "unavailable")` at `:290`. Update
the description text at `:73-88` so "live-inbox operation" reads
"live inbox (push notifications when new messages land; `supported` only in
HTTP mode while the watcher runs)". Because the modern stateless lane still
cannot receive the push, add a `detail` string on the capability if
`Capability` has one (check `:271-295`): "notifications/imessage/new_messages
over the legacy session SSE stream; stateless clients poll
get_messages_since".

Tests: `CapabilityContractTests.swift:68` becomes two tests: default probe
(false) → `"unavailable"`; injected `{ true }` → `"supported"`. Key set at
`:124-145` unchanged (still 15 keys). `ResponseContractTests.swift:236`
fixture unchanged unless it asserts the string, in which case it stays
`unavailable` (default probe).

**Verify:**

```bash
cd swift && swift test 2>&1 | tail -1
```

Expected: `Executed <446 + layer-2 tests> tests, with 0 failures`. Commit.

#### Step 14: plans/README.md row and final full run

Add a row to the table in `plans/README.md` (after 078):

`| 080 | Live inbox: get_messages_since ROWID cursor tool; optional chat.db watcher pushing notifications/imessage/new_messages over SSE | P2 | M/L | none | <status> |`

with the status text stating which layer landed, the branch, the final
test count, and the two live smoke numbers from step 8.

**Verify:**

```bash
cd swift && swift build && swift test 2>&1 | tail -1
```

Expected: `... with 0 failures`.

## Test plan

| Test | File | Layer | Proves |
|---|---|---|---|
| `testReturnsMessagesAfterCursorInRowidOrder` | GetMessagesSinceToolTests | 1 | exclusive cursor, ASC order, consumed rows absent |
| `testOmittedCursorReturnsCurrentRowidOnly` | same | 1 | "start from now" helper |
| `testReactionRowsAreNeverReturnedButReactionsAreAttached` | same | 1 | reaction rows consumed, annotations reused |
| `testFilteredChatRowsAreConsumedAndCounted` | same | 1 | plan 074 semantics + `filtered_hidden` + cursor advance |
| `testIncludeFilteredReturnsJunkChat` | same | 1 | opt-in |
| `testNextRowidAdvancesPastConsumedTrailingRows` | same | 1 | `next_rowid` authority |
| `testLimitPlusOneDoesNotConsumeTheOverflowRow` | same | 1 | pagination boundary |
| `testYoungUnresolvedRowStallsTheCursor` | same | 1 | fail-closed on in-flight join |
| `testOldUnresolvedRowIsSkippedAndConsumed` | same | 1 | grace window, no permanent stall |
| `testChatFilterRestrictsAndStillAdvances` | same | 1 | `chat_id` |
| `testInvalidChatIdIsInvalidInput` | same | 1 | input hygiene (plan 063 style) |
| `testLimitIsClamped` | same | 1 | 1…500 |
| `testQueryCountIsBounded` | same | 1 | no per-row queries |
| ToolRegistry / Binding / Integration counts | existing files | 1 | 13 tools |
| `testFiresWhenARowIsInserted` | MessageWatcherTests | 2 | kqueue path works on a temp sqlite |
| `testDebouncesABurstIntoOnePoll` | same | 2 | 250 ms debounce |
| `testReregistersAfterWalRotation` | same | 2 | (st_dev, st_ino) re-registration |
| `testStopIsIdempotentAndLeavesNoTimers` | same | 2 | no lingering timer after stop |
| `testNotifyAllSessionsReachesEverySessionResponseHandler` | SessionManagerTests | 2 | fan-out and payload shape |
| `testNewMessagesNotificationReachesOpenSSEGet` | HTTPTransportLiveSocketTests | 2 | end-to-end SSE, silent drop without GET |
| Capability contract: default vs injected probe | CapabilityContractTests | 2 | `live_inbox` truthful |
| `LaunchdSafetyTests` | existing | both | no `Task.sleep` |

Full suite: `cd swift && swift build && swift test` — 0 failures, count
recorded in plans/README.md.

## Done criteria

Layer 1 (required):

- [ ] `swift/Sources/iMessageMax/Tools/GetMessagesSince.swift` exists and `tools/list` returns 13 tools including `get_messages_since`.
- [ ] `GetMessagesSinceToolTests` has 13 tests, all green.
- [ ] `grep -rn "Task.sleep(" swift/Sources` prints nothing and `LaunchdSafetyTests` passes.
- [ ] `grep -rn "12 tools\|count, 12\|Twelve core" README.md AGENTS.md swift/Tests docs` prints nothing.
- [ ] `get_messages` behavior unchanged: `GetMessagesToolTests` green with no test edits.
- [ ] README, AGENTS.md, SKILL.md, CHANGELOG (`## Unreleased`), release checklist updated.
- [ ] Live smoke: second call returns ascending rowids and `next_rowid == current_rowid`; numbers recorded in plans/README.md.
- [ ] `cd swift && swift build && swift test` → 0 failures, ≥ 446 tests.

Layer 2 (only if attempted):

- [ ] `MessageWatcherTests` green, including the WAL-rotation test or an explicit `XCTSkip` with the reason.
- [ ] `testNewMessagesNotificationReachesOpenSSEGet` green.
- [ ] `diagnose` reports `live_inbox: supported` when run through HTTP mode with the watcher started, `unavailable` under stdio and in tests.
- [ ] `iMessageMaxCommand` stops the watcher on termination; `swift test` exits cleanly (no hang, no leftover worker).
- [ ] plans/README.md row states which layer landed.

## STOP conditions

Stop and report (do not work around) if:

1. The drift check shows `GetMessagesInternals.swift` no longer has
   `MessageRow`, `MessageAnnotations.reactionsMap`, or `replyLookup`, or
   `Diagnose.swift` no longer has a `Capability` type at `:271-295`.
2. `QueryBuilder` cannot express the `MIN(chat_id)` subselect or the
   `ROWID <= ?` upper bound (fall back to a raw `db.query` string only if
   `GetUnread`/`Search` already do so; otherwise stop).
3. Adding the 13th tool breaks a test not listed in step 6 and the reason is
   not simply a pinned count (for example a catalog checksum or icon
   fixture): report the test name and stop.
4. The full suite after step 6 is not `0 failures` for a reason unrelated to
   this plan (pre-existing flake): rerun once; if it persists, report.
5. Layer 2: `swift-sdk` 0.12.1 `Server.notify` throws for a running session
   in `testNotifyAllSessionsReachesEverySessionResponseHandler` (error
   other than "not connected"), or `handleServerResponse` cannot be made to
   broadcast id-less payloads without restructuring the pending-request
   registry (plan 071's extraction). Alternative to document in the README:
   clients poll `get_messages_since`; layer 1 stands alone.
6. Layer 2: any `swift test` run hangs for more than 5 minutes after the
   watcher lands (a lingering `DispatchSourceTimer` or fd). Revert the
   watcher commits and report; do not ship layer 2 with a timer you cannot
   prove stops.
7. Layer 2: `DispatchSource.makeFileSystemObjectSource` never fires on the
   temp sqlite in `testFiresWhenARowIsInserted` even though the fallback
   poll reports the row (the test passes only via fallback). That is
   acceptable to ship (fallback is the guarantee) but must be stated in the
   plans/README.md row and the watcher doc comment; if the fallback also
   fails, stop.
8. Anything requires editing `.mcp.json` or `Task.sleep`.

## Maintenance notes

- **Cursor validity.** `next_rowid` is meaningful only against this Mac's
  `chat.db`. If the user signs out of iMessage or restores from backup,
  ROWIDs can restart; a client that sees `next_rowid > current_rowid` in a
  later response should reset by calling without `since_rowid`. Document
  this in the README section; consider a `cursor_epoch` (e.g. the `chat.db`
  inode) in a later plan if it ever bites.
- **Grace window (30 s).** Chosen from imsg's 20-retries-at-250 ms (5 s)
  plus slack for a sleeping Mac. Live data shows orphans are permanent (41
  in the last 5,000, newest 233615), so the window is only about the
  seconds right after an insert. Tune via the single constant.
- **URL-balloon dedupe** was measured at 0 duplicates at rest (query:
  balloon rows whose `text` matches a plain row within 4 rowids). imsg
  dedupes because during live watching the plain row and the balloon row
  can be observed as two events. If the layer-2 watcher ever reports the
  same text twice within a second in the same chat, port imsg's
  `URLBalloonDedupeState` (key `chatID|isFromMe|sender|text`, 90 s window)
  into the tool as a page-local pass and add `balloon_bundle_id` to the
  select list (the fixture column is already in place from step 1).
- **ROWID vs date.** Arrival order is not send order (26 inversions in
  5,000). Callers wanting display order sort by `ts` client-side; the tool
  must keep ROWID order so the cursor stays gap-free.
- **Modern lane.** Stateless clients never get the push. If a future
  swift-sdk release adds a stateless notification path, wire
  `NewMessagesNotification` there; nothing else changes.
- **stdio lane.** `MCPServerWrapper.server` (`Server/MCPServer.swift`) can
  call the same `notify`; start a `MessageWatcher` there in a follow-up if
  a stdio client wants the push. Diagnose's probe already distinguishes.
- **Never make the watcher a startup requirement.** If `chat.db` is
  unreadable (Full Disk Access missing), the watcher logs and the service
  still serves tools; `diagnose` is the place users find out.
- **Capability advertisement.** No MCP capability flag exists for custom
  notifications; `Version.serverCapabilities` stays
  `.init(tools: .init(listChanged: false))`. The README documents the
  notification name; that is the contract.
