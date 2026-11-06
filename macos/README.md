# iMessage Max for the menu bar

This is a small native companion app for the existing iMessage Max service. It checks whether the service is ready, walks you through permission setup, starts and stops the helper, and copies connection details. It does not browse conversations or send messages.

## Use it

Open **iMessage Max.app**, then click the speech bubble in the menu bar to open the panel. Opening the app again also shows the panel.

- The **switch** beside the title starts and stops the helper. Turning it off keeps the helper stopped until you turn it on again. Quitting closes the companion and leaves the helper running.
- The **setup step** on the home page shows the next permission that needs attention, with buttons for that permission. The panel checks reading, contact names, and sending separately and lists them below.
- **Connection** copies the local address, Codex configuration, MCP HTTP configuration, or Plug configuration. Paste the configuration for your assistant into its settings, then reconnect that assistant. The Codex TOML snippet goes in `~/.codex/config.toml`. The Plug snippet goes in Plug's existing `config.toml`. The app never changes those files for you.
- **Details & help** copies a diagnostic report without messages or contact details, opens the local service log, restarts the helper, and opens Messages.
- **Preferences** offers launch at login. It is off by default. If macOS requires approval, the panel links to Login Items.

Connection, Details & help, and Preferences are pages that slide in within the same panel. Escape returns to the home page, and a second Escape closes the panel. Every control supports keyboard focus and VoiceOver. The panel follows the macOS Appearance, Reduce Motion, and Reduce Transparency settings.

## Build and install

The companion requires macOS 15 or newer and the repository's Swift toolchain. It is a separate Swift 6 package with no third-party dependencies. It imports the repository's `contract/` package for the wire types and words it shares with the server.

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

The build script also supports `--build-only`, `--verify`, `--debug`, `--logs`, and `--telemetry`. It requires the persistent **iMessage Max Dev** signing identity that the server also uses. If you do not have that identity, follow the repository's `make setup-signing` instructions.

The build produces `dist/iMessage Max.app`, which contains the signed server helper and the canonical launchd template. The build targets the host architecture, and the current local build is for Apple silicon. The app is signed locally and is not a notarized public release.

## Existing and fresh installations

The companion adopts `~/Library/LaunchAgents/local.imessage-max.plist`, keeps its port if that port is a valid loopback port, and keeps its executable path. It does not move an existing Full Disk Access grant. The companion controls only the `local.imessage-max` service. When it confirms that a listener is unrelated, it reports a conflict and leaves that listener alone.

On a fresh Mac, **Set up iMessage Max** copies the bundled helper to `~/Library/Application Support/iMessage Max/bin/imessage-max` and renders the repository's launchd template. The helper runs only on loopback. You still make every macOS permission decision.

Full Disk Access must go to the helper that reads Messages. Granting it to the menu bar companion is not enough. Setup shows that exact executable in Finder and opens the matching settings pane. After you change the grant, use the restart button in setup. Contacts and Automation requests run in that same launchd service, through a loopback setup endpoint that accepts only native requests. The companion does not spawn a CLI process, which would inherit the companion's own privacy identity. Setup opens Messages before it checks Automation, because macOS cannot check a closed target. If a grant already exists, setup finishes without another permission prompt. Afterward, the panel checks the running service again. It never treats a prompt or a command's exit as proof of a grant. The explicit CLI modes are still available for manual setup.

The setup endpoint is not one of the thirteen MCP tools. It rejects browser origins, requires an explicit native request header, accepts only Contacts or Automation requests, and is not available on externally bound listeners. Startup and ordinary tool calls never invoke it. It sends no message. If the companion quits while macOS is asking for consent, the companion stops waiting. The helper and the macOS dialog stay open until you answer.

## Implementation

`Sources/MaxCore` contains immutable diagnostic snapshots (the capability keys and words come from the shared `contract/` package), strict loopback configuration parsing, the modern MCP client, bounded actor-owned process execution, and launchd control behind the `ServiceControlling` protocol. `Sources/iMessageMaxMenu` contains MainActor observable UI state and SwiftUI views. `PanelState.swift` derives the home page's headline, primary button, and face from one reading of the service, so a copy change happens in one place. A narrow AppKit layer owns the status item and popover, so the same panel opens on first launch and when the app is reopened. Background checks run at most once per minute, stop during sleep, and merge with interactive checks. The app draws the face only while the panel is open. The face animates only in these cases: when its mood changes, on a click or good news, and continuously while an action is in progress.

## Design checks

The panel face, the app icon, and the cached menu bar artwork share the code in `Sources/MaxBrand`. `MessageMark.swift` holds the bubble outlines. The panel and the menu bar use the round one, and the app icon contains the original one. `MaxFace.swift` holds the poses, each one row of numbers on the same grid. It also holds `CompanionMood`, which picks each mood's pose for the panel and the menu bar. The build script prepends those sources to the app-icon renderer, so the drawings cannot drift apart. It compiles the renderer with optimisation because the renderer shades the icon's satin-silver bubble pixel by pixel. The companion uses its own round-stroke glyph family, switch, and buttons, and follows native appearance, contrast, and motion preferences.

Run design checks from a debug build. They do not touch the installed companion or the service:

```sh
swift build --package-path macos
macos/.build/debug/iMessageMaxMenu --design-window --design-state setup-contacts --design-dark
```

`--design-state` loads a fixture (`fresh`, `stopped`, `setup-messages`, `setup-contacts`, `setup-sending`, `problem`, `working`, `checking`, `ready`) and never contacts the service. Instead, the panel runs against a canned `ServiceControlling` from `Sources/iMessageMaxMenu/DesignHarness.swift`. That file holds every design flag. `--design-window` shows the panel in a floating window. `--design-open <connection|details|preferences>` opens a page, `--design-act <start|stop|allow|copy>` plays an action, and `--design-light`, `--design-dark`, `--design-reduce-motion`, and `--design-slow-motion` override appearance and motion for that process only. `--design-artwork <file.png>` writes every menu bar mood to a contact sheet and exits. `docs/design/2026-10-12-companion-overhaul.md` records the design decisions and the limits of their verification. The earlier pass is in `docs/design/2026-10-12-benji-polish.md`.
