# Plan 038: SSE GET endpoint coverage, the four `handleGet` guards and the 503 capacity wire response

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report, do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 0ff6b8f..HEAD -- swift/Sources/iMessageMax/Server/HTTPTransport.swift swift/Sources/iMessageMax/Server/SessionManager.swift`
> Expected: empty. Any change to `handleGet` or to `SessionManager.init`'s
> signature is a STOP condition, re-read the current code and report the
> mismatch instead of guessing.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW (test-only, plus one additive default-valued init parameter)
- **Depends on**: nothing
- **Category**: tests
- **Planned at**: commit `0ff6b8f`, 2026-08-07

## Why this matters

`HTTPTransport.handleGet` is the SSE streaming endpoint of the legacy MCP
session lane. It is registered on the root route:

```swift
router.get("/") { request, context in
    try await self.handleGet(request: request, context: context)
}
```

It has **zero end-to-end test coverage**. Verified at commit `0ff6b8f`:

```
$ cd swift && grep -rn '\.get\b\|method: \.get\|"GET"' Tests/iMessageMaxTests/*Integration*.swift
(no output)
```

Every existing HTTP integration test POSTs. Nothing has ever exercised the
GET path, so all four of its behavioral branches, three rejection guards and
the streaming happy path, are unverified. A refactor that broke any of them
(wrong status code, dropped `Mcp-Session-Id` echo, missing `text/event-stream`
content type) would ship green.

Plan 029 hardened the session/SSE lifecycle at the *actor* level and added
`SessionManager` unit tests, but it never reached the HTTP wire. This plan
closes that gap at the wire.

Second, smaller gap: `SessionManager.createSession` returning `.atCapacity`
is unit-tested (`Tests/iMessageMaxTests/HTTPTransportTests.swift:212`), but
the *HTTP mapping* of that result, 503 with the message "Too many active
sessions. Try again later.", is not, because `HTTPTransport` constructs its
`SessionManager` internally with the hardcoded default cap of 100 and offers
no way to lower it. One additive init parameter makes that reachable.

## Current state

### `handleGet` (`swift/Sources/iMessageMax/Server/HTTPTransport.swift:476-520`)

```swift
    /// Handles GET requests for SSE streaming
    func handleGet(
        request: Request,
        context: some Hummingbird.RequestContext
    ) async throws -> Response {
        // Validate Accept header
        guard let accept = request.headers[.accept],
            accept.contains("text/event-stream")
        else {
            return errorResponse(
                status: .notAcceptable,
                message: "Invalid Accept header, expected text/event-stream"
            )
        }

        // Validate session
        guard let sessionId = request.headers[.mcpSessionId] else {
            return errorResponse(
                status: .badRequest,
                message: "Missing Mcp-Session-Id header"
            )
        }

        guard await sessionManager.validate(sessionId: sessionId) != nil else {
            return errorResponse(
                status: .notFound,
                message: "Invalid or expired session. Please re-initialize."
            )
        }

        await sessionManager.touch(sessionId: sessionId)

        // Get Last-Event-ID for resumption if provided
        let lastEventId = request.headers[.lastEventId]

        // Create streaming response
        var responseHeaders = HTTPFields()
        responseHeaders[.contentType] = "text/event-stream"
        responseHeaders[.cacheControl] = "no-cache"
        responseHeaders[.connection] = "keep-alive"
        responseHeaders[.mcpSessionId] = sessionId
        ...
```

So the contract under test is exactly:

| Request | Expected |
|---|---|
| No `Accept: text/event-stream` | 406, JSON body containing `Invalid Accept header` |
| Correct `Accept`, no `Mcp-Session-Id` | 400, body containing `Missing Mcp-Session-Id header` |
| Correct `Accept`, unknown `Mcp-Session-Id` | 404, body containing `Invalid or expired session` |
| Correct `Accept`, live `Mcp-Session-Id` | 200, `Content-Type: text/event-stream`, `Cache-Control: no-cache`, `Mcp-Session-Id` echoed back |

### `.atCapacity` mapping (`swift/Sources/iMessageMax/Server/HTTPTransport.swift:250-256`)

```swift
            case .atCapacity:
                return errorResponse(
                    status: .serviceUnavailable,
                    message: "Too many active sessions. Try again later."
                )
```

### `HTTPTransport.init` (`swift/Sources/iMessageMax/Server/HTTPTransport.swift:73-93`)

```swift
    init(
        host: String = "127.0.0.1",
        port: Int = 8080,
        database: Database,
        resolver: ContactResolver,
        logger: Logger? = nil,
        requestTimeout: Duration = .seconds(300)
    ) {
        ...
        self.sessionManager = SessionManager(database: database, resolver: resolver)
    }
```

`SessionManager.init` already accepts `maxSessions: Int = 100`
(`swift/Sources/iMessageMax/Server/SessionManager.swift:73-82`), plan 029
added it as an explicitly documented test seam. `HTTPTransport` just doesn't
forward it.

## Conventions to follow

New tests go in the existing HTTP integration suite,
`swift/Tests/iMessageMaxTests/HTTPTransportIntegrationTests.swift`, and must
reuse its private helpers rather than reinventing them. Its shape:

```swift
import XCTest
import MCP
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Logging
import NIOCore
import NIOEmbedded
@testable import iMessageMax

final class HTTPTransportIntegrationTests: XCTestCase {
    func testInitializeCreatesSessionIdAndImmediateToolsList() async throws {
        let transport = HTTPTransport(
            host: "127.0.0.1",
            port: 0,
            database: Database(),
            resolver: ContactResolver(seedCache: [:]),
            requestTimeout: .seconds(5)
        )
        let app = await transport.makeApplicationForTesting()

        try await app.test(TestingSetup.router) { client in
            let initializeResponse = try await client.executeRequest(
                uri: "/",
                method: HTTPRequest.Method.post,
                headers: jsonHeaders(),
                body: byteBuffer(for: initializePayload(id: 1, protocolVersion: "2025-11-25"))
            )
            ...
            let sessionId = try XCTUnwrap(initializeResponse.head.headerFields[.mcpSessionId])
```

Helpers already present at the bottom of that file (all `private func` in the
same file, call them directly, do not redefine):

- `initializePayload(id:protocolVersion:)`
- `toolsListPayload(id:)`
- `jsonHeaders(sessionId:protocolVersion:)`
- `byteBuffer(for:)`
- `decodeJSONString(from:)`
- `decodeJSON(from:)`
- `initializeSession(...)`, use this to obtain a live session id

Header-name constants live at `HTTPTransport.swift:920-935`
(`.mcpSessionId`, `.mcpProtocolVersion`, `.mcpName`). Use `.mcpSessionId`,
never a raw string literal.

## Steps

### Step 1. Add the four `handleGet` tests

Add four test methods to `HTTPTransportIntegrationTests`. Build the SSE
`Accept` header explicitly (`jsonHeaders()` sets JSON accept, which is wrong
for this endpoint), construct an `HTTPFields` with
`[.accept: "text/event-stream"]` plus `[.mcpSessionId: ...]` where needed.

1. `testSSEGetRejectsMissingEventStreamAccept`. GET `/` with
   `Accept: application/json`. Assert `.notAcceptable` (406) and that the
   decoded body string contains `Invalid Accept header`.
2. `testSSEGetRejectsMissingSessionHeader`. GET `/` with
   `Accept: text/event-stream` and no `Mcp-Session-Id`. Assert `.badRequest`
   (400) and body contains `Missing Mcp-Session-Id header`.
3. `testSSEGetRejectsUnknownSession`. GET `/` with
   `Accept: text/event-stream` and `Mcp-Session-Id: not-a-real-session`.
   Assert `.notFound` (404) and body contains `Invalid or expired session`.
4. `testSSEGetOpensStreamForLiveSession`, first POST `initialize` (or call
   the existing `initializeSession` helper) to obtain a real session id, then
   GET `/` with `Accept: text/event-stream` and that id. Assert `.ok` (200),
   `head.headerFields[.contentType]` contains `text/event-stream`,
   `head.headerFields[.cacheControl]` equals `no-cache`, and
   `head.headerFields[.mcpSessionId]` equals the session id from
   `initialize`.

Each assertion that inspects a body must pass the decoded body string as the
`XCTAssert` message, matching how the existing tests surface failures:
`XCTAssertEqual(response.head.status, .notAcceptable, body)`.

**On test 4 and hanging**: `handleGet` returns a long-lived streaming
response. If `client.executeRequest` for the GET does not return promptly,
that is a STOP condition, see STOP conditions below. Do not add sleeps,
retries, or timeouts to work around it.

**Verify**:

```bash
cd swift && swift test --filter HTTPTransportIntegrationTests 2>&1 | tail -20
```

Expected: all tests pass, and the executed-test count for that suite is 4
higher than before your change. Record both numbers.

### Step 2, Forward `maxSessions` through `HTTPTransport.init`

In `swift/Sources/iMessageMax/Server/HTTPTransport.swift`, add one parameter
to `init` **at the end of the parameter list, with a default**, so no existing
call site changes:

```swift
    ///   - maxSessions: concurrent-session cap, forwarded to `SessionManager`.
    ///     Production uses the default; tests lower it to reach the 503 path.
    init(
        host: String = "127.0.0.1",
        port: Int = 8080,
        database: Database,
        resolver: ContactResolver,
        logger: Logger? = nil,
        requestTimeout: Duration = .seconds(300),
        maxSessions: Int = 100
    ) {
```

and forward it in the body:

```swift
        self.sessionManager = SessionManager(
            database: database,
            resolver: resolver,
            maxSessions: maxSessions
        )
```

Check `SessionManager.init`'s real parameter list before writing that call,
it has parameters between `resolver` and `maxSessions`. Pass `maxSessions` by
label and let the others default. If any parameter between them lacks a
default value, that is a STOP condition.

Do not change the default (100). Do not add any other parameter.

**Verify**:

```bash
cd swift && swift build 2>&1 | tail -5
```

Expected: builds clean, no new warnings.

### Step 3. Add the 503 capacity wire test

Add `testSecondSessionAtCapacityReturns503` to
`HTTPTransportIntegrationTests`: construct the transport with
`maxSessions: 1`, POST `initialize` once (expect 200 and a session id), then
POST `initialize` a second time. Assert the second response is
`.serviceUnavailable` (503) and its body contains
`Too many active sessions`.

**Verify**:

```bash
cd swift && swift test --filter HTTPTransportIntegrationTests 2>&1 | tail -20
```

Expected: all pass; suite count is now 5 higher than the Step 1 baseline.

### Step 4, Full suite

```bash
cd swift && swift build && swift test 2>&1 | tail -20
```

Expected: `Executed 238 tests, with 0 failures` (233 at `0ff6b8f` + 5 new). Read the count with `| grep -E 'Executed [0-9]+ tests' | tail -1`, not `| tail -3`.
If the baseline is not 233, report the actual numbers rather than adjusting
the plan's arithmetic to match.

## Done criteria

All must hold, checked by running the command:

1. `cd swift && swift build`, exits 0, no new warnings.
2. `cd swift && swift test 2>&1 | grep -E 'Executed [0-9]+ tests' | tail -1`, `Executed 238 tests, with 0 failures`. (`tail -3` shows the swift-testing trailer, not the XCTest count, this package runs both harnesses.)
3. `cd swift && grep -cE 'HTTPRequest\.Method\.get|method: \.get' Tests/iMessageMaxTests/HTTPTransportIntegrationTests.swift`, at
   least `4`. Match on either spelling. An earlier draft pinned the single
   literal `method: HTTPRequest.Method.get`, which made the criterion shape
   the code: the executor had to spell `.get` the long way in a `Request`
   head where `.get` was natural, purely to keep a grep count. A criterion
   that a correct implementation can fail is a broken criterion.
4. `cd swift && grep -n 'maxSessions' Sources/iMessageMax/Server/HTTPTransport.swift`, three hits: the doc-comment line Step 2 prescribes, the init parameter, and the forwarded argument. Only two of those are code. **Do not delete the doc comment to make a grep count smaller**, an earlier draft of this criterion said "exactly two" and contradicted Step 2's own snippet.
5. `git diff --stat`, touches exactly two files:
   `swift/Sources/iMessageMax/Server/HTTPTransport.swift` and
   `swift/Tests/iMessageMaxTests/HTTPTransportIntegrationTests.swift`.

## Files in scope

- `swift/Sources/iMessageMax/Server/HTTPTransport.swift`, the `init` parameter and its forwarding **only**.
- `swift/Tests/iMessageMaxTests/HTTPTransportIntegrationTests.swift`, new tests.

## Files explicitly out of scope

- `swift/Sources/iMessageMax/Server/SessionManager.swift`, already has the seam; do not modify.
- `swift/Sources/iMessageMax/Server/SSEConnection.swift`, plan 029 hardened it; do not restructure.
- `handleGet`'s body, this plan tests it, it does not change it. If a test
  fails because the current behavior differs from the table in "Current
  state", report the discrepancy; do not edit `handleGet` to make the test
  pass.
- `swift/Tests/iMessageMaxTests/HTTPTransportTests.swift`, the existing
  actor-level tests stay as they are.

## Explicitly not covered, and why

`SessionCreationResult.startFailed` → HTTP 500
(`HTTPTransport.swift:262-267`) stays untested. Inducing it requires
`Server.start(transport:)` from the MCP SDK to throw, which no injectable
seam currently reaches. Adding a test-only failure hook to `SessionManager`
would put production complexity in the session actor to cover one
three-line mapping. Not worth it. This paragraph exists so the gap is a
recorded decision rather than an oversight.

## Test plan

Five new tests, all in
`swift/Tests/iMessageMaxTests/HTTPTransportIntegrationTests.swift`, all
following `testInitializeCreatesSessionIdAndImmediateToolsList` as the
structural pattern (build transport → `makeApplicationForTesting()` →
`app.test(TestingSetup.router) { client in ... }`).

What each must actually assert, a test that only checks a status code and
not the body/headers does not satisfy this plan:

| Test | Asserts |
|---|---|
| `testSSEGetRejectsMissingEventStreamAccept` | status 406 **and** body mentions `Invalid Accept header` |
| `testSSEGetRejectsMissingSessionHeader` | status 400 **and** body mentions `Missing Mcp-Session-Id header` |
| `testSSEGetRejectsUnknownSession` | status 404 **and** body mentions `Invalid or expired session` |
| `testSSEGetOpensStreamForLiveSession` | status 200 **and** `Content-Type` contains `text/event-stream` **and** `Cache-Control` is `no-cache` **and** `Mcp-Session-Id` echoes the initialize response |
| `testSecondSessionAtCapacityReturns503` | second initialize is 503 **and** body mentions `Too many active sessions` |

## STOP conditions

Stop and report, do not improvise, if any of these occur:

- ~~The GET request in test 4 does not return.~~ **This fired, and is now
  resolved, see "How test 4 was actually made to work" below.** Left in the
  history because the prediction was right and the plan was better for
  carrying it.
- `SessionManager.init` has a parameter between `resolver` and `maxSessions`
  that has no default value.
- Any existing test starts failing. The only production change here is an
  additive defaulted parameter; it cannot legitimately break anything.
- `handleGet`'s actual status codes or messages differ from the table above.
- The `swift test` baseline at the start of your work is not 233.

## Maintenance note

The four-row contract table in "Current state" is the durable artifact here:
if `handleGet` grows a fifth guard (origin validation, protocol-version
enforcement), it needs a fifth row and a fifth test. Watch in review for
changes to `handleGet` that add or reorder guards without a matching test,
guard *order* is behavior, since a request missing both `Accept` and
`Mcp-Session-Id` must answer 406, not 400.

The `maxSessions` passthrough is a test seam with a production default.
If someone later wires it to a config file or environment variable, the
default must stay 100 and `testSecondSessionAtCapacityReturns503` must keep
setting it explicitly rather than relying on ambient config.

## How test 4 was actually made to work

The plan predicted test 4 might hang and told the executor to report rather
than improvise. It hung. The mechanism, confirmed in Hummingbird's own source
rather than inferred:

```swift
// RouterTestFramework.swift:114-125
group.addTask {
    let response: Response
    do {
        response = try await self.responder.respond(to: request, context: context)
    } catch { ... }
    let responseWriter = RouterResponseWriter()
    try await response.body.write(responseWriter)          // <-- drains to completion
    return responseWriter.values.withLockedValue { values in
        TestResponse(head: response.head, body: values.body, ...)  // <-- only then
    }
}
```

`handleGet` returns a body that pumps the SSE channel, keep-alives included,
until the connection is unregistered. It never completes, so `executeRequest`
never returns and `response.head` is unreachable through the client. No
timeout or retry fixes this; any body-collecting client deadlocks the same
way.

The resolution: **call `handleGet` directly and assert on `response.head`
without touching `response.body`.** The head is fully populated the moment the
handler returns, and nothing obliges the body writer to run. Two facts make
this cheap:

- `handleGet` never reads `context`, the only occurrence in its body is the
  parameter itself, so any instance satisfies the generic.
- The file already contained the exact construction needed, in
  `testOriginMiddlewareRejectsBadOriginAndHost`:
  `BasicRequestContext(source: ApplicationRequestContextSource(channel: EmbeddedChannel(), logger: Logger(label: #function)))`.

The `initialize` call still goes through the real client, so the session id
under assertion is genuine.

This trades wire-level fidelity for reachability on exactly one test, and the
code carries a comment saying so, including an explicit "do not fix it back."
Anyone who routes it through `executeRequest` again will hang the suite.

**Lesson worth keeping**: a streaming endpoint is not testable by a
body-collecting client, and that is a property of the *client*, not a defect in
the endpoint. Reach for the handler directly rather than concluding the code is
untestable.
