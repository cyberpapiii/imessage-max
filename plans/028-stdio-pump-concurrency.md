# Plan 028: Unblock the stdio pump and surface swallowed write errors

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report, do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat e3d14da..HEAD -- swift/Sources/iMessageMax/Server/DualEraStdioTransport.swift swift/Tests/iMessageMaxTests/DualEraStdioTransportTests.swift`
> Plan 027 lands first and adds an `initialize` guard to the pump, that is
> expected drift; preserve it. Any OTHER structural difference from the
> excerpts is a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: MED (concurrency change on the stdio ingest path)
- **Depends on**: 027 (its era-routing tests are the safety net for this
  refactor and its initialize guard must be preserved)
- **Category**: bug
- **Planned at**: commit `e3d14da`, 2026-08-07

## Why this matters

The dual-era stdio adapter routes every inbound message through one pump
loop. Modern-era messages are dispatched **inline**: the loop `await`s
`ModernDispatcher.handle(...)`, which for `tools/call` runs the actual tool,
before reading the next message. A modern `send` call can legitimately
take ~45 seconds (osascript + transfer polling); during that time nothing
else is read from stdin, so legacy session traffic and further modern
requests all head-of-line block behind it. The legacy lane doesn't have this
problem (messages are yielded downstream and handled elsewhere); the modern
lane should not either, it is stateless by design, so requests are safe to
handle concurrently.

Second defect, same function: responses are written with
`try? await base.send(responseData)`. If writing to stdout fails (closed
pipe, full buffer on a dying client), the error, and the response, vanish
silently: the client hangs waiting for a reply the server believes it sent.
A failed stdout write on a stdio transport is not recoverable noise; it
should at minimum be visible in the log.

## Current state

`swift/Sources/iMessageMax/Server/DualEraStdioTransport.swift` (71 lines,
`actor DualEraStdioTransport: Transport`). The pump as of `e3d14da`
(`:33-56`), after plan 027 the `if let json` condition also excludes
`initialize`; keep that:

```swift
    func connect() async throws {
        try await base.connect()
        let upstream = await base.receive()
        let base = self.base
        let continuation = self.continuation
        pumpTask = Task {
            do {
                for try await data in upstream {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                        ModernDispatcher.isModernMessage(json) {
                        let result = await ModernDispatcher.handle(data, transport: "stdio")
                        if let responseData = result.data {
                            try? await base.send(responseData)
                        }
                        continue
                    }
                    continuation.yield(data)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func disconnect() async {
        pumpTask?.cancel()
        await base.disconnect()
        continuation.finish()
    }
```

Deployment target: `Package.swift` declares `.macOS(.v14)`, so
`withDiscardingTaskGroup` (macOS 14 API) is available.

Stderr-logging precedent in this repo:
`FileHandle.standardError.write(Data("...".utf8))`, see
`Server/MCPServer.swift:46`.

Tests: `swift/Tests/iMessageMaxTests/DualEraStdioTransportTests.swift` with
the `FakeBaseTransport` actor double (`feed(_:)`, `sentCount()`,
`waitForFirstSend()`), plus the era-matrix tests plan 027 added. Plan 019's
`LaunchdSafetyTests` forbids `Task.sleep(` in Sources, the design below
introduces none.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| stdio tests | `cd swift && swift test --filter DualEraStdioTransportTests` | all pass |
| Full suite | `cd swift && swift test` | exit 0, 0 failures |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Server/DualEraStdioTransport.swift`
- `swift/Tests/iMessageMaxTests/DualEraStdioTransportTests.swift`
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):
- `ModernDispatcher` internals, plan 030.
- The HTTP transport's modern path (it already handles requests
  per-HTTP-request, no head-of-line issue).
- Era-selection rules, locked by plan 027's tests; behavior must be
  identical, only *when* modern work runs changes.
- The legacy passthrough ordering, legacy messages MUST stay strictly
  ordered (the SDK session protocol depends on it).

## Git workflow

- Branch: `advisor/028-stdio-pump-concurrency`
- Conventional commits, e.g. `fix: handle modern stdio messages concurrently; log stdout write failures`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Restructure the pump around a discarding task group

Replace the pump body so modern messages are handled in child tasks while
the loop keeps reading. Target shape (adapt to 027's guard):

```swift
        pumpTask = Task {
            await withDiscardingTaskGroup { group in
                do {
                    for try await data in upstream {
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                            (json["method"] as? String) != "initialize",
                            ModernDispatcher.isModernMessage(json) {
                            // Modern lane is stateless: safe to handle
                            // concurrently. Never block the read loop on a
                            // tool call.
                            group.addTask {
                                let result = await ModernDispatcher.handle(data, transport: "stdio")
                                if let responseData = result.data {
                                    do {
                                        try await base.send(responseData)
                                    } catch {
                                        FileHandle.standardError.write(
                                            Data("[iMessage Max] stdio write failed; response dropped: \(error)\n".utf8)
                                        )
                                    }
                                }
                            }
                            continue
                        }
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
```

Notes for the executor:

- `withDiscardingTaskGroup` keeps running children after the loop ends and
  waits for them before returning, in-flight modern requests complete even
  if stdin closes first. Cancelling `pumpTask` (in `disconnect`) cancels the
  group and its children; that is the intended shutdown path.
- Interleaved responses on stdout are safe: each `base.send` writes one
  complete JSON-RPC message (the SDK stdio transport frames per call), and
  JSON-RPC ids do the correlation. Do NOT add ordering machinery.
- If the compiler requires it, hoist `let base`/`let continuation` captures
  exactly as the current code does.

**Verify**: `cd swift && swift build` → exit 0;
`cd swift && swift test --filter DualEraStdioTransportTests` → all pass
(027's matrix proves era behavior is unchanged).

### Step 2: Add the concurrency test

Add to `DualEraStdioTransportTests.swift`:

`testSlowModernCallDoesNotBlockSubsequentMessages`,

1. Register (via the fake-tool mechanism from 027's tests /
   `ModernDispatcherTests`) a `slow_tool` whose handler awaits a signal
   before returning: use an `AsyncStream`/continuation or an actor-based
   gate. NOT `Task.sleep` timing guesses:

```swift
        let gate = AsyncStream<Void>.makeStream()
        registerFakeTool(named: "slow_tool") { _ in
            var iterator = gate.stream.makeAsyncIterator()
            _ = await iterator.next()   // parks until the test opens the gate
            return [.plainText("done")]
        }
```

2. Feed a modern `tools/call` for `slow_tool`, then immediately feed a
   legacy message.
3. Assert the legacy message arrives downstream (via the receive iterator)
   **while** the slow call is still parked (`sentCount() == 0` at that
   moment).
4. Open the gate (`gate.continuation.yield(())`), then
   `waitForFirstSend()` and assert the slow tool's response was written.

Also add `testWriteFailureIsSwallowedButLogged` only if `FakeBaseTransport`
can be made to throw from `send` in ≤10 lines (add a `var failNextSend`
flag); assert the pump survives (a subsequent modern discover still gets
answered). The stderr line itself isn't assertable in-process, the
surviving-pump behavior is the testable part.

**Verify**: `cd swift && swift test --filter DualEraStdioTransportTests` →
all pass, 1–2 new tests.

### Step 3: Full suite

**Verify**: `cd swift && swift test` → exit 0, 0 failures. Also
`swift test --filter LaunchdSafetyTests` → green (no `Task.sleep`
introduced).

## Test plan

Step 2. Exemplars: `DualEraStdioTransportTests.swift` FakeBaseTransport
pattern; `ModernDispatcherTests.swift:236` fake-tool registration.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` exits 0; 0 failures; ≥1 net-new test
- [ ] `grep -n "try? await base.send" swift/Sources/iMessageMax/Server/DualEraStdioTransport.swift` → no matches
- [ ] `grep -n "withDiscardingTaskGroup" swift/Sources/iMessageMax/Server/DualEraStdioTransport.swift` → 1 match
- [ ] Plan 027's era-matrix tests all still pass unmodified
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Plan 027 has not landed (no initialize guard, no matrix tests), land
  order matters; report.
- `withDiscardingTaskGroup` is unavailable at the deployment target the
  package actually builds with, report; fall back is a plain
  `withTaskGroup` + manual draining, but confirm before diverging.
- The concurrency test is flaky (ordering assumptions fail intermittently),
  do not paper over with sleeps; report the interleaving you observed.
- You need to modify any 027 test to keep it green, behavior drifted;
  report.

## Maintenance notes

- Invariant: **the pump loop never awaits request handling**, it only
  parses, routes, yields, and spawns. Anything slow belongs in a child task.
- Legacy ordering remains strict FIFO through `continuation.yield`; modern
  responses may interleave on stdout by design. If a future modern feature
  becomes stateful/order-sensitive, this decision must be revisited.
- Plan 030 touches `ModernDispatcher.serialize`/logging; no interaction with
  this pump beyond the `handle` call signature staying the same.
