# iMessage Max menu bar companion

Approved by Rob on October 12, 2026. He authorized implementation end to end, waived further approval gates, and selected service management rather than conversation browsing or sending.

## Intent

Make iMessage Max approachable without a terminal: know whether it works, finish setup, start or stop it, recover it, and connect an assistant. Keep the app lightweight, minimal, and delightful. The five nouns are iMessage Max, Messages, Contacts, connection, and setup.

## Product

One native menu bar panel, 360 points wide, with system typography and a 12-point text floor. A small original speech-bubble face shares the service's state. The header, face, status, and footer persist while connection, setup, and details expand within the same panel. The daily surface has one primary action. Its copy distinguishes reading from sending: a listening socket alone never means ready, and unverified Automation never means sending works.

Implementation ruling: a narrow AppKit status-item/popover boundary hosts the SwiftUI panel. MenuBarExtra has no public API to reveal its panel on app launch/reopen. Discoverability needs that behavior; no custom window system or additional working screen is introduced. The header and footer stay outside the scrolling body.

The home surface answers whether the service can read Messages, resolve contact names, and send. Its action is the next missing setup step, start, or recheck. A service menu holds stop and restart. Quitting the companion leaves the service running. Stop unloads the launch agent so its keepalive cannot undo the person's choice; start loads it again. Restart verifies the new service rather than merely trusting launchctl's exit code.

Setup presents one permission at a time. Full Disk Access instructions reveal the exact server executable in Finder and open the correct System Settings pane. Explicit Contacts and Automation requests run in the actual launchd service through a bounded, loopback-only native setup endpoint. The companion verifies the reply's process identity and then rechecks live capabilities. It opens Messages before checking Automation because the Apple API requires its target to be running. Browser-origin and unmarked requests are rejected. Denied permissions open System Settings. Rechecking follows permission changes; Full Disk Access instructions explain the required restart. No test message is sent.

Connection offers the local endpoint and copies valid generic MCP HTTP configuration and Plug configuration. It never claims an assistant has connected without evidence. Details show version, per-capability status, last check, service controls, logs, and a sanitized diagnostic report. Preferences expose launch at login via ServiceManagement, with system-approval states described plainly.

## Runtime and distribution

macOS 15 minimum; Swift 6 language mode. A separate dependency-free Swift package under macos/ builds the companion. SwiftUI owns presentation, an observable MainActor model owns UI state, Sendable snapshots cross boundaries, and an actor controls launchd and process operations. URLSession performs stateless diagnose calls using the actual modern header and body contract. Requests time out, overlapping refreshes are coalesced, and periodic checks stop during sleep. No continuous character animation or message reads.

Adopt the installed local.imessage-max agent and its existing signed binary path. Never migrate an existing Full Disk Access grant. A distributable app contains a signed server helper and the repository's canonical launchd template; a fresh installation copies the helper to a stable user Application Support path and renders that template. No administrator access is required. Runtime controls target only local.imessage-max and validate the configured loopback host and executable. A different process occupying the endpoint is an actionable conflict, not permission to stop it.

## Visual and motion tokens

Spacing: 4, 8, 12, 16, 24 points. Card radius: 14; control radius: 10. Type: 12-point captions, 13-point rows, 14-point body, 23-point status. Neutrals carry layout; green means ready, amber needs attention, gray means stopped or checking, red is a failed operation. Every status also has text and a distinct symbol.

Initial motion estimates: 160 ms controls, 280 ms expanding sections, 180 ms exits, 600 ms first-setup/recovery acknowledgement. These are starting values, not claims about Benji Taylor's specifications. The bubble's eyes and mouth interpolate rather than swapping drawings. Nothing loops while idle or hidden. Reduce Motion removes travel, scaling, and celebration. Reduce Transparency gets an opaque surface. System colors support light/dark and increased contrast; all actions use native buttons, keyboard focus, and accessibility labels.

## Verification contract

Meaningful tests cover readiness distinctions, malformed and foreign protocol replies, non-loopback configuration rejection, launchd template fidelity, process timeout/cancellation, and truthful setup prioritization. Run the existing server suite and make install after server changes. Build a signed app bundle, launch it, inspect the live panel and expanded surfaces, exercise refresh/copy/start/stop/restart, and confirm the service's database access afterward. Record measured app size, memory/CPU snapshot, request timing, and remaining permission or distribution limits. Local signing is not notarized public distribution.
