# Plan 030: Modern dispatcher robustness, id-preserving fallbacks, sanitized era log, cached catalog

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report, do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat e3d14da..HEAD -- swift/Sources/iMessageMax/Server/ModernProtocol.swift swift/Sources/iMessageMax/Server/ServerExtensions.swift swift/Tests/iMessageMaxTests/ModernDispatcherTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW-MED (hot-path serialization changes, well covered by existing dispatcher tests)
- **Depends on**: none (independent of 027/028; touches different functions)
- **Category**: bug + security + perf
- **Planned at**: commit `e3d14da`, 2026-08-07

## Why this matters

Three defects in the modern (MCP 2026-07-28) dispatcher:

1. **Encode failures silently corrupt responses.** `serialize` falls back to
   a hardcoded `id:null` error envelope, a client correlating by request id
   waits forever on what looks like someone else's error. `contentJSON`
   returns `[]` on encode failure, turning a *successful* tool call into an
   empty-content success. `toolsJSON` returns `[]`, presenting an empty
   catalog as valid. All three lose the failure without a log line.
2. **The era log line trusts client input.** `logEra` interpolates
   client-supplied `clientInfo.name`/`version` into a structured stderr line
   with no length bound and no control-character stripping, a client can
   inject `\n` to forge log lines or dump megabytes into the service log.
   (The legacy lane's equivalent header-interpolation issue is fixed by plan
   020; this is the modern lane's copy.)
3. **The tool catalog is re-encoded on every request.** `toolsListResult`
   JSON-encodes all ~13 tool schemas per `tools/list`, and every single
   response (including each `tools/call`) rebuilds `serverInfoJSON`/icons.
   The dispatcher's own cache hints (`ttlMs` 3600000) tell clients the
   catalog is static for an hour; the server should believe itself and
   memoize, invalidating on registry change.

## Current state

All excerpts from `swift/Sources/iMessageMax/Server/ModernProtocol.swift`
at `e3d14da`.

Serialization + fallback (`:290-324`):

```swift
    private static func successResult(id: Any, result: [String: Any]) -> ModernDispatchResult {
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ]
        return ModernDispatchResult(data: serialize(envelope), httpStatus: 200)
    }

    static func errorResult(
        id: Any?, code: Int, message: String,
        data: [String: Any]? = nil, httpStatus: Int
    ) -> ModernDispatchResult {
        ...
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": error,
        ]
        return ModernDispatchResult(data: serialize(envelope), httpStatus: httpStatus)
    }

    private static func serialize(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object))
            ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
    }
```

Encode helpers that swallow failures (`:248-269`): `iconsJSON()` (nil on
failure, acceptable, icons are optional), `toolsJSON()` (`[]` on failure),
`contentJSON(_:)` (`[]` on failure).

The era log (`:330-341`):

```swift
    private static func logEra(transport: String, version: String, method: String, meta: [String: Any]) {
        var client = "unknown"
        if let info = meta[ModernMetaKey.clientInfo] as? [String: Any],
            let name = info["name"] as? String {
            let clientVersion = info["version"] as? String ?? "?"
            client = "\(name)/\(clientVersion)"
        }
        FileHandle.standardError.write(
            "[iMessage Max] era=modern transport=\(transport) version=\(version) method=\(method) client=\(client)\n"
                .data(using: .utf8)!
        )
    }
```

Note `version` here is also client-supplied but is only reachable after the
`ModernProtocolVersion.supported.contains(...)` guard (`:126`), so it is
already constrained to `"2026-07-28"`; only `client` needs sanitizing.
`method` reaches the log for any supported-version request, including
unknown methods, clamp it too.

Catalog builders (`:185-191`, `:256-262`):

```swift
    private static func toolsListResult() -> [String: Any] {
        var result = completeResult()
        result["tools"] = toolsJSON()
        ...
    }

    private static func toolsJSON() -> [[String: Any]] {
        let tools = ToolHandlerRegistry.shared.getTools()
        guard let data = try? JSONEncoder().encode(tools),
            let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return json
    }
```

The registry (`swift/Sources/iMessageMax/Server/ServerExtensions.swift:117-160`):
`final class ToolHandlerRegistry: @unchecked Sendable`, singleton `shared`,
`NSLock`-guarded `tools`/`registrationOrder`/`handlers`, with `register(...)`
(`:127`), `getTools()` (`:143`), `getHandler(for:)` (`:149`),
`resetForTesting()` (`:155`).

Tests: `swift/Tests/iMessageMaxTests/ModernDispatcherTests.swift`, resets
the registry in setUp/tearDown (`:10-18`), `registerFakeTool` helper
(`:236`), and existing assertions on discover/tools-list/call shapes that
must all stay green.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| Dispatcher tests | `cd swift && swift test --filter ModernDispatcherTests` | all pass |
| HTTP modern tests | `cd swift && swift test --filter ModernHTTPIntegrationTests` | all pass |
| Full suite | `cd swift && swift test` | exit 0, 0 failures |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Server/ModernProtocol.swift`
- `swift/Sources/iMessageMax/Server/ServerExtensions.swift` (registry
  version counter only)
- `swift/Tests/iMessageMaxTests/ModernDispatcherTests.swift`
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):
- `ServerExtensions.swift:239` legacy `Error:` wrapper, legacy lane.
- HTTP header validation / `errorResponse` in HTTPTransport, plan 020.
- The stdio pump, plan 028.
- `callTool`'s unknown-tool `-32602` choice, spec-conformant enough; leave.
- Changing the catalog cache *hints* (ttlMs/cacheScope values).

## Git workflow

- Branch: `advisor/030-modern-dispatcher-robustness`
- Conventional commits, e.g. `fix: preserve request id in serialize fallback; sanitize era log; cache tool catalog`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Make serialization failures loud and id-preserving

Replace `serialize` with a variant that keeps correlation and logs:

```swift
    private static func serialize(_ object: [String: Any]) -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object)
        } catch {
            FileHandle.standardError.write(
                Data("[iMessage Max] modern serialize failed: \(error)\n".utf8)
            )
            // Preserve correlation when the id is a JSON scalar.
            let fallbackId: Any
            switch object["id"] {
            case let s as String: fallbackId = s
            case let n as NSNumber: fallbackId = n
            default: fallbackId = NSNull()
            }
            let fallback: [String: Any] = [
                "jsonrpc": "2.0",
                "id": fallbackId,
                "error": ["code": -32603, "message": "Internal error: response serialization failed"],
            ]
            return (try? JSONSerialization.data(withJSONObject: fallback))
                ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
        }
    }
