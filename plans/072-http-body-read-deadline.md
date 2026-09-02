# Plan 072: Bounded read deadline for HTTP request bodies

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 639529e..HEAD -- swift/Sources/iMessageMax/Server/HTTPTransport.swift swift/Sources/iMessageMax/Server/HTTPRequestParsing.swift swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift swift/Sources/iMessageMax/Server/SSEConnection.swift swift/Tests/iMessageMaxTests/OversizedBodyTests.swift swift/Tests/iMessageMaxTests/HTTPTransportIntegrationTests.swift swift/Tests/iMessageMaxTests/LaunchdSafetyTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition. One expected drift: if plan 071
> has landed, `collectBodyDrainingOverflow` lives in
> `Server/HTTPRequestParsing.swift` with a forwarder on `HTTPTransport`. That
> is fine; edit the implementation wherever it lives.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: MEDIUM (touches the request path; a wrong deadline breaks every POST)
- **Depends on**: nothing (071 is a convenience, not a prerequisite)
- **Category**: security
- **Planned at**: commit `639529e`, 2026-09-01. Baseline: `cd swift && swift build && swift test` passes with 370 tests, 0 failures.

## Why this matters

`handlePost` reads the whole request body before doing anything else. The
read is bounded in bytes (`maxRequestBodyBytes`, 512 KiB, with a 32 MiB
overflow drain) but not in time. A client that sends headers, one byte of
body, and then stalls holds a Hummingbird connection, an event-loop
iterator, and the `handlePost` task open forever. Nothing in the process
ever closes it: the server sets no idle timeout on the HTTP1 channel, and
the request-level `requestTimeout` (300 s) only starts after the body has
been parsed and the JSON-RPC request has been stored in the pending
registry.

The server binds to loopback by default and validates `Origin`, so the
exposure is a misbehaving local client rather than the open internet, but
the launchd service is expected to run for weeks. A handful of stalled
connections from a crashed client that never closed its sockets would
accumulate for the life of the process. Plan 060 already fixed one
fd-leak shape (the oversized-body drain); this is the time-domain twin.

Two layers close it:

1. An application-level deadline around the body read in
   `collectBodyDrainingOverflow`, returning HTTP 408 with a JSON-RPC error
   body so a client that is merely slow gets a diagnosable answer.
2. Hummingbird's own `HTTP1Channel.Configuration.idleTimeout`, which closes
   channels that stall mid-request or sit idle between requests. This is
   the backstop for clients that stall before sending any body at all,
   which the application layer never sees.

## Current state

### The unbounded read

`swift/Sources/iMessageMax/Server/HTTPTransport.swift:761-784` (after plan
071, `HTTPRequestParsing.swift`):

```swift
    nonisolated static func collectBodyDrainingOverflow(
        _ body: RequestBody,
        declaredLength: Int?,
        maxBytes: Int,
        drainLimit: Int
    ) async throws -> BodyCollection {
        if let declaredLength, declaredLength > drainLimit {
            return .tooLarge
        }

        var collected = ByteBuffer()
        var iterator = body.makeAsyncIterator()
        while var chunk = try await iterator.next() {
            guard collected.readableBytes + chunk.readableBytes <= maxBytes else {
                var drained = chunk.readableBytes
                while drained <= drainLimit, let more = try await iterator.next() {
                    drained += more.readableBytes
                }
                return .tooLarge
            }
            collected.writeBuffer(&chunk)
        }
        return .complete(Data(buffer: collected))
    }
```

Both `iterator.next()` calls can suspend indefinitely.

`HTTPTransport.swift:736`: `enum BodyCollection { case complete(Data); case tooLarge }`.

The call site, `HTTPTransport.swift:184-196`:

```swift
        switch try await Self.collectBodyDrainingOverflow(
            request.body,
            declaredLength: request.headers[.contentLength].flatMap(Int.init),
            maxBytes: Self.maxRequestBodyBytes,
            drainLimit: Self.overLimitDrainBytes
        ) {
        case .complete(let data):
            bodyData = data
        case .tooLarge:
            return Response(status: .contentTooLarge)
        }
```

`errorResponse(status:message:code:)` at `HTTPTransport.swift:1008` builds a
JSON-RPC error body with `"id": null` for a given HTTP status.

### The only sleep primitive allowed

`swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift:11-26`:

```swift
    static func sleep(_ duration: Duration) async {
        let gate = ResumeGate()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let work = DispatchWorkItem {
                    gate.resume(continuation)
                }
                gate.arm(work: work, continuation: continuation)
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + dispatchInterval(for: duration),
                    execute: work
                )
            }
        } onCancel: {
            gate.cancelAndResume()
        }
    }
```

It honors task cancellation, so it can be raced inside a task group and
cancelled when the other branch wins. `LaunchdSafetyTests.testNoTaskSleepInServiceSources`
(`swift/Tests/iMessageMaxTests/LaunchdSafetyTests.swift:7-33`) fails the
suite if `Task.sleep(` appears anywhere under `swift/Sources`.

`RequestBody` is `Sendable` (`swift/.build/checkouts/hummingbird/Sources/HummingbirdCore/Request/RequestBody.swift:17`),
so it can be handed to a child task.

### No idle timeout on the channel

`HTTPTransport.swift:873-895`:

```swift
        return Application(
            router: router,
            configuration: .init(
                address: .hostname(host, port: port)
            ),
            logger: logger
        )
```

Hummingbird 2.26.0 exposes the timeout through the server builder, not
`ApplicationConfiguration`. `swift/.build/checkouts/hummingbird/Sources/Hummingbird/Application.swift:258-259`
shows the router initializer takes `server: HTTPServerBuilder = .http1()`,
and `HummingbirdCore/Server/HTTP/HTTPServerBuilder.swift:82-86` provides
`.http1(configuration: HTTP1Channel.Configuration)` whose init
(`HTTP1Channel.swift:57-63`) takes `idleTimeout: TimeAmount? = nil`.

What it does (`HummingbirdCore/Server/HTTPUserEventHandler.swift:69-75`):

```swift
        case IdleStateHandler.IdleStateEvent.read:
            // if we get an idle read event and we haven't completed reading the request
            // close the connection, or a request hasnt been initiated
            if self.requestsBeingRead > 0 || self.requestsInProgress == 0 {
                self.logger.trace("Idle read timeout, so close channel")
                context.close(promise: nil)
            }
```

So a read-idle channel is closed only when a request body is still being
read or no request is in progress. An SSE GET whose request has been fully
read and whose response is streaming has `requestsInProgress == 1` and
`requestsBeingRead == 0`, so the idle timer does not close it. A pending
POST waiting on the 300 s `requestTimeout` is in the same state. The idle
timeout is safe to enable without breaking either.

### SSE keep-alive cadence

`swift/Sources/iMessageMax/Server/SSEConnection.swift:79`: production
keep-alive interval is `.seconds(30)`. Not relevant to the read-idle
event (writes do not reset a read-idle timer and the SSE GET is exempt
by state anyway), noted here so nobody "fixes" it.

### Test scaffolding

`swift/Tests/iMessageMaxTests/OversizedBodyTests.swift:10-40` shows the
pattern: `RequestBody.makeStream()` gives a `(body, source)` pair; a
producer `Task` yields chunks with `await source.yield(chunk)` and calls
`source.finish()`; the test calls `HTTPTransport.collectBodyDrainingOverflow(...)`
directly. A test that yields one chunk and never finishes is exactly the
stalled client.

`HTTPTransportIntegrationTests` (18 tests) constructs
`HTTPTransport(host: "127.0.0.1", port: 0, database: Database(), resolver: ContactResolver(seedCache: [:]), requestTimeout: .seconds(5), cleanupInterval: .milliseconds(20))`,
calls `makeApplicationForTesting()`, and drives it with
`app.test(TestingSetup.router)`. The router test harness bypasses the
channel pipeline, so the Hummingbird idle timeout cannot be exercised
there; it is verified by a live-socket test instead (Step 5).

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `cd swift && swift build` | ends in `Build complete!` |
| Focused | `cd swift && swift test --filter "OversizedBodyTests\|BodyReadDeadlineTests\|HTTPTransportIntegrationTests"` | 0 failures |
| Sleep guard | `cd swift && swift test --filter LaunchdSafetyTests` | 1 test, 0 failures |
| Whole suite | `cd swift && swift test` | 370 plus new tests, 0 failures |
| Grep guard | `grep -rn "Task.sleep" swift/Sources` | no output |

## Scope

