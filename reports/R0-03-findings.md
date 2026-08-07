# R0-03 Findings — Legacy HTTP Session Capacity

## Finding

Legacy Streamable HTTP sessions have a fixed production capacity of 100.
Each session has a 3,600-second idle TTL, and the reaper runs every 300
seconds. A churn client that initializes sessions without retaining their
IDs can therefore refuse new legacy clients for roughly 60–65 minutes.
The modern MCP 2026-07-28 lane is stateless and does not consume this pool.

The cap and TTL remain unchanged under the resolved `document-and-signal`
policy.

## Exact behavior at capacity

- `SessionManager` refuses creation when `sessions.count >= 100`.
- Only legacy `initialize` requests need a new pooled session.
- Existing session traffic continues to work.
- Before this change, the HTTP response was status 503, content type
  `application/json`, and JSON-RPC error code `-32600` with `id: null` and
  message `Too many active sessions. Try again later.`
- That response identified pressure but did not tell the client how to
  recover.
- Client or SSE disconnect does not terminate the logical MCP session.

Impact is local-only under the loopback binding, but 100 inexpensive
unauthenticated initialize requests can deny new legacy sessions.

## Recovery paths

1. Reuse an existing valid session instead of initializing another.
2. For each unused session whose full ID is available, send `DELETE /` with
   its `Mcp-Session-Id`; the server returns 204 and capacity is immediately
   reusable.
3. Otherwise wait for the one-hour idle TTL plus the reaper interval (up to
   about five additional minutes).
4. Restarting the service clears all sessions, but is disruptive and is not
   needed when IDs were retained.

Clients should retain full session IDs until they have issued DELETE. The
stderr log intentionally records only an eight-character prefix, which is
not sufficient for later cleanup.

## Smallest hardening change

The 503 JSON-RPC message now says:

> Session capacity reached. Reuse an existing session, terminate unused
> sessions with DELETE and their Mcp-Session-Id, or retry after idle sessions
> expire.

No `diagnose` capability key was added. `diagnose` is only callable from an
already-established session, so it cannot help a newly refused client, and
adding a sixteenth key would expand the frozen 15-key capability contract.
Improving the admission error is both more direct and smaller.

## Evidence

The existing integration transport was configured with `maxSessions: 1` to
reach the same production branch without exhausting the live service.

- Before: first initialize 200; second initialize 503 with the opaque
  `Too many active sessions. Try again later.` message.
- Red proof: strengthened assertions for actionable recovery failed five
  times against that old message.
- After: first initialize 200; second initialize 503 with all recovery
  signals; DELETE of the retained first session returned 204; a third
  initialize returned 200.

Focused command:

```text
swift test --filter HTTPTransportIntegrationTests/testSecondSessionAtCapacityReturns503
```

This probe avoids leaving live service sessions behind and proves recovery
without a kickstart.
