# Plan 071: Extract the pending-request registry from HTTPTransport and migrate two hand-built queries onto QueryBuilder

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 639529e..HEAD -- swift/Sources/iMessageMax/Server/HTTPTransport.swift swift/Sources/iMessageMax/Database/QueryBuilder.swift swift/Sources/iMessageMax/Tools/ListAttachments.swift swift/Sources/iMessageMax/Tools/GetActiveConversations.swift swift/Sources/iMessageMax/Tools/FindChat.swift swift/Tests/iMessageMaxTests/HTTPTransportTests.swift swift/Tests/iMessageMaxTests/HTTPTransportIntegrationTests.swift swift/Tests/iMessageMaxTests/OversizedBodyTests.swift swift/Tests/iMessageMaxTests/ListAttachmentsQueryTests.swift swift/Tests/iMessageMaxTests/ListToolCharacterizationTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: LOW (pure refactor; every touched behavior is already pinned by tests)
- **Depends on**: nothing
- **Category**: tech-debt
- **Planned at**: commit `639529e`, 2026-09-01. Baseline: `cd swift && swift build && swift test` passes with 370 tests, 0 failures.

## Why this matters

`HTTPTransport.swift` is ~900 lines and owns three unrelated jobs: HTTP
routing (POST/GET/DELETE on `/`), request body parsing (size limits,
Accept negotiation), and a per-session registry of in-flight JSON-RPC
requests with timeout timers. The registry is the part with the subtlest
invariants (cancel the DispatchSourceTimer on every removal path, resume
each continuation exactly once, never use `asyncAfter` for cancellable
work) and it is the part nobody can unit-test in isolation today because
it is private state on the transport actor. Plan 072 wants to add a body
read deadline to the parsing helper; doing that inside a 900-line file
makes review harder than it needs to be.

Separately, two tools still build SQL by string concatenation while the
rest of the tools use `QueryBuilder`. `ListAttachments.buildQuery` appends
`AND ...` fragments to a `var sql` with a parallel `var params`, and
`GetActiveConversations` appends its `is_group` clause to a HAVING by
string. Both work, both are golden-tested, and both are the kind of code
that grows a bind-order bug the next time someone adds a filter. Migrating
them now, while the characterization tests are green, is cheap.

This plan is two independent halves. Do half A, land it as its own commit,
then do half B. If half A hits a STOP condition, half B can still proceed.

## Current state

### A. The pending-request registry lives inside HTTPTransport

`swift/Sources/iMessageMax/Server/HTTPTransport.swift:34-49`:

```swift
    private var pendingRequests: [PendingRequestKey: PendingRequest] = [:]
    ...
    private let requestTimeout: Duration
    ...
    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, Error>
        let timeoutTimer: DispatchSourceTimer
    }
    private struct PendingRequestKey: Hashable {
        let sessionId: String
        let requestId: String
    }
```

The registry has four mutation paths and one enumeration path. All five
must survive the extraction with identical semantics.

Store (`HTTPTransport.swift:789-824`). Note the comment: it records why the
timer is a `DispatchSourceTimer` rather than `asyncAfter`. Keep that
comment with the code.

```swift
    private func storePendingRequest(
        sessionId: String,
        id: String,
        continuation: CheckedContinuation<Data, Error>
    ) -> Bool {
        let key = PendingRequestKey(sessionId: sessionId, requestId: id)
        guard pendingRequests[key] == nil else { return false }
        // A DispatchSourceTimer is used instead of asyncAfter so the timer can be
        // cancelled when the response arrives. asyncAfter closures cannot be
        // cancelled and each one retains ~0.65 KiB until it fires, which for a
        // 300 s timeout under load is a real leak.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.timeoutPendingRequest(sessionId: sessionId, id: id) }
        }
        timer.schedule(deadline: .now() + AsyncTimeout.dispatchInterval(for: requestTimeout))
        timer.resume()
        pendingRequests[key] = PendingRequest(continuation: continuation, timeoutTimer: timer)
        return true
    }
```

Timeout (`:826-832`): removes the entry and resumes throwing
`MCPError.serverError(code: -32000, message: "Request timeout")`.