In scope:

- A `bodyReadDeadline: Duration` on `HTTPTransport` (init parameter,
  default `.seconds(30)`), threaded into the body collector.
- `collectBodyDrainingOverflow` gains a deadline and a new
  `BodyCollection.timedOut` case.
- `handlePost` maps `.timedOut` to HTTP 408 via `errorResponse`.
- `buildApplication()` passes `server: .http1(configuration: .init(idleTimeout: ...))`.
- Tests: unit (stalled stream returns `.timedOut` inside the deadline),
  router-level (408 body shape), and one live-socket test for the channel
  idle timeout.
- `README.md` HTTP transport section: one sentence documenting the 408.

Out of scope:

- A deadline on the SSE GET response stream (it is a long-lived stream by
  design).
- Changing `requestTimeout`, `maxRequestBodyBytes`, or `overLimitDrainBytes`.
- Connection-count caps (`MaximumAvailableConnections`); separate plan if
  wanted.
- Touching `.mcp.json` (never), committing secrets (never), `Task.sleep`
  under `swift/Sources` (never; `LaunchdSafetyTests` enforces it).

## Git workflow

- Branch: `git checkout -b advisor/072-http-body-read-deadline main`.
  If plan 071 has landed, branch from the `main` that contains it.
- Commit 1 (after Step 3): `fix(http): bound request body reads with a 408 deadline`
- Commit 2 (after Step 5): `fix(http): enable Hummingbird idle timeout on the HTTP1 channel`
- Commit 3 (after Step 6): `docs: note the 408 body read deadline`
- Do not push, do not merge.

## Steps

### Step 1: Unit test first (red)

Add `swift/Tests/iMessageMaxTests/BodyReadDeadlineTests.swift`:

```swift
import XCTest
import Hummingbird
import NIOCore
@testable import iMessageMax

final class BodyReadDeadlineTests: XCTestCase {
    func testStalledBodyReturnsTimedOutWithinDeadline() async throws {
        let (body, source) = RequestBody.makeStream()
        let producer = Task {
            await source.yield(ByteBuffer(bytes: [0x7b]))  // "{" then silence
            // Never finish. The collector must give up on its own.
        }
        let start = ContinuousClock.now
        let result = try await HTTPTransport.collectBodyDrainingOverflow(
            body,
            declaredLength: 64,
            maxBytes: HTTPTransport.maxRequestBodyBytes,
            drainLimit: HTTPTransport.overLimitDrainBytes,
            deadline: .milliseconds(200)
        )
        let elapsed = ContinuousClock.now - start
        guard case .timedOut = result else { return XCTFail("Expected .timedOut, got \(result)") }
        XCTAssertLessThan(elapsed, .seconds(2))
        source.finish()
        await producer.value
    }

    func testCompleteBodyIsUnaffectedByDeadline() async throws {
        let (body, source) = RequestBody.makeStream()
        let producer = Task {
            await source.yield(ByteBuffer(string: "{}"))
            source.finish()
        }
        let result = try await HTTPTransport.collectBodyDrainingOverflow(
            body, declaredLength: 2,
            maxBytes: HTTPTransport.maxRequestBodyBytes,
            drainLimit: HTTPTransport.overLimitDrainBytes,
            deadline: .seconds(5)
        )
        guard case .complete(let data) = result else { return XCTFail("Expected .complete") }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{}")
        await producer.value
    }
}
```

If plan 071 landed, call `HTTPRequestParsing.collectBodyDrainingOverflow`
instead and keep the forwarder in sync.

**Verify**: `cd swift && swift build --build-tests` fails with "extra
argument 'deadline' in call". Expected red.

### Step 2: Add the deadline to the collector

Change the signature to add `deadline: Duration` (no default; every caller
passes it explicitly so nobody silently gets "forever"). Add
`case timedOut` to `BodyCollection`.

Implement as a race in a throwing task group. The body iteration moves
into a child task; a second child sleeps with `AsyncTimeout.sleep` and
then throws a private `BodyReadTimeout` error. First result wins;
`group.cancelAll()` cancels the loser. `AsyncTimeout.sleep` honors
cancellation, so a fast body does not leave a 30 s timer running.