```

Add the same one-line stderr log to the `guard ... else` failure branches of
`toolsJSON()` and `contentJSON(_:)` (keep their `[]` returns, shape safety,
but never silently). `iconsJSON()` stays as-is (nil is a legitimate
"no icons" answer).

**Verify**: `cd swift && swift build`; `swift test --filter ModernDispatcherTests` → green.

### Step 2: Sanitize the era log

In `logEra`, clamp and strip client-controlled strings:

```swift
    /// Client-supplied strings are untrusted: strip control characters
    /// (log-line injection) and clamp length before logging.
    private static func sanitizedLogField(_ value: String, maxLength: Int = 64) -> String {
        String(value.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .prefix(maxLength)
            .map(Character.init))
    }
```

Apply to `name`, `clientVersion`, and `method` before interpolation
(`client = "\(sanitizedLogField(name))/\(sanitizedLogField(clientVersion))"`,
`method=\(sanitizedLogField(method))`). `transport` and `version` are
server-constrained; leave them.

**Verify**: `cd swift && swift build` → exit 0.

### Step 3: Version the registry and memoize the catalog

1. In `ToolHandlerRegistry` (`ServerExtensions.swift`), add a monotonic
   version, bumped under the existing lock by BOTH `register` and
   `resetForTesting`:

```swift
    private var version: Int = 0

    /// Monotonic catalog version: bumps on every register/reset. Consumers
    /// may cache derived catalog data keyed by this value.
    var catalogVersion: Int {
        lock.lock()
        defer { lock.unlock() }
        return version
    }
```

   (`version += 1` inside `register` and `resetForTesting`'s locked
   sections.)

2. In `ModernDispatcher`, cache the encoded catalog keyed by that version.
   `ModernDispatcher` is an enum with static state, guard the cache with
   its own `NSLock` (match the registry's locking idiom):

```swift
    private static let catalogCacheLock = NSLock()
    private static var cachedToolsJSON: (version: Int, tools: [[String: Any]])?

    private static func toolsJSON() -> [[String: Any]] {
        let currentVersion = ToolHandlerRegistry.shared.catalogVersion
        catalogCacheLock.lock()
        if let cached = cachedToolsJSON, cached.version == currentVersion {
            defer { catalogCacheLock.unlock() }
            return cached.tools
        }
        catalogCacheLock.unlock()

        let tools = ToolHandlerRegistry.shared.getTools()
        guard let data = try? JSONEncoder().encode(tools),
            let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            FileHandle.standardError.write(...)   // Step 1's log line
            return []
        }
        catalogCacheLock.lock()
        cachedToolsJSON = (currentVersion, json)
        catalogCacheLock.unlock()
        return json
    }