Remove (`:836-844`): removes the entry, cancels its timer, returns the
continuation to the caller (`handleServerResponse` at `:668` resumes it
with the response body; if nothing was pending the response is broadcast
over SSE instead).

Cleanup for a session (`:847-856`): filters `pendingRequests.keys` by
`sessionId`, cancels each timer, resumes each continuation throwing
`MCPError.serverError(code: -32000, message: "Session terminated")`. Called
from `handleDelete` (`:644`) and from the session-termination handler set in
`configureRoutingIfNeeded` (`:858-871`).

Disconnect (`:703-707`): iterates every entry, cancels the timer, resumes
throwing `MCPError.connectionClosed`, then `removeAll()`.

The producer side is in `handlePost` (`:332-366`): a
`withCheckedThrowingContinuation` calls `storePendingRequest`; a `false`
return means a duplicate request id and the continuation is resumed
throwing a `-32600` error; otherwise a `Task` routes the message to the
session and, if routing fails, calls `removePendingRequest` and resumes
throwing `MCPError.connectionClosed`.

### A. Body parsing helpers are also on the transport

`HTTPTransport.swift:730-736`:

```swift
    static let maxRequestBodyBytes = 512 * 1024
    ...
    static let overLimitDrainBytes = 32 * 1024 * 1024
    ...
    enum BodyCollection { case complete(Data); case tooLarge }
```

`HTTPTransport.swift:761-784` is `nonisolated static func
collectBodyDrainingOverflow(_ body: RequestBody, declaredLength: Int?,
maxBytes: Int, drainLimit: Int) async throws -> BodyCollection`. It is
called from `handlePost` at `:184-196` and directly from
`OversizedBodyTests` (4 tests) as `HTTPTransport.collectBodyDrainingOverflow`.

`HTTPTransport.swift:897-900`:

```swift
    private nonisolated func acceptsStreamableHTTP(_ accept: String) -> Bool {
        if accept.contains("*/*") { return true }
        return accept.contains("application/json") && accept.contains("text/event-stream")
    }
```

Called from `handlePost` at `:173-181`.

### B. ListAttachments builds SQL by concatenation

`swift/Sources/iMessageMax/Tools/ListAttachments.swift:322-462`,
`buildQuery(chatId:fromPerson:typeFilter:since:before:limit:sort:cursor:) -> (String, [Any])`.
The shape:

- `typeClause` comes from `AttachmentType.sqlPredicate(for:alias: "a")`.
- `ranksBySize = sort == .largestFirst`. The largest-first branch joins
  `message_attachment_join` and `attachment` directly and groups by
  `m.ROWID`; the two date branches pick one chat per message via a
  `chatPick` subquery (`JOIN chat c ON c.ROWID = (...)`) and filter
  attachments with an `EXISTS` subquery.