```swift
    private struct BodyReadTimeout: Error {}

    nonisolated static func collectBodyDrainingOverflow(
        _ body: RequestBody,
        declaredLength: Int?,
        maxBytes: Int,
        drainLimit: Int,
        deadline: Duration
    ) async throws -> BodyCollection {
        if let declaredLength, declaredLength > drainLimit {
            return .tooLarge
        }
        do {
            return try await withThrowingTaskGroup(of: BodyCollection.self) { group in
                group.addTask {
                    try await readAndDrain(body, maxBytes: maxBytes, drainLimit: drainLimit)
                }
                group.addTask {
                    await AsyncTimeout.sleep(deadline)
                    throw BodyReadTimeout()
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } catch is BodyReadTimeout {
            return .timedOut
        }
    }
```

`readAndDrain` is the existing loop body, unchanged, hoisted into a
private static function. Cancelling the reader task while it is suspended
in `iterator.next()` makes NIO's inbound stream throw `CancellationError`;
`withThrowingTaskGroup` rethrows the first error only, and by then the
timeout has already been returned, so the cancellation error is discarded.
Confirm this by reading the test output: the stalled test must not fail
with `CancellationError`.

**Verify**: `cd swift && swift test --filter "BodyReadDeadlineTests\|OversizedBodyTests"`
reports 6 tests, 0 failures. Update the four existing `OversizedBodyTests`
calls to pass `deadline: .seconds(30)`; they should need no other change.
Run the stalled test five times in a row; it must pass every time.

### Step 3: Wire the transport

- `HTTPTransport.init` gains `bodyReadDeadline: Duration = .seconds(30)`
  stored in `private let bodyReadDeadline`.
- The call site at `:184-196` passes `deadline: bodyReadDeadline` and adds:

```swift
        case .timedOut:
            return errorResponse(status: .requestTimeout, message: "Request body read timed out")
```

- Add a router-level test to `HTTPTransportIntegrationTests`: construct
  the transport with `bodyReadDeadline: .milliseconds(200)`, build a
  `RequestBody.makeStream()` with one yielded byte and no finish, send it
  via `client.executeRequest(uri: "/", method: .post, headers: jsonHeaders(), body: ...)`.
  Check whether `executeRequest` accepts a streaming `RequestBody`; if it
  only accepts `ByteBuffer`, skip this test and rely on Step 1 plus the
  live-socket test in Step 5, and say so in the commit message. Expected
  when it works: status 408, body decodes to JSON with `error.code == -32600`
  and the message above.

**Verify**: `cd swift && swift test --filter "HTTPTransportIntegrationTests\|BodyReadDeadlineTests\|OversizedBodyTests"`
reports 0 failures. `grep -rn "Task.sleep" swift/Sources` prints nothing.
`cd swift && swift test --filter LaunchdSafetyTests` passes. Commit 1.

### Step 4: Enable the channel idle timeout

In `buildApplication()`:

```swift
        return Application(
            router: router,
            server: .http1(configuration: .init(idleTimeout: .seconds(60))),
            configuration: .init(address: .hostname(host, port: port)),
            logger: logger
        )
```

60 s is deliberately longer than the 30 s body deadline so the application
layer answers first with a 408 whenever it can, and the channel timeout
only catches clients that never start a body. Make the value an
`HTTPTransport.init` parameter `channelIdleTimeout: Duration = .seconds(60)`
and convert with `TimeAmount.nanoseconds(Int64(...))` via
`AsyncTimeout.dispatchInterval` or a direct `duration.components` read;
do not write a new saturating conversion, reuse the existing one.

**Verify**: `cd swift && swift build` ends in `Build complete!`. The whole
`HTTPTransportIntegrationTests` filter still passes (the test router does
not touch the channel, so no change is expected; this confirms the init
signature change broke nothing).

### Step 5: Live-socket test for the idle timeout

Add `testIdleChannelIsClosedByServer` to a new
`HTTPTransportLiveSocketTests.swift` (or append to
`HTTPTransportIntegrationTests` if a live-socket test already exists there;
check first with `grep -n "connect()" swift/Tests/iMessageMaxTests/*.swift`).

- Build `HTTPTransport(host: "127.0.0.1", port: 0, ..., channelIdleTimeout: .milliseconds(300))`,
  call `connect()`, discover the bound port. If there is no accessor for
  the bound port when `port: 0` is used, pick a fixed high port for the
  test (`Int.random(in: 40000..<50000)`) and retry once on bind failure.
