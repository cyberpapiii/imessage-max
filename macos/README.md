# iMessage Max for the menu bar

A small native companion for the existing iMessage Max service. It checks readiness, guides permission setup, starts and stops the helper, and shares connection details. It does not browse conversations or send messages.

## Use it

Open **iMessage Max.app**. Click the speech bubble in the menu bar whenever you need it. Opening the app again also reveals the panel.

- The **switch** beside the title starts and stops the helper. Off keeps it off until you turn it on again. Quit closes the companion and leaves the helper running.
- The **setup step** on the home page shows the next permission that needs attention, with its own buttons. Reading, contact names, and sending are checked separately and listed underneath.
- **Connection** copies the local address, Codex configuration, MCP HTTP configuration, or Plug configuration. Paste the appropriate configuration into your assistant's settings, then reconnect that assistant. Codex's TOML snippet belongs in `~/.codex/config.toml`; Plug's belongs in its existing `config.toml`. The app never changes those files for you.
- **Details & help** copies a diagnostic report without messages or contact details, opens the local service log, restarts the helper, and opens Messages.
- **Preferences** offers launch at login. It is off by default. If macOS requires approval, the panel links to Login Items.

Connection, Details & help, and Preferences are pages that slide in inside the same panel. Escape goes back to the home page; a second Escape closes the panel. Every control supports keyboard focus and VoiceOver. Appearance, Reduce Motion, and Reduce Transparency follow macOS.

## Build and install

Requires macOS 15 or newer and the repository's Swift toolchain. The companion is a separate Swift 6 package with no third-party dependencies; it imports the repository's `contract/` package for the wire types and words it shares with the server.

From the repository root:

```sh
# Required after changes to server code: preserves its signed, authorized path.
make -C swift install

# Build, sign, install in ~/Applications, and launch the companion.
./script/build_and_run.sh --install

# Build, sign, and run from dist/; also available through Codex's Run action.
./script/build_and_run.sh

# Run the companion's service-boundary and panel-state tests.
swift test --package-path macos
```

The build script also supports `--build-only`, `--verify`, `--debug`, `--logs`, and `--telemetry`. It requires the persistent **iMessage Max Dev** signing identity used by the server. If missing, follow the repository's `make setup-signing` instructions.

The resulting `dist/iMessage Max.app` includes the signed server helper and the canonical launchd template. The build matches the host architecture; the current local artifact is Apple silicon. It is locally signed, not a notarized public release.

## Existing and fresh installations

The companion adopts `~/Library/LaunchAgents/local.imessage-max.plist`, honors its valid loopback port, and preserves its executable path. It does not move an existing Full Disk Access grant. Only the `local.imessage-max` service is controlled. A confirmed unrelated listener is reported as a conflict and is left alone.

On a fresh Mac, **Set up iMessage Max** copies the bundled helper to `~/Library/Application Support/iMessage Max/bin/imessage-max` and renders the repository's launchd template. The helper runs only on loopback. macOS permission decisions remain yours.

Full Disk Access applies to the helper that reads Messages, not merely the menu bar companion. Setup reveals that exact executable in Finder and opens the correct settings pane. After changing the grant, use the setup restart button. Contacts and Automation requests run in that same launchd service through a native-only loopback setup endpoint; the companion does not spawn a CLI that inherits its own privacy identity. Setup opens Messages before checking Automation because macOS cannot check a closed target. An existing grant completes setup without another permission prompt. The panel rechecks the running service afterward and never treats a prompt or command exit as proof of a grant. The explicit CLI modes remain available for manual setup.

The setup endpoint is outside MCP's thirteen tools. It rejects browser origins, requires an explicit native request header, accepts only Contacts or Automation, and is unavailable on externally bound listeners. Startup and ordinary tool calls never invoke it. It sends no message. If the companion quits while macOS is asking for consent, it stops waiting; the helper and macOS dialog remain until you answer.

## Implementation

`Sources/MaxCore` contains immutable diagnostic snapshots (the capability keys and words come from the shared `contract/` package), strict loopback configuration parsing, the modern MCP client, bounded actor-owned process execution, and launchd control behind the `ServiceControlling` protocol. `Sources/iMessageMaxMenu` contains MainActor observable UI state and SwiftUI views; `PanelState.swift` derives the home page's headline, primary button, and face from one reading of the service, so a copy change lands in one place. A narrow AppKit boundary owns the status item and popover so the same panel can open on first launch and app reopen. Background checks run at most once per minute, stop during sleep, and coalesce with interactive checks. The face is drawn only while the panel is open, and animates only when its mood changes, on a click or good news, and continuously while an action is in progress.

## Design checks

The panel face, app icon, and cached menu bar artwork share `Sources/MaxBrand`: `MessageMark.swift` holds the bubble outlines (the round one the panel and menu bar wear, and the original one inside the app icon) and `MaxFace.swift` holds the poses, each one row of numbers on the same grid, and `CompanionMood`, which picks each mood's pose for the panel and the menu bar. The build script prepends those sources to the app-icon renderer, preventing drift between drawings, and compiles it with optimisation because it shades the icon's satin-silver bubble pixel by pixel. The companion uses its own round-stroke glyph family, switch, and buttons, and follows native appearance, contrast, and motion preferences.

Design checks run from a debug build without touching the installed companion or the service:

```sh
swift build --package-path macos
macos/.build/debug/iMessageMaxMenu --design-window --design-state setup-contacts --design-dark
```

`--design-state` loads a fixture (`fresh`, `stopped`, `setup-messages`, `setup-contacts`, `setup-sending`, `problem`, `working`, `checking`, `ready`) and never contacts the service: the panel runs against a canned `ServiceControlling` from `Sources/iMessageMaxMenu/DesignHarness.swift`, which holds every design flag. `--design-window` shows the panel in a floating window. `--design-open <connection|details|preferences>` opens a page, `--design-act <start|stop|allow|copy>` plays an action, and `--design-light`, `--design-dark`, `--design-reduce-motion`, and `--design-slow-motion` override appearance and motion for that process only. `--design-artwork <file.png>` writes every menu bar mood to a contact sheet and exits. The decisions and verification limits are recorded in `docs/design/2026-10-12-companion-overhaul.md`; the earlier pass is in `docs/design/2026-10-12-benji-polish.md`.
