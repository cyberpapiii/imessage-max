# R0-03 Worker Report — Session Capacity Signal

## Outcome

Implemented the resolved `document-and-signal` policy with one
behavior-visible change: legacy HTTP initialization now returns an actionable
503 message when the existing session pool is full.

The production cap remains 100. The idle TTL remains 3,600 seconds. No
`diagnose` capability key was added because a refused client cannot call the
tool and the capability contract is intentionally fixed at 15 keys.

## Changed files

- `swift/Sources/iMessageMax/Server/HTTPTransport.swift`
  - Replaced the opaque capacity message with guidance to reuse an existing
    session, terminate unused sessions by DELETE with `Mcp-Session-Id`, or
    wait for idle expiry.
- `swift/Tests/iMessageMaxTests/HTTPTransportIntegrationTests.swift`
  - Strengthened the capacity integration test.
  - Proves a retained session ID can be deleted with HTTP 204.
  - Proves the next initialize succeeds immediately after deletion.
- `reports/R0-03-findings.md`
  - Records the exact cap, TTL, cleanup cadence, exposed response, impact,
    and recovery paths.

## Evidence

### Before

The existing focused integration probe passed with:

- first initialize: 200
- second initialize at injected capacity: 503
- message: `Too many active sessions. Try again later.`

### Red proof

After strengthening the test but before changing production code:

- focused test exited 1
- five recovery-message assertions failed against the old response
- DELETE recovery and subsequent initialize already exercised the real HTTP
  chain

### After

`swift test --filter HTTPTransportIntegrationTests/testSecondSessionAtCapacityReturns503`
passed:

- first initialize: 200
- second initialize: 503 with all actionable message elements
- DELETE retained session: 204
- replacement initialize: 200

`make test` passed 247 tests with 0 failures.

`make install` passed after the concurrent soak and extended idle observation
had stopped:

- release build succeeded
- signature replaced with `iMessage Max Dev`
- launchd service restarted
- legacy v1.4.2 health check passed
- modern 2026-07-28 health check passed

## Review

Independent correctness, project-standards, testing, API-contract, and
reliability review passes reported no findings, residual risks, or testing
gaps. The markdown findings report was untracked during that code-only review
and was manually checked against the implementation constants and observed
test evidence.

## Constraints honored

- No cap increase
- No TTL change
- No `Task.sleep` added
- No send calls
- No force push, rebase, or gt operation
- No install during active soak traffic
