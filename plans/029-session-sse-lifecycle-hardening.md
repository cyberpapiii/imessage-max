# Plan 029: Session/SSE lifecycle hardening, honest createSession errors, single-consumption SSE stream, injectable TTL

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report, do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat e3d14da..HEAD -- swift/Sources/iMessageMax/Server/SessionManager.swift swift/Sources/iMessageMax/Server/SSEConnection.swift swift/Sources/iMessageMax/Server/HTTPTransport.swift`
> Plan 019 lands first and swaps the two `Task.sleep` calls in these files
> for `AsyncTimeout.sleep`, expected drift; preserve it. Any other
> structural mismatch with the excerpts is a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED (touches the legacy HTTP session plumbing)
- **Depends on**: 019 (keep-alive sleep swap must be preserved through the
  SSEChannel restructure)
- **Category**: bug + tests
- **Planned at**: commit `e3d14da`, 2026-08-07

## Why this matters

Three lifecycle defects in the legacy HTTP session lane:

1. **Start failures masquerade as capacity limits.** `createSession` returns
   `nil` both when the 100-session cap is hit AND when the per-session SDK
   `Server.start` throws. The caller can only answer 503 "Too many active
   sessions. Try again later.", so an internal startup failure (a bug, a
   bad transport state) tells every client to retry against a server that
   will never succeed, and the real error is swallowed without a log line.
2. **`SSEChannel.stream` is a computed property that spawns tasks per
   access.** Each access builds a *new* `AsyncStream` and a new
   forwarding/keep-alive task group over the same single-consumer base
   stream. A second access silently competes for events (AsyncStream is
   single-consumer: whichever iterator polls first steals the event) and
   leaks a task group per access. It works today only because exactly one
   call site accesses it exactly once, nothing enforces or documents that.
3. **Session TTL is untestable.** `sessionTimeout` (3600s) and `maxSessions`
   (100) are hardcoded `let`s, so expiry-cleanup behavior, the code plan
   019 keeps alive every 5 minutes forever, has zero test coverage.

## Current state

### createSession (`swift/Sources/iMessageMax/Server/SessionManager.swift:82-139`)

```swift
    func createSession(protocolVersion: String = MCPProtocolVersion.defaultAssumed) async -> MCPSessionState? {
        guard sessions.count < maxSessions else {
            return nil  // Caller returns 503 Service Unavailable
        }
        ...
        do {
            try await server.start(transport: adapter)
        } catch {
            session.messageContinuation.finish()
            return nil
        }

        session.serverTask = Task {
            await server.waitUntilCompleted()
        }

        sessions[sessionId] = session
        return session
    }
```

Constants at `:40-43`:

```swift
    /// Session timeout duration (1 hour)
    private let sessionTimeout: TimeInterval = 3600

    /// Maximum number of concurrent sessions
    private let maxSessions = 100
```

Init at `:60-63` takes `(database:resolver:)`. Cleanup:
`cleanupExpiredSessions` at `:238` compares `lastActivity` against
`sessionTimeout`; the loop task at `:228-235` (post-019: `AsyncTimeout.sleep`).

### The caller (`swift/Sources/iMessageMax/Server/HTTPTransport.swift:247-255`)

```swift
            guard let session = await sessionManager.createSession(
                protocolVersion: requestedProtocolVersion ?? MCPProtocolVersion.latest
            ) else {
                return errorResponse(
                    status: .serviceUnavailable,
                    message: "Too many active sessions. Try again later."
                )
            }
```

### SSEChannel (`swift/Sources/iMessageMax/Server/SSEConnection.swift:87-136`)

```swift
final class SSEChannel: @unchecked Sendable {
    private let continuation: AsyncStream<String>.Continuation
    private let _stream: AsyncStream<String>

    /// The event stream with interleaved keep-alives
    var stream: AsyncStream<String> {
        let baseStream = _stream
        return AsyncStream { continuation in
            Task {
                // Merge events with keep-alives
                await withTaskGroup(of: Void.self) { group in
                    // Event forwarding task
                    group.addTask {
                        for await event in baseStream {
                            continuation.yield(event)
                        }
                        continuation.finish()
                    }

                    // Keep-alive task
                    group.addTask {
                        while !Task.isCancelled {
                            await AsyncTimeout.sleep(.seconds(30))   // post-019 shape
                            if Task.isCancelled { break }
                            continuation.yield(SSEEvent.keepAlive())
                        }
                    }

                    // Wait for event stream to finish, then cancel keep-alive
                    await group.next()
                    group.cancelAll()
                }
            }
        }
    }