```

   Do NOT cache an empty-on-failure result (the code above naturally
   doesn't, failures return before the cache write). `serverInfoJSON()` is
   three static strings, make it a `private static let` computed once.
   `iconsJSON()` similarly never changes at runtime: compute once into a
   `private static let` via an immediately-invoked closure.

   **Concurrency note**: `[[String: Any]]` crossing the static cache is why
   the lock idiom (not an actor) is used, it matches how
   `ToolHandlerRegistry` already handles the same problem. If strict
   concurrency checking rejects the static `var`, wrap cache + lock in a
   small `final class CatalogCache: @unchecked Sendable` mirroring the
   registry's pattern.

**Verify**: `cd swift && swift build`; full dispatcher + HTTP modern suites green
(deterministic-order test at `ModernDispatcherTests.swift:142` now also
proves the cache preserves order; the resetForTesting bump keeps tests
isolated).

### Step 4: Tests

Add to `ModernDispatcherTests.swift`:

1. `testCatalogCacheInvalidatesOnRegistryChange`, register tool A;
   `tools/list` → 1 tool; register tool B; `tools/list` → 2 tools in
   registration order. (Proves version bumping; without it the second list
   would serve the stale single-tool cache.)
2. `testCatalogCacheServesConsistentResultAcrossCalls`, two consecutive
   `tools/list` calls return byte-identical `tools` arrays (decode both,
   compare names + order).
3. `testLogFieldSanitization`, make `sanitizedLogField` internal (not
   private) and assert directly: control chars stripped
   (`"evil\nname"` → `"evilname"`), 300-char input clamped to 64.
4. `testSerializeFallbackPreservesScalarId`, only if `serialize` can be
   reached with an unencodable object through a seam (it cannot today
   without contriving; if so, make `serialize` internal and test it
   directly with `["id": 7, "x": Date()]`, `JSONSerialization` rejects
   `Date`, asserting the fallback body contains `"id":7`).

**Verify**: `cd swift && swift test --filter ModernDispatcherTests` → all
pass, ≥3 net-new tests.

### Step 5: Full suite

**Verify**: `cd swift && swift test` → exit 0, 0 failures.

## Test plan

Step 4. Exemplars: `ModernDispatcherTests` helpers (`registerFakeTool`,
`modernRequest`, `result(from:)`) and its registry reset lifecycle.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` exits 0; 0 failures; ≥3 net-new tests
- [ ] `grep -n "catalogVersion" swift/Sources/iMessageMax/Server/ServerExtensions.swift swift/Sources/iMessageMax/Server/ModernProtocol.swift` → both match
- [ ] `grep -c "standardError" swift/Sources/iMessageMax/Server/ModernProtocol.swift` ≥ 4 (era log + serialize + toolsJSON + contentJSON failures)
- [ ] `grep -n "sanitizedLogField" swift/Sources/iMessageMax/Server/ModernProtocol.swift` → defined and applied in `logEra`
- [ ] The deterministic-order test (`ModernDispatcherTests.swift:142`) passes unmodified
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Excerpts don't match live code (drift).
- Strict-concurrency errors on the static cache can't be resolved with the
  `@unchecked Sendable` cache-class pattern already used by
  `ToolHandlerRegistry`, report rather than inventing a new concurrency
  design.
- Any existing dispatcher/HTTP-modern test needs its *assertions* changed,
  response shapes must be byte-compatible; only additions are expected.
- You're tempted to also memoize per-response `completeResult()` `_meta`,
  that's included via the `serverInfoJSON` static let; anything further is
  out of scope.

## Maintenance notes

- The catalog cache's correctness rests on ONE invariant: **every mutation
  of registry tool state bumps `version` under the lock**. Any future
  `unregister`/`replace` method must do the same, check for this in review
  of registry changes.
- `sanitizedLogField` is the reusable primitive if other log lines later
  interpolate client input (grep for `era=` writers).
- If tool schemas ever become dynamic (per-session capabilities), the cache
  must key on that too, revisit before building such a feature.
