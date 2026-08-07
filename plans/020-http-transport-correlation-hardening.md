# Plan 020: Harden HTTPTransport request correlation and error responses

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report, do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat e3d14da..HEAD -- swift/Sources/iMessageMax/Server/HTTPTransport.swift swift/Tests/iMessageMaxTests/HTTPTransportIntegrationTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug / security
- **Planned at**: commit `e3d14da`, 2026-08-07

## Why this matters

Four defects live in the same ~120 lines of `HTTPTransport.swift`:

1. **A crafted JSON-RPC id crashes the whole service.** `parseJsonRpcId` runs
   `String(Int(doubleId))`; a POST with `"id": 1e300` makes `Int(_:)` trap
   ("Double value cannot be converted to Int"). The function runs for every
   request on the legacy lane (`HTTPTransport.swift:290`), so an `initialize`
   with that id aborts the process on the first unauthenticated POST, and a
   repeated POST is a restart loop against launchd.
2. **Ids of different JSON types collide.** `1` (int) and `"1"` (string) both
   canonicalize to `"1"`; the second concurrent request is rejected as a
   duplicate, or worse, a response can resume the wrong continuation.
3. **Error bodies are hand-built JSON.** `errorResponse` escapes only `"`;
   the client-controlled `MCP-Protocol-Version` header value is interpolated
   into the message, so a header ending in `\` (or containing control
   characters) produces malformed/injectable JSON in the response body.
4. **Every successful request leaks an armed 300-second timer.** The success
   path removes the pending request without cancelling its
   `DispatchWorkItem`, so each served request leaves a timer plus a wakeup
   `Task` behind, steady-state churn in a runtime with a documented
   sensitivity to stray task wakeups.

## Current state

All in `swift/Sources/iMessageMax/Server/HTTPTransport.swift` (903 lines).
Relevant excerpts as of `e3d14da`:

The pending-request plumbing (`:55-63`):

```swift
    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, Error>
        let timeoutWorkItem: DispatchWorkItem
    }

    private struct PendingRequestKey: Hashable {
        let sessionId: String
        let requestId: String
    }
```

The id parser (`:842-856`), defect 1 and 2:

```swift
    /// Parses the JSON-RPC id from a message
    private nonisolated func parseJsonRpcId(from json: [String: Any]) -> String {
        if let id = json["id"] {
            if let stringId = id as? String {
                return stringId
            } else if let intId = id as? Int {
                return String(intId)
            } else if let doubleId = id as? Double {
                return String(Int(doubleId))
            } else if id is NSNull {
                return "null"
            }
        }
        return UUID().uuidString  // Generate unique ID if none found
    }
```

Call sites: `:290` (`case .request` in `handlePost`, feeds
`storePendingRequest`) and `:582` (`handleServerResponse`, feeds the lookup).
Both go through this one function, which is what makes a canonical-form change
safe: store and lookup always agree.

The error body builder (`:858-871`), defect 3:

```swift
    /// Creates a JSON-RPC error response
    private nonisolated func errorResponse(status: HTTPResponse.Status, message: String, code: Int = -32600) -> Response
    {
        let escapedMessage = message.replacingOccurrences(of: "\"", with: "\\\"")
        let errorJson =
            """
            {"jsonrpc":"2.0","error":{"code":\(code),"message":"\(escapedMessage)"},"id":null}
            """
        return Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(string: errorJson))
        )
    }
```

Client-controlled input reaches it at `:783-787` (and `:801-813`):

```swift
        if let versionHeader {
            guard MCPProtocolVersion.supported.contains(versionHeader) else {
                return errorResponse(
                    status: .badRequest,
                    message: "Unsupported protocol version: \(versionHeader)",
                    code: -32600
                )
            }
        }
```

The success path that skips timer cancellation (`:584-588`), defect 4:

```swift
        // Check if this matches a pending request
        let key = PendingRequestKey(sessionId: sessionId, requestId: jsonRpcId)
        if let pending = pendingRequests.removeValue(forKey: key) {
            pending.continuation.resume(returning: data)
            logger.trace("Routed response for request: \(jsonRpcId)")
```

The helper that does it correctly (`:700-712`), already exists, use it:

```swift
    /// Removes and returns a pending request
    private func removePendingRequest(
        sessionId: String,
        id: String,
        cancelTimeout: Bool = true
    ) -> PendingRequest? {
        let key = PendingRequestKey(sessionId: sessionId, requestId: id)
        let pending = pendingRequests.removeValue(forKey: key)
        if cancelTimeout {
            pending?.timeoutWorkItem.cancel()
        }
        return pending
    }
```

The correct serializer pattern to mirror (`ModernProtocol.swift:321-324`):

```swift
    private static func serialize(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object))
            ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
    }