    init() {
        var cont: AsyncStream<String>.Continuation!
        self._stream = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    func send(_ event: String) { continuation.yield(event) }
    func close() { continuation.finish() }
}
```

`SSEConnectionManager` (same file, `:139-221`) is an actor with
register/unregister/broadcast/terminateSession, sound as-is; only its
`register` creates `SSEChannel()`.

Existing tests: `swift/Tests/iMessageMaxTests/HTTPTransportTests.swift` has
`SSEEventTests` and `SSEConnectionManagerTests` (register/unregister/counts),
extend these, don't duplicate. `HTTPTransportIntegrationTests.swift:1-90`
shows the Hummingbird `app.test` pattern for endpoint-level tests.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| Transport tests | `cd swift && swift test --filter HTTPTransportTests` | all pass |
| Integration | `cd swift && swift test --filter HTTPTransportIntegrationTests` | all pass |
| Full suite | `cd swift && swift test` | exit 0, 0 failures |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Server/SessionManager.swift`
- `swift/Sources/iMessageMax/Server/SSEConnection.swift`
- `swift/Sources/iMessageMax/Server/HTTPTransport.swift` (the one createSession call site + its error mapping)
- `swift/Tests/iMessageMaxTests/HTTPTransportTests.swift`
- `swift/Tests/iMessageMaxTests/HTTPTransportIntegrationTests.swift`
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):
- The pending-request/timeout machinery in HTTPTransport, plan 020.
- `AsyncTimeout` and the 019 sleep swaps, preserve verbatim.
- SSE resumption (`lastEventId` is stored but unused), a feature, not this fix.
- The SDK `Server`/`SessionTransportAdapter` interaction beyond the error split.

## Git workflow

- Branch: `advisor/029-session-sse-lifecycle`
- Conventional commits, e.g. `fix: split createSession failures from capacity; make SSE stream single-shot; inject session TTL`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Split createSession outcomes

In `SessionManager.swift`:

1. Add above the actor:

```swift
/// Outcome of createSession: capacity refusal and startup failure need
/// different HTTP answers (503 retry-later vs 500 internal).
enum SessionCreationResult {
    case created(SessionManager.MCPSessionState)
    case atCapacity
    case startFailed(Error)
}
```

(Adjust namespacing to however `MCPSessionState` is declared, it is a
nested class of the actor; if nesting fights the compiler, declare the enum
inside the actor.)

2. Change the signature to
   `func createSession(protocolVersion: String = ...) async -> SessionCreationResult`,
   returning `.atCapacity` at the cap, `.startFailed(error)` in the catch
   (keep the `messageContinuation.finish()`), `.created(session)` at the end.

3. In the catch, also log:
   `FileHandle.standardError.write(Data("[iMessage Max] session Server.start failed: \(error)\n".utf8))`.

4. Update the caller in `HTTPTransport.swift:247-255`:

```swift
            switch await sessionManager.createSession(
                protocolVersion: requestedProtocolVersion ?? MCPProtocolVersion.latest
            ) {
            case .created(let session):
                sessionId = session.id
                ... (existing success body)
            case .atCapacity:
                return errorResponse(
                    status: .serviceUnavailable,
                    message: "Too many active sessions. Try again later."
                )
            case .startFailed:
                return errorResponse(
                    status: .internalServerError,
                    message: "Failed to start session. Check the server log."
                )
            }
```

(Restructure the surrounding `if isInitialize` block minimally; `sessionId`
assignment and the success-path logging move inside `.created`.)

**Verify**: `cd swift && swift build` → exit 0; existing integration tests pass.

### Step 2: Make the SSE stream single-shot and stored

In `SSEConnection.swift`, replace the computed `stream` with a
once-per-channel merged stream created in `init`:

```swift
final class SSEChannel: @unchecked Sendable {
    private let continuation: AsyncStream<String>.Continuation

    /// The event stream with interleaved keep-alives. Single-consumer:
    /// built once at init; consume it exactly once.
    let stream: AsyncStream<String>

    init(keepAliveInterval: Duration = .seconds(30)) {
        var cont: AsyncStream<String>.Continuation!
        let baseStream = AsyncStream<String> { cont = $0 }
        self.continuation = cont

        self.stream = AsyncStream { downstream in
            let merger = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await event in baseStream {
                            downstream.yield(event)
                        }
                        downstream.finish()
                    }
                    group.addTask {
                        while !Task.isCancelled {
                            await AsyncTimeout.sleep(keepAliveInterval)
                            if Task.isCancelled { break }
                            downstream.yield(SSEEvent.keepAlive())
                        }
                    }
                    await group.next()
                    group.cancelAll()
                }
            }
            downstream.onTermination = { _ in
                merger.cancel()
            }
        }
    }

    func send(_ event: String) { continuation.yield(event) }
    func close() { continuation.finish() }
}
```

Key differences from today: one merger per channel (not per access);
`onTermination` cancels the merger when the HTTP response body iterator is
dropped (client disconnect), so the keep-alive loop doesn't spin until its
next tick against a dead stream. Note `AsyncTimeout.sleep` is
non-cancellable, cancellation takes effect at the next interval boundary;
that is the accepted 019 trade.

The `keepAliveInterval` parameter (default 30s) is the test seam; production
call sites (`SSEConnectionManager.register`) stay `SSEChannel()`.

