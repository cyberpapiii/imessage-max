# Plan 027: Complete the era-routing test matrix + align stdio initialize routing with HTTP

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat e3d14da..HEAD -- swift/Sources/iMessageMax/Server/DualEraStdioTransport.swift swift/Tests/iMessageMaxTests/DualEraStdioTransportTests.swift swift/Tests/iMessageMaxTests/ModernHTTPIntegrationTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW (one guard line + tests)
- **Depends on**: none. **Ordering**: land BEFORE plan 028 (which
  restructures the same stdio pump; this plan's tests then protect that
  refactor).
- **Category**: tests (+ one small correctness alignment)
- **Planned at**: commit `e3d14da`, 2026-08-07

## Why this matters

The server speaks two protocol eras: the legacy SDK session lane and the
modern stateless MCP 2026-07-28 lane, with era selection at each transport
boundary. Existing coverage is good but has holes exactly where regressions
would be silent: the stdio lane only tests `server/discover` (never a modern
`tools/list`/`tools/call`/notification end-to-end), and neither transport
locks the rule for an `initialize` request that carries the modern `_meta`
protocolVersion key. Worse, the two transports currently *disagree* on that
rule: HTTP explicitly keeps `initialize` on the legacy lane no matter what
the body carries, while the stdio pump has no such guard — an initialize
with modern `_meta` would be swallowed by the dispatcher and returned as
`method not found`, and the SDK Server would never see the handshake. No
real client sends that today, which is exactly why only a test will keep it
true. This plan adds the one-line stdio guard to match HTTP and fills the
matrix so plan 028's pump rewrite (and any future era work) has a safety
net.

## Current state

### The divergence

HTTP era selection (`swift/Sources/iMessageMax/Server/HTTPTransport.swift:214-220`):

```swift
        // Era selection (dual-era server, MCP 2026-07-28 backward-compat
        ...
        // stateless 2026-07-28 lane. Only the BODY selects the era. Real
        ...
        if !isInitialize, ModernDispatcher.isModernMessage(json) {
```

stdio pump (`swift/Sources/iMessageMax/Server/DualEraStdioTransport.swift:38-55`) —
note: no initialize exclusion:

```swift
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
```

Era detection (`swift/Sources/iMessageMax/Server/ModernProtocol.swift:58-62`):
modern ⇔ `method == "server/discover"` OR params.`_meta` contains
`io.modelcontextprotocol/protocolVersion`.

### Existing coverage (do not duplicate)

- `ModernDispatcherTests.swift` — dispatcher unit level: detection (`:22`),
  discover, `_meta` validation, version negotiation, tools/list ordering +
  cache hints, tools/call complete/isError/unknown, notifications, base64
  sentinel. Helpers: `ToolHandlerRegistry.shared.resetForTesting()` in
  setUp/tearDown (`:10-18`), `registerFakeTool(named:handler:)` (`:236`),
  `modernRequest(method:extraParams:)`, `discoverPayload()`,
  `result(from:)`/`error(from:)`.
- `ModernHTTPIntegrationTests.swift` — HTTP: discover, tools/list,
  tools/call (+ base64 name), header-mismatch cases, unsupported version,
  unknown method, notification 202, "legacy request with modern *headers*
  stays legacy" (`:249`), legacy session flow alongside modern (`:282`).
- `DualEraStdioTransportTests.swift` — stdio: modern discover answered
  directly + legacy initialize passes through (`:11-46`), send passthrough
  (`:48-60`). Test double: `FakeBaseTransport` actor (`:65-117`) with
  `feed(_:)`, `sentCount()`, `waitForFirstSend()`.

### The matrix cells that are MISSING