```

Repo conventions: actor-isolated transport; conventional-commit messages;
tests use Hummingbird's `app.test` client, see
`HTTPTransportIntegrationTests.swift:12-31` for the pattern (build
`HTTPTransport(host:"127.0.0.1", port: 0, database: Database(), resolver:
ContactResolver(seedCache: [:]), requestTimeout: .seconds(5))`, then
`await transport.makeApplicationForTesting()`, then
`try await app.test(TestingSetup.router) { client in ... }`).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| Full tests | `cd swift && swift test` | exit 0, 0 failures |
| Targeted | `cd swift && swift test --filter HTTPTransport` | all pass |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Server/HTTPTransport.swift`
- `swift/Tests/iMessageMaxTests/HTTPTransportIntegrationTests.swift`
- `swift/Tests/iMessageMaxTests/HTTPTransportTests.swift` (if you add the unit
  tests there instead, either test file is fine, be consistent)
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):
- `swift/Sources/iMessageMax/Server/ModernProtocol.swift`, its own hygiene
  fixes are plan 026.
- `swift/Sources/iMessageMax/Server/OriginValidationMiddleware.swift`, its
  hand-built JSON uses constant strings only; leave it.
- The era-selection branch in `handlePost` (`:216-224`), behavior must not
  change; plan 027 owns its test coverage.
- Any change to `requestTimeout` defaults or the Dispatch-timer pattern
  itself (`:657-670`), that pattern is load-bearing (launchd crash lesson).

## Git workflow

- Branch: `advisor/020-http-transport-correlation-hardening`
- Conventional commits, e.g. `fix: non-trapping JSON-RPC id canonicalization and serialized error bodies`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Make `parseJsonRpcId` total (never traps) and type-tagged

Replace the body of `parseJsonRpcId` (`:843-856`) with a version that (a)
cannot trap on any input and (b) gives each JSON id type its own namespace.
Also make it `static` (it touches no instance state) and drop `private` to
`internal` so it can be unit-tested; keep `nonisolated`:

```swift
    /// Canonicalizes the JSON-RPC id to a collision-free string form.
    /// Type-tagged so `1` and `"1"` (both legal, distinct ids) never collide.
    /// Total: never traps, whatever the client sends.
    nonisolated static func parseJsonRpcId(from json: [String: Any]) -> String {
        guard let id = json["id"] else {
            return "u:\(UUID().uuidString)"  // No id — generate a unique key
        }
        if let stringId = id as? String {
            return "s:\(stringId)"
        }
        if let intId = id as? Int {
            return "i:\(intId)"
        }
        if let doubleId = id as? Double {
            if let exact = Int(exactly: doubleId) {
                return "i:\(exact)"  // 2.0 and 2 are the same JSON number
            }
            return "d:\(doubleId)"  // fractional or out-of-Int-range; no trap
        }
        if id is NSNull {
            return "n:null"
        }
        return "u:\(UUID().uuidString)"
    }
```

Update the two call sites (`:290` and `:582`) to `Self.parseJsonRpcId(from:)`.
The duplicate-id error message at `:305` will now show the tagged form (e.g.
`Duplicate in-flight JSON-RPC request id: i:2`); that is acceptable.

Note the deliberate choice: an *exactly integral* double maps to the `i:`
namespace because JSON does not distinguish `2` from `2.0`, a client that
sends `2` and gets a response echoing `2.0` (or vice versa through the SDK)
must still correlate.

**Verify**: `cd swift && swift build` → exit 0.

### Step 2: Serialize error bodies instead of interpolating

Replace the body of `errorResponse` (`:859-871`):

```swift
    private nonisolated func errorResponse(status: HTTPResponse.Status, message: String, code: Int = -32600) -> Response
    {
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message],
            "id": NSNull(),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object))
            ?? Data(#"{"jsonrpc":"2.0","error":{"code":-32603,"message":"Internal error"},"id":null}"#.utf8)
        return Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(bytes: data))
        )
    }
```

Additionally, clamp the echoed header value at the three interpolation sites
(`:785`, `:803`, `:811`): before interpolating `versionHeader` (or
`negotiated`) into a message, truncate it to 64 characters, e.g.
`String(versionHeader.prefix(64))`. Serialization already makes any content
safe; the clamp just keeps a garbage header from bloating logs and responses.

**Verify**: `cd swift && swift build` → exit 0.

### Step 3: Cancel the timeout timer on the success path

In `handleServerResponse` (`:584-588`), replace the direct dictionary removal
with the existing helper so the work item is cancelled:

```swift
        if let pending = removePendingRequest(sessionId: sessionId, id: jsonRpcId) {
            pending.continuation.resume(returning: data)
            logger.trace("Routed response for request: \(jsonRpcId)")
```

(`removePendingRequest` defaults `cancelTimeout: true`, that is the point.)

**Verify**: `cd swift && swift build` → exit 0, and
`grep -n "pendingRequests.removeValue" swift/Sources/iMessageMax/Server/HTTPTransport.swift`
shows matches only inside `removePendingRequest` and `cleanupPendingRequests`.

### Step 4: Unit tests for the id canonicalizer

Add a test class (in `HTTPTransportTests.swift` or the integration file):