**Verify**: `cd swift && swift build` → exit 0.

### Step 3: Inject the SessionManager TTL and cap

Change the init (`SessionManager.swift:60-63`) to:

```swift
    init(
        database: Database,
        resolver: ContactResolver,
        sessionTimeout: TimeInterval = 3600,
        maxSessions: Int = 100
    ) {
        self.database = database
        self.resolver = resolver
        self.sessionTimeout = sessionTimeout
        self.maxSessions = maxSessions
    }
```

and make the two properties non-default `let`s. Expose a test hook for
cleanup: make `cleanupExpiredSessions()` internal (drop `private`) with a
doc comment saying it exists for the timer loop and tests.

**Verify**: `cd swift && swift build` → exit 0 (production call sites use
the defaults).

### Step 4: Tests

1. **SSEChannel unit tests** (add a class near `SSEConnectionManagerTests`
   in `HTTPTransportTests.swift`):
   - `testEventsFlowAndCloseFinishes`, send two events, close; iterate
     `channel.stream`, assert both arrive then the stream ends.
   - `testKeepAlivesInterleave`, `SSEChannel(keepAliveInterval: .milliseconds(20))`,
     send nothing; iterate and assert the first item is
     `SSEEvent.keepAlive()` (bounded: take 1 item, don't loop forever).
   - `testStreamPropertyIsStable`, `channel.stream` accessed twice returns
     the same instance semantics: send one event, read it from a single
     iterator; assert a second `channel.stream` access doesn't compile-break
     or steal (with a stored `let` this is trivially true, the test
     documents the contract).
2. **SessionManager tests** (new class in `HTTPTransportTests.swift`):
   - `testCreateSessionAtCapacityReturnsAtCapacity`,
     `SessionManager(database: Database(), resolver: ContactResolver(seedCache: [:]), maxSessions: 1)`
     (copy constructor args from `HTTPTransportIntegrationTests.swift:1-90`);
     create one session (assert `.created`), then a second (assert
     `.atCapacity`).
   - `testExpiredSessionIsCleanedUp`, `sessionTimeout: 0.01`; create a
     session, wait ~50ms (`try await Task.sleep` is fine in *tests*; the 019
     tripwire only scans Sources/), call `cleanupExpiredSessions()`, assert
     `routeMessage(sessionId:data:)` now returns false.
3. **Endpoint test** (in `HTTPTransportIntegrationTests.swift`): initialize
   flow already covered; add `testInitializeStartFailureReturns500` ONLY if
   a failure can be induced through existing seams (it likely cannot,
   `Server.start` won't fail with a healthy adapter). If not cleanly
   inducible, skip it and note in the commit message; the enum split is
   covered by the SessionManager unit tests plus the compile-checked caller
   switch.

**Verify**: `cd swift && swift test --filter HTTPTransportTests` → all pass,
≥5 new tests.

### Step 5: Full suite

**Verify**: `cd swift && swift test` → exit 0, 0 failures.

## Test plan

Step 4. Exemplars: `SSEConnectionManagerTests` (same file),
`HTTPTransportIntegrationTests.swift:1-90` (constructor + app.test pattern).

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` exits 0; 0 failures; ≥5 net-new tests
- [ ] `grep -n "var stream" swift/Sources/iMessageMax/Server/SSEConnection.swift` → no matches (`let stream` instead)
- [ ] `grep -n "onTermination" swift/Sources/iMessageMax/Server/SSEConnection.swift` → ≥1 match
- [ ] `grep -n "SessionCreationResult" swift/Sources/iMessageMax/Server/SessionManager.swift swift/Sources/iMessageMax/Server/HTTPTransport.swift` → both files match
- [ ] `grep -n "Too many active sessions" swift/Sources/iMessageMax/Server/HTTPTransport.swift` → still present (capacity path unchanged)
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Plan 019 hasn't landed (keep-alive still uses `Task.sleep`), order matters.
- The `stream` restructure breaks SSE delivery in
  `HTTPTransportIntegrationTests` or the GET-endpoint path (`handleGet`,
  `HTTPTransport.swift:467`) in a way that needs `handleGet` changes beyond
  mechanical renames, report before touching response streaming.
- `MCPSessionState` nesting makes the result enum awkward enough that you
  want to restructure the state class, don't; report.
- Flaky timing in the new tests, prefer raising the wait bound once; if
  still flaky, report rather than adding retries.

## Maintenance notes

- Contract: **`SSEChannel.stream` is consumed exactly once per channel**;
  the stored-`let` + onTermination design enforces the cost even if a second
  consumer appears (it would just see nothing, same AsyncStream semantics,
  but no longer leaks task groups).
- The `keepAliveInterval` and `sessionTimeout`/`maxSessions` seams exist for
  tests; production always uses defaults. Flag any production call site that
  starts passing custom values in review.
- SSE resumption via `lastEventId` remains unimplemented; if built later, it
  changes this channel design (buffering), revisit then.