| # | Transport | Message | Expected | Exists? |
|---|-----------|---------|----------|---------|
| 1 | stdio | modern `tools/list` (with `_meta`) | answered directly by dispatcher; catalog result; never forwarded downstream | NO |
| 2 | stdio | modern `tools/call` of a registered fake tool | answered directly; `resultType: complete`; never forwarded | NO |
| 3 | stdio | modern notification (no `id`, with `_meta`) | consumed: no response written AND not forwarded downstream | NO |
| 4 | stdio | `initialize` carrying modern `_meta` protocolVersion | passes through to legacy lane (after Step 1's guard) | NO — currently swallowed by dispatcher |
| 5 | HTTP | `initialize` whose BODY carries modern `_meta` protocolVersion | stays on legacy lane (SDK handshake response, not a dispatcher error) | NO (only the modern-*headers* variant is tested) |
| 6 | stdio | non-JSON / unparseable line | forwarded downstream untouched (SDK owns legacy error shape) | NO |

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| stdio tests | `cd swift && swift test --filter DualEraStdioTransportTests` | all pass |
| HTTP tests | `cd swift && swift test --filter ModernHTTPIntegrationTests` | all pass |
| Full suite | `cd swift && swift test` | exit 0, 0 failures |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Server/DualEraStdioTransport.swift` (the guard only)
- `swift/Tests/iMessageMaxTests/DualEraStdioTransportTests.swift`
- `swift/Tests/iMessageMaxTests/ModernHTTPIntegrationTests.swift`
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):
- Pump concurrency / `try?` write-error swallowing in the stdio pump — plan 028.
- `ModernDispatcher` internals (encode failures, logEra, caching) — plan 030.
- `HTTPTransport` era-selection code — already correct; tests only.
- `isModernMessage` detection logic — the guard goes at the *transport*
  boundary (matching HTTP's structure), not inside detection.

## Git workflow

- Branch: `advisor/027-era-routing-test-matrix`
- Conventional commits, e.g. `test: complete era-routing matrix; fix: keep stdio initialize on the legacy lane`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Align the stdio initialize rule with HTTP

In the pump in `DualEraStdioTransport.connect()`, add the same
initialize exclusion HTTP has:

```swift
                for try await data in upstream {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                        (json["method"] as? String) != "initialize",
                        ModernDispatcher.isModernMessage(json) {
```

Also update the file-header comment (`:3-8`) to mention that `initialize`
always stays on the legacy lane, mirroring HTTP.

**Verify**: `cd swift && swift build` → exit 0; existing
`DualEraStdioTransportTests` still pass.

### Step 2: Fill the stdio cells (matrix rows 1, 2, 3, 4, 6)

Add to `DualEraStdioTransportTests.swift`, all following the existing
`FakeBaseTransport` + `feed`/`waitForFirstSend` pattern of `:11-46`. For
rows 1–2, mirror `ModernDispatcherTests`'s registry lifecycle: add the same
`setUp`/`tearDown` calling `ToolHandlerRegistry.shared.resetForTesting()`,
and reuse its fake-tool registration approach (copy the minimal
`registerFakeTool` helper if it isn't shared — check whether it's `private`
to that file; if so, inline a local equivalent, ~10 lines).

1. `testModernToolsListIsAnsweredDirectly` — feed a modern `tools/list`
   (copy the `_meta` JSON shape from the discover payload at `:19-22`);
   assert the response's `result.tools` exists, `sentCount() == 1`, and
   nothing was forwarded downstream (drain check as in `:40-43`).
2. `testModernToolCallIsAnsweredDirectly` — register `stdio_echo` fake tool;
   feed modern `tools/call` with `"name": "stdio_echo"`; assert
   `result.resultType == "complete"` and no downstream forward.
3. `testModernNotificationIsConsumedSilently` — feed a modern-shaped message
   **without** `id`; then feed a legacy message; assert the *first* thing
   forwarded downstream is the legacy message (the notification neither got
   a reply — `sentCount() == 0` — nor was forwarded).
4. `testInitializeWithModernMetaStaysLegacy` — feed an `initialize` whose
   params include `_meta` with the modern protocolVersion key; assert it is
   forwarded downstream verbatim and `sentCount() == 0`.
5. `testUnparseableLinePassesThroughToLegacyLane` — feed
   `Data("not json".utf8)`; assert forwarded downstream verbatim,
   `sentCount() == 0`.

**Verify**: `cd swift && swift test --filter DualEraStdioTransportTests` →
all pass (5 new + 2 existing).

### Step 3: Fill the HTTP cell (matrix row 5)

Add to `ModernHTTPIntegrationTests.swift`, modeled directly on
`testLegacyRequestWithModernHeadersStaysOnLegacyLane` (`:249`):

`testInitializeWithModernMetaInBodyStaysLegacy` — POST an `initialize`
request whose **body** params carry
`"_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28", ...}`
alongside the normal legacy initialize fields; assert the response is a
legacy SDK initialize result (has `result.protocolVersion` and a session
header, matching whatever the `:282` legacy-flow test asserts) — NOT a
dispatcher error and NOT a 4xx.

**Verify**: `cd swift && swift test --filter ModernHTTPIntegrationTests` → all pass (1 new).

### Step 4: Full suite

**Verify**: `cd swift && swift test` → exit 0, 0 failures, ≥6 net-new tests.

## Test plan

This plan IS the test plan — 6 new tests enumerated above. Exemplars:
`DualEraStdioTransportTests.swift:11-46`,
`ModernHTTPIntegrationTests.swift:249-281`,
`ModernDispatcherTests.swift:10-18` + `:236` (registry lifecycle + fake tool).

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` exits 0; 0 failures; ≥6 net-new tests
- [ ] `grep -n "initialize" swift/Sources/iMessageMax/Server/DualEraStdioTransport.swift` → the guard is present in the pump
- [ ] Every row of the matrix table above has a named test (map them in the commit message)
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Plan 028 landed first and the pump no longer matches the excerpt — the
  guard then belongs wherever the era branch moved; report and coordinate.
- Row-4 or row-5 tests fail *after* Step 1 — that means era selection
  differs from this plan's model of it; report the actual behavior, do not
  force the test green.
- `FakeBaseTransport` can't express a needed assertion (e.g. ordered
  downstream + sent interleaving) without redesign — extend it minimally;
  if that grows past ~20 lines, report.

## Maintenance notes

- These tests are the contract for era selection: **body decides; initialize
  is always legacy; unparseable lines are legacy-lane traffic.** Plan 028
  must keep them green through the pump rewrite; any future third era joins
  this matrix.
- If the SDK ever ships native 2026-07-28 support and the modern lane is
  migrated to it, this matrix is the acceptance suite for that migration.