- Then, in order: `fromPerson` (`"me"` becomes `m.is_from_me = 1`, anything
  else becomes `h.id LIKE ? ESCAPE '\\'` bound as `%escapeLike(x)%`),
  `since`/`before` via `AppleTime.parse` bound as `m.date >= ?` / `m.date <= ?`,
  the cursor (`cursor.olderThanSQL` or `cursor.newerThanSQL` with the
  cursor's three bind values), `GROUP BY m.ROWID` when `ranksBySize`,
  `ORDER BY` per sort, and finally `LIMIT ?` with `params.append(limit)`.

The dominant risk in this function is bind order: the `typeClause` binds
nothing, but the chat filter, from-person, since, before, and cursor each
bind, and they have to bind in the same order the `?` placeholders appear.
`QueryBuilder` guarantees that by construction.

`ListAttachmentsQueryTests` (9 tests, `swift/Tests/iMessageMaxTests/ListAttachmentsQueryTests.swift:137-219`)
pins every branch: one row per message even when joined to two chats,
type filter applying to attachments not messages, three sort orders,
inclusive time bounds, cursor paging on both date sorts, and `more`
without overrun. It asserts on results, not on SQL text, so a migration
that preserves behavior passes unchanged.

### B. GetActiveConversations builds SQL by concatenation

`swift/Sources/iMessageMax/Tools/GetActiveConversations.swift:154-189`
(inside `execute`): a raw SQL string with a correlated `participant_count`
subquery, `SUM(CASE ...)` counts for my/their messages, `MAX` dates, then

```swift
            WHERE m.date >= ? AND m.associated_message_type = 0
            GROUP BY c.ROWID
            HAVING my_count >= 1 AND their_count >= 1
```

followed by `var params: [Any] = [windowStartApple]`, then

```swift
        if let isGroup {
            sql += isGroup ? " AND participant_count > 1" : " AND participant_count <= 1"
        }
        sql += " ORDER BY last_in_window DESC LIMIT ?"
        params.append(fetchLimit)
```

where `fetchLimit = clampedLimit * 3`. Rows map to `ChatActivityRow`.

`ListToolCharacterizationTests` covers `get_active_conversations` at
`swift/Tests/iMessageMaxTests/ListToolCharacterizationTests.swift:217-445`
with a fixture that has 3 messages from me and 2 from them inside the
window. These are the golden tests for half B's second migration.

### B. QueryBuilder API (for reference)

`swift/Sources/iMessageMax/Database/QueryBuilder.swift`: `select(_ columns: String...)`,
`from(_:)`, `join(_ clause: String, _ params: Any...)`, `join(_ clause:, params: [Any])`,
`leftJoin(_:)`, `where(_ clause: String, _ params: Any...)`, `where(_ clause:, params: [Any])`,
`groupBy(_:)`, `having(_ clause:, _ params: Any...)`, `orderBy(_ columns: String...)`,
`limit(_ n: Int)`, `build() -> (sql: String, params: [Any])`, and
`static func escapeLike(_:)`. Join params bind before WHERE params; HAVING
params bind after WHERE; LIMIT is interpolated as an integer, not bound.
The builder is a class with a fluent API (calls mutate and return `self`).

### B. FindChat raw queries stay raw

`swift/Sources/iMessageMax/Tools/FindChat.swift:277`, `:399`, `:427`, `:459`
are four raw queries (candidate chats by handle set, display-name LIKE,
unnamed DMs by participant, chats by recent content). They use `IN (...)`
placeholder lists and a shared `groupFilterSQL` fragment. They are out of
scope: leave them raw and add one comment above `groupFilterSQL`
(`:253`) saying so, so the next reader does not attempt the migration
piecemeal.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `cd swift && swift build` | ends in `Build complete!` |
| Half A focused tests | `cd swift && swift test --filter "HTTPTransportTests\|HTTPTransportIntegrationTests\|OversizedBodyTests"` | 48 tests, 0 failures |
| Half B focused tests | `cd swift && swift test --filter "ListAttachmentsQueryTests\|ListToolCharacterizationTests"` | 17 tests, 0 failures |
| Whole suite | `cd swift && swift test` | 370 tests plus any you add, 0 failures |
| Task.sleep guard | `cd swift && swift test --filter LaunchdSafetyTests` | 1 test, 0 failures |

## Scope

In scope:

- New file `swift/Sources/iMessageMax/Server/PendingRequestRegistry.swift`.
- New file `swift/Sources/iMessageMax/Server/HTTPRequestParsing.swift` (name
  is a suggestion; anything under `Server/` that reads as "request parsing"
  is fine).
- `HTTPTransport.swift` shrinks to routing plus delegation.
- `ListAttachments.buildQuery` and the `GetActiveConversations` query move
  onto `QueryBuilder`.
- One comment in `FindChat.swift`.
- A new `PendingRequestRegistryTests.swift` (half A) covering the registry
  in isolation.

Out of scope:

- Any behavior change to HTTP status codes, error codes, timeout values,
  SSE broadcast, or session lifecycle.
- Migrating `FindChat`, `ListChats.buildPageQuery` (its message aggregate
  is a deliberate raw subquery), `SearchInternals`, or `ChatSummaryQueries`.
- Adding the body read deadline (that is plan 072, which builds on the
  parsing helper this plan creates).
- Touching `.mcp.json` (never), committing secrets (never), or introducing
  `Task.sleep` anywhere under `swift/Sources` (`LaunchdSafetyTests` fails
  the build if you do; use `AsyncTimeout` or Dispatch timers).

## Git workflow

- Branch: `git checkout -b advisor/071-registry-and-querybuilder main`.
- Commit 1 (after Step 3): `refactor(http): extract PendingRequestRegistry and request parsing from HTTPTransport`
- Commit 2 (after Step 6): `refactor(tools): move list_attachments and get_active_conversations onto QueryBuilder`
- Conventional commits, one logical change each. Do not push and do not
  merge; the reviewer does that.

## Steps

### Step 1: Registry tests first

Create `swift/Tests/iMessageMaxTests/PendingRequestRegistryTests.swift`.
Write these against the API in Step 2 before the actor exists, so the
tests fail to compile first and then pass:

1. `testStoreThenRemoveReturnsContinuationAndCancelsTimer`: store a
   continuation for `(session: "s1", id: "1")`, call `remove`, assert the
   returned continuation is non-nil and that resuming it delivers the
   value to the awaiting task.
2. `testDuplicateIdIsRejected`: store `("s1","1")` twice; second `store`
   returns `false`; the first continuation is still resumable.
3. `testTimeoutResumesWithRequestTimeoutError`: registry built with
   `timeout: .milliseconds(50)`; store; await the continuation; expect
   `MCPError.serverError(code: -32000, message: "Request timeout")` within
   well under one second.
4. `testCleanupForSessionOnlyTouchesThatSession`: store `("s1","1")` and
   `("s2","1")`; `cleanup(for: "s1")`; the `s1` continuation throws
   `"Session terminated"`; `remove(session: "s2", id: "1")` still returns
   its continuation.
5. `testRemoveAllResumesEverythingWithConnectionClosed`: store two, call
   `removeAll()`, both throw `MCPError.connectionClosed`, registry is empty.

Use `withCheckedThrowingContinuation` inside a `Task` per test to obtain a
real `CheckedContinuation<Data, Error>`; do not fake one. Wait on the
resulting `Task.value`. No `Task.sleep` in tests either: use
`AsyncTimeout.sleep` if a test needs a delay, but the tests above should
not need one.

**Verify**: `cd swift && swift build --build-tests` fails with "cannot find
'PendingRequestRegistry' in scope". That is the expected red.

### Step 2: Create the actor

Create `swift/Sources/iMessageMax/Server/PendingRequestRegistry.swift`:

```swift
import Foundation
import MCP

/// In-flight JSON-RPC requests awaiting a response from the session's server,
/// keyed by (session, request id), each with a cancellable timeout timer.
actor PendingRequestRegistry {
    struct Key: Hashable { let sessionId: String; let requestId: String }
    private struct Entry {
        let continuation: CheckedContinuation<Data, Error>
        let timer: DispatchSourceTimer
    }
    private var entries: [Key: Entry] = [:]
    private let timeout: Duration

    init(timeout: Duration) { self.timeout = timeout }

    /// Returns false when a request with the same id is already pending.
    func store(sessionId: String, id: String, continuation: CheckedContinuation<Data, Error>) -> Bool
    func remove(sessionId: String, id: String) -> CheckedContinuation<Data, Error>?
    func timeout(sessionId: String, id: String)
    func cleanup(for sessionId: String)
    func removeAll()
    var count: Int { entries.count }   // for tests
}
```

Move the bodies of `storePendingRequest`, `timeoutPendingRequest`,
`removePendingRequest`, `cleanupPendingRequests(for:)`, and the disconnect
loop (`:703-707`) into these methods verbatim, including the
DispatchSourceTimer comment. The timer handler becomes
`Task { [weak self] in await self?.timeout(sessionId:id:) }`.

Keep the three error values byte-identical: `-32000 "Request timeout"`,
`-32000 "Session terminated"`, `MCPError.connectionClosed`.

Then in `HTTPTransport`:

- Replace `pendingRequests`, `PendingRequest`, `PendingRequestKey` with
  `private let pendingRequests: PendingRequestRegistry`, initialised in
  `init` as `PendingRequestRegistry(timeout: requestTimeout)`.
- `handlePost` `:332-366`: `storePendingRequest(...)` becomes
  `await pendingRequests.store(...)`. Because `withCheckedThrowingContinuation`'s
  body is synchronous, wrap: capture the continuation, then
  `Task { let stored = await pendingRequests.store(...); if !stored { continuation.resume(throwing: ...) ; return }; ... route ... }`.
  The duplicate-id error text and the `-32600` code stay the same.
- `handleServerResponse` `:668`, `handleDelete` `:644`, the termination
  handler in `configureRoutingIfNeeded`, and `disconnect` call through to
  the registry. Delete the four private methods from the transport.

**Verify**: `cd swift && swift build` ends in `Build complete!`, then
`cd swift && swift test --filter "PendingRequestRegistryTests\|HTTPTransportTests\|HTTPTransportIntegrationTests"`
reports 49 tests, 0 failures (44 existing plus the 5 new).

### Step 3: Move the parsing helpers

Create `swift/Sources/iMessageMax/Server/HTTPRequestParsing.swift` holding:

```swift
enum HTTPRequestParsing {
    static let maxRequestBodyBytes = 512 * 1024
    static let overLimitDrainBytes = 32 * 1024 * 1024
    enum BodyCollection { case complete(Data); case tooLarge }
    static func collectBodyDrainingOverflow(_ body: RequestBody, declaredLength: Int?, maxBytes: Int, drainLimit: Int) async throws -> BodyCollection
    static func acceptsStreamableHTTP(_ accept: String) -> Bool
}
```

Move the bodies verbatim from `HTTPTransport.swift:730-784` and `:897-900`.
Leave forwarding shims on `HTTPTransport` so existing call sites and
`OversizedBodyTests` keep compiling:

```swift
    static var maxRequestBodyBytes: Int { HTTPRequestParsing.maxRequestBodyBytes }
    static var overLimitDrainBytes: Int { HTTPRequestParsing.overLimitDrainBytes }
    typealias BodyCollection = HTTPRequestParsing.BodyCollection
    nonisolated static func collectBodyDrainingOverflow(...) async throws -> BodyCollection {
        try await HTTPRequestParsing.collectBodyDrainingOverflow(...)
    }
```

Do not rewrite `OversizedBodyTests` to the new name; the shim is the
contract and plan 072 will decide what to do with it.

**Verify**: `cd swift && swift test --filter "OversizedBodyTests\|HTTPTransportTests\|HTTPTransportIntegrationTests\|PendingRequestRegistryTests"`
reports 53 tests, 0 failures. `wc -l swift/Sources/iMessageMax/Server/HTTPTransport.swift`
is at least 150 lines shorter than before. Commit 1.

### Step 4: Migrate ListAttachments.buildQuery

Rewrite `buildQuery` (`ListAttachments.swift:322-462`) on a `QueryBuilder`:

- `select(...)` the same column list the current branch produces.
- `from("message m")`, then the branch-specific joins via `join(...)`. The
  `chatPick` subquery join in the date branches has bind parameters
  (`chatId`) in the subquery; pass them with `join(_:params:)` so they bind
  before WHERE params, exactly as today.
- Every `sql += " AND ..."` becomes a `.where(...)`. Keep the LIKE escape
  and the `ESCAPE '\\'` suffix.
- `groupBy("m.ROWID")` when `ranksBySize`.
- `orderBy(...)` per sort.
- `limit(limit)`. `QueryBuilder.limit` interpolates the integer rather than
  binding it, so drop `params.append(limit)`. `limit` is already clamped
  by the caller; confirm that by reading the call site before relying on it.
- Return `query.build()`.

Keep the function signature. Keep the comment explaining why the date
sorts pick one chat per message.

**Verify**: `cd swift && swift test --filter ListAttachmentsQueryTests`
reports 9 tests, 0 failures, with no test edits. If any test needed
editing to pass, the migration changed behavior: revert and try again.

### Step 5: Migrate GetActiveConversations

Rewrite the query at `GetActiveConversations.swift:154-189`:

```swift
        let query = QueryBuilder()
            .select(/* same six columns, including the correlated participant_count subquery */)
            .from("chat c")
            .join("chat_message_join cmj ON cmj.chat_id = c.ROWID")
            .join("message m ON m.ROWID = cmj.message_id")
            .where("m.date >= ?", windowStartApple)
            .where("m.associated_message_type = 0")
            .groupBy("c.ROWID")
            .having("my_count >= 1 AND their_count >= 1")
        if let isGroup {
            query.having(isGroup ? "participant_count > 1" : "participant_count <= 1")
        }
        query.orderBy("last_in_window DESC").limit(fetchLimit)
        let (sql, params) = query.build()
```

Check how `QueryBuilder.having` combines multiple clauses (read
`build()`) so the two HAVING predicates are joined with `AND`, matching
the current string. Keep the `ChatActivityRow` mapping closure unchanged.

**Verify**: `cd swift && swift test --filter ListToolCharacterizationTests`
reports 8 tests, 0 failures, with no test edits.

### Step 6: FindChat comment and full suite

Above `groupFilterSQL` at `FindChat.swift:253` add:

```swift
    // The four queries below stay on raw SQL on purpose: they splice
    // `IN (?, ?, ...)` placeholder lists whose length is data-dependent,
    // which QueryBuilder does not model. See plans/071.
```

**Verify**: `cd swift && swift build && swift test` reports 375 tests, 0
failures. `cd swift && swift test --filter LaunchdSafetyTests` passes.
`grep -rn "Task.sleep" swift/Sources` prints nothing. Commit 2.

## Test plan

- New: `PendingRequestRegistryTests` (5 tests) exercising store, duplicate,
  timeout, per-session cleanup, and remove-all directly on the actor.
- Unchanged and must stay green with zero edits: `HTTPTransportTests` (26),
  `HTTPTransportIntegrationTests` (18), `OversizedBodyTests` (4),
  `ListAttachmentsQueryTests` (9), `ListToolCharacterizationTests` (8).
- Whole suite: 375 tests, 0 failures.

## Done criteria

- [ ] `swift/Sources/iMessageMax/Server/PendingRequestRegistry.swift` exists and is an `actor`.
- [ ] `grep -n "pendingRequests\[" swift/Sources/iMessageMax/Server/HTTPTransport.swift` prints nothing.
- [ ] `grep -n "DispatchSource.makeTimerSource" swift/Sources/iMessageMax/Server/` hits only `PendingRequestRegistry.swift`.
- [ ] `grep -n "collectBodyDrainingOverflow" swift/Sources/iMessageMax/Server/HTTPRequestParsing.swift` finds the implementation; the `HTTPTransport` copy is a one-line forwarder.
- [ ] `grep -n 'sql += ' swift/Sources/iMessageMax/Tools/ListAttachments.swift swift/Sources/iMessageMax/Tools/GetActiveConversations.swift` prints nothing.
- [ ] `git diff main -- swift/Tests/iMessageMaxTests/ListAttachmentsQueryTests.swift swift/Tests/iMessageMaxTests/ListToolCharacterizationTests.swift swift/Tests/iMessageMaxTests/OversizedBodyTests.swift swift/Tests/iMessageMaxTests/HTTPTransportTests.swift swift/Tests/iMessageMaxTests/HTTPTransportIntegrationTests.swift` is empty.
- [ ] `cd swift && swift test` reports 375 tests, 0 failures.
- [ ] Two commits on `advisor/071-registry-and-querybuilder`, not pushed.

## STOP conditions

- The drift check shows changes to any in-scope file and the excerpts above no longer match.
- Any existing test in the five golden suites needs an edit to pass. That means behavior moved; report the diff rather than editing the test.
- `QueryBuilder` cannot express something `buildQuery` needs (for example, a join whose params must bind after a WHERE param). Report which clause; do not extend `QueryBuilder` in this plan.
- `withCheckedThrowingContinuation` plus the actor hop in Step 2 makes an `HTTPTransportIntegrationTests` case flaky (run the filter three times). Report; do not add sleeps.
- `LaunchdSafetyTests` fails.

## Maintenance notes

- Future transport work (plan 072's read deadline, any connection cap)
  goes in `HTTPRequestParsing.swift` or `buildApplication()`, not in the
  registry.
- If a tool ever needs a data-dependent `IN (...)` list, that is the
  moment to add `QueryBuilder.whereIn(_ column:, _ values: [Any])` and
  migrate `FindChat`; until then its four raw queries are intentional.
- The `HTTPTransport` forwarders for `collectBodyDrainingOverflow` and
  the size constants can be removed once `OversizedBodyTests` is pointed at
  `HTTPRequestParsing` (plan 072 may do that).