- Open a raw TCP socket (`Foundation` `URLSession` will not do; use
  NIO's `ClientBootstrap` or POSIX `socket`/`connect` from `Darwin`),
  write `"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n{"` and
  then read. Expect EOF (server closed the connection) within 2 s.
- Also assert the SSE exemption: a second connection that sends a valid
  legacy-lane `initialize` POST, then a GET with `Accept: text/event-stream`
  and the returned `Mcp-Session-Id`, stays open for at least 1 s (three
  idle periods) and receives the `: keep-alive` comment when the
  keep-alive interval is set short. If `SSEConnection`'s keep-alive
  interval is not injectable through `HTTPTransport`, assert only that the
  socket is still open after 1 s and note the gap in the commit message.
- Tear down with `disconnect()`.

No `Task.sleep` in the test; waiting is done by blocking socket reads with
a receive timeout, or `AsyncTimeout.sleep`.

**Verify**: run the new test five times in a row; 0 failures each time.
Then `cd swift && swift test` full suite, 0 failures. Commit 2.

### Step 6: Docs

In `README.md`, find the HTTP transport section (grep for `--port` or
`Streamable HTTP`) and add one sentence: "Request bodies must arrive
within 30 seconds; a stalled upload gets HTTP 408 with a JSON-RPC error
body, and connections idle for 60 seconds are closed." No tool response
shapes change, so `docs/conformance-baseline.yml` and
`ResponseContractTests` are untouched.

**Verify**: `grep -n "408" README.md` shows the new sentence. Commit 3.

## Test plan

- `BodyReadDeadlineTests` (2 new): stalled stream returns `.timedOut`
  inside the deadline; a complete body is unaffected.
- `OversizedBodyTests` (4 existing): pass with the added `deadline:`
  argument and no other edits.
- `HTTPTransportIntegrationTests`: 1 new router-level 408 test if the
  harness supports streaming bodies; all 18 existing tests unchanged.
- Live-socket test (1 or 2 new): idle channel closed; SSE GET survives.
- `LaunchdSafetyTests` green.
- Whole suite: 370 plus 4 to 6 new, 0 failures.

## Done criteria

- [ ] `grep -n "case timedOut" swift/Sources/iMessageMax/Server/*.swift` finds the new case.
- [ ] `grep -n "requestTimeout)" swift/Sources/iMessageMax/Server/HTTPTransport.swift` shows `.requestTimeout` status used for the 408 response.
- [ ] `grep -n "idleTimeout" swift/Sources/iMessageMax/Server/HTTPTransport.swift` finds the `.http1(configuration:)` call.
- [ ] `grep -rn "Task.sleep" swift/Sources` prints nothing.
- [ ] `grep -rn "deadline:" swift/Tests/iMessageMaxTests/OversizedBodyTests.swift | wc -l` is 4.
- [ ] `cd swift && swift test` reports 0 failures, at least 374 tests.
- [ ] Three commits on `advisor/072-http-body-read-deadline`, not pushed.

## STOP conditions

- The drift check shows changes to in-scope files beyond the plan 071 move, and the excerpts no longer match.
- `Application.init(router:server:configuration:logger:)` does not accept `server:` in the checked-out Hummingbird, or `HTTP1Channel.Configuration` has no `idleTimeout`. Report the actual signature.
- The stalled-body unit test fails with `CancellationError` or hangs. Do not add sleeps or retries; report the trace.
- The live-socket test shows the SSE GET being closed by the idle timeout. That contradicts the `HTTPUserEventHandler` reading above; stop and report rather than raising the timeout.
- Any existing `HTTPTransportIntegrationTests` case changes outcome.
- The only way to make it work involves `Task.sleep` or `asyncAfter` without a cancellation path.

## Maintenance notes

- Both timeouts are init parameters on `HTTPTransport`; tests set them
  short, production keeps the defaults. Keep the channel idle timeout
  longer than the body deadline so clients see a 408 rather than a reset.
- The `BodyCollection` enum is the seam: any future body policy (for
  example, per-chunk rate limits) is a new case there, mapped to a status
  in `handlePost`.
- If Hummingbird changes `IdleStateHandler` semantics (for example, starts
  counting write-idle), the live-socket SSE assertion is the test that
  catches it; do not delete it when it gets inconvenient.