```swift
final class JsonRpcIdCanonicalizationTests: XCTestCase {
    func testIntAndStringIdsDoNotCollide() {
        XCTAssertNotEqual(
            HTTPTransport.parseJsonRpcId(from: ["id": 1]),
            HTTPTransport.parseJsonRpcId(from: ["id": "1"])
        )
    }

    func testHugeDoubleIdDoesNotTrap() {
        let key = HTTPTransport.parseJsonRpcId(from: ["id": 1e300])
        XCTAssertTrue(key.hasPrefix("d:"))
    }

    func testFractionalDoubleIdDoesNotTrap() {
        let key = HTTPTransport.parseJsonRpcId(from: ["id": 1.5])
        XCTAssertEqual(key, "d:1.5")
    }

    func testIntegralDoubleMatchesIntId() {
        XCTAssertEqual(
            HTTPTransport.parseJsonRpcId(from: ["id": 2.0]),
            HTTPTransport.parseJsonRpcId(from: ["id": 2])
        )
    }

    func testNullIdIsStable() {
        XCTAssertEqual(HTTPTransport.parseJsonRpcId(from: ["id": NSNull()]), "n:null")
    }

    func testMissingIdGeneratesUniqueKeys() {
        XCTAssertNotEqual(
            HTTPTransport.parseJsonRpcId(from: [:]),
            HTTPTransport.parseJsonRpcId(from: [:])
        )
    }
}
```

Caveat: `["id": 1]` bridges to `NSNumber`; on Apple platforms `as? Int` and
`as? Double` both succeed for integral NSNumbers, so branch order (Int before
Double) is what keeps `1` in the `i:` namespace. Do not reorder the branches.

**Verify**: `cd swift && swift test --filter JsonRpcIdCanonicalizationTests` → all pass.

### Step 5: Integration tests for the crash input and the header injection

Add to `HTTPTransportIntegrationTests.swift`, following the existing
`app.test` pattern (`:12-31`):

1. **Huge-id request does not crash the server.** Build the transport with
   `requestTimeout: .seconds(2)`. POST an `initialize` whose body is the
   existing `initializePayload` JSON but with `"id": 1e300` (construct the
   JSON string manually if the helper only takes Int ids). Assert: the call
   returns an HTTP response (any status) and a subsequent normal `initialize`
   with `id: 1` still succeeds with `.ok`. Before this plan, the first POST
   aborted the test process, the assertion that *any* response arrives is
   the regression test.
2. **Malicious protocol-version header yields well-formed JSON.** POST a
   normal `initialize` with header `MCP-Protocol-Version` set to
   `bad\version"x` (a value containing a backslash and a quote). Assert:
   status is `.badRequest`, and the body parses via `JSONSerialization`
   with `error.code == -32600`. (Header field values cannot contain newlines
   in HTTP/1.1, so backslash+quote is the attack shape to test.)

**Verify**: `cd swift && swift test --filter HTTPTransportIntegrationTests` → all pass.

### Step 6: Full suite

**Verify**: `cd swift && swift test` → exit 0, 0 failures.

## Test plan

Covered by steps 4–5. New tests: 6 unit (id canonicalization) + 2 integration
(crash input, header injection). Pattern exemplar:
`HTTPTransportIntegrationTests.testInitializeCreatesSessionIdAndImmediateToolsList`.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift build` exits 0
- [ ] `cd swift && swift test` exits 0 with 0 failures; ≥8 new tests present
- [ ] `grep -n "String(Int(" swift/Sources/iMessageMax/Server/HTTPTransport.swift` → no matches
- [ ] `grep -n 'replacingOccurrences(of: "\\\\""' swift/Sources/iMessageMax/Server/HTTPTransport.swift` → no matches (no hand-escaping left)
- [ ] `handleServerResponse` routes through `removePendingRequest` (inspect `:580-590` region)
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The excerpts above don't match the live code (drift).
- Changing `parseJsonRpcId` to `static` breaks callers you weren't told
  about, `grep -n "parseJsonRpcId" swift/Sources/` should show exactly the
  two call sites (`:290`, `:582`) plus the definition; if there are more, stop.
- Any *existing* test fails after step 1 in a way that isn't a trivially
  updated assertion about the duplicate-id error message text.
- The huge-id integration test still crashes the process after the fix.

## Maintenance notes

- The type-tag namespace (`s:`/`i:`/`d:`/`n:`/`u:`) is internal to the
  pending-request table, it never appears on the wire except inside the
  duplicate-id error message. If someone later surfaces ids in more client
  messages, strip the tag for display.
- Reviewer should scrutinize: branch order in `parseJsonRpcId` (Int before
  Double), and that the integral-double → `i:` mapping is kept, since the
  legacy SDK may re-emit an integral id with a different JSON number form.
- Deliberately deferred: fractional-double ids are technically legal but the
  SDK's own `ID` type may not round-trip them; we only guarantee no-crash and
  no-collision, not correlation for fractional ids.
