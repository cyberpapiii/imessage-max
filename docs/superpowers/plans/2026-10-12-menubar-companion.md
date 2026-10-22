# iMessage Max Menu Bar Companion Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task by task. Rob authorized native execution and waived further approval gates.

**Goal:** Deliver a signed, running, lightweight native companion for setup and management of iMessage Max.

**Architecture:** A dependency-free macos/ Swift package separates a Sendable service core from SwiftUI presentation. The app adopts the existing launch agent and preserves its executable path; fresh installations use a bundled helper and the canonical launchd template.

**Tech Stack:** Swift 6, SwiftUI, AppKit at system-integration boundaries, Foundation URLSession/Process, ServiceManagement.

**Spec:** docs/superpowers/specs/2026-10-12-menubar-companion-design.md

## Global Constraints

- macOS 15 minimum; Swift 6 language mode.
- No third-party UI dependencies, message browsing, or test sends.
- Preserve the installed signed server path and target only local.imessage-max.
- Copy the canonical launchd template; do not hand-write a replacement.
- 360-point panel width and 12-point minimum text.
- Honor Reduce Motion, Reduce Transparency, keyboard navigation, and dark mode.
- Run swift/make install after server code changes.

## Review Focus

- A service says ready while Automation is unverified: show reading and sending separately.
- An unrelated listener occupies the endpoint: report conflict and do not control it.
- A launch agent uses a non-default loopback port or invalid host: honor the valid port and reject network exposure.
- A command or request hangs or the Mac sleeps: bounded timeouts and cancellation, no duplicate work.
- Fresh install or an existing grant: use the template and stable helper paths without moving an installed server.

## Task 1: Service core and explicit permission request

Files: macos/Package.swift, macos/Sources/MaxCore/{ServiceState,ServiceClient,ProcessRunner,ServiceController}.swift; macos/Tests/MaxCoreTests/; swift/Sources/iMessageMax/{iMessageMaxCommand.swift,Utilities/AutomationPermission.swift}.

- [x] Write failing behavioral tests for readiness, protocol validation, loopback configuration, template rendering, and process timeout.
- [x] Implement immutable diagnostic snapshots and service configuration parsing.
- [x] Implement async bounded process execution and launchd lifecycle control.
- [x] Add an explicit non-sending --request-messages-access command; default startup remains non-prompting.
- [x] Run core tests and relevant server tests.

## Task 2: Native panel and setup

Files: macos/Sources/iMessageMaxMenu/{App,AppModel,PanelView,Components,DetailViews}.swift; macos/Resources/Info.plist.

- [x] Implement MainActor observable state, refresh coalescing, sleep handling, and truthful actions.
- [x] Implement one persistent panel, morphing bubble face, setup, connection, diagnostics, and preferences.
- [x] Add launch-at-login, pasteboard, Finder, Settings, and log-opening system integration.
- [x] Build and inspect the native panel, expanded states, and Escape behavior; review appearance/accessibility adaptations and record which checks were live or source-only.

## Task 3: Build, install, and prove

Files: script/build_and_run.sh, .codex/environments/environment.toml, macos/README.md, .gitignore, docs/validation/2026-10-12-menubar-companion.md.

- [x] Stage/sign the .app, bundled server helper, canonical template, and app icon.
- [x] Wire the Codex Run action; document build/install and user setup.
- [x] Run both test suites, make install, and launch the companion from its stable installed path.
- [x] Exercise actual service stop/start/restart and copy actions; verify final permissions and process identity.
- [x] Request a fresh code review, fix important findings, and record measurements and honest limits.

## Execution ledger

- Approved scope and design retained from the conversation. Rob explicitly waived subsequent review gates.
- Ruling: use a dedicated branch in the existing checkout rather than relocate the service to a worktree. Full Disk Access names the current release path; preserving it is a product requirement.
- Ruling: test service and protocol boundaries; inspect reversible presentation changes on the running app instead of writing tests that mirror the view implementation.
- Task 1: complete. Readiness tests failed against the initial stub, then passed. Actor-inherited Dispatch timer callbacks crashed the timeout test; explicitly Sendable callbacks fixed the isolation boundary. Protocol/configuration/template/timeout/cancellation tests now cover those boundaries.
- Task 2: complete. Native anchored panel inspected through CUA. Setup, connection, diagnostics, preferences, and real service controls exercised. AppKit owns presentation so first launch/reopen can reveal the panel; SwiftUI owns all visible content.
- Ruling: use canonical bootout/bootstrap for restart. A real kickstart test left the helper crash-throttled for 30 seconds; unload/load returned to readiness in about two seconds. This does not claim to fix the server's existing shutdown allocator abort.
- Review: five initial findings fixed; later stale-response, duration, and shutdown-cancellation findings addressed. Delayed cancellation now verifies an already running child actually exits.
- Task 3: complete. Both suites passed, the signed companion was installed under ~/Applications, and make install verified both service eras and real database access. Native controls and copied values were exercised. Validation details and remaining limits are in docs/validation/2026-10-12-menubar-companion.md.
- Setup repair: a closed Messages app was incorrectly classified as missing consent, and a companion-spawned CLI had the companion's privacy identity rather than the independent daemon's. Explicit permission requests now execute in the live daemon, return its PID, and require a subsequent live diagnosis before reporting success. Messages opens before Automation setup; readiness priority still checks Messages database and Contacts first. Both suites passed again (19 companion tests; 548 server tests, one skipped). Native verification reproduced the closed-target state and completed setup with one click using the existing grant; no message was sent.
