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
# Builds the app, installs it to ~/Applications and registers its helper.
make -C swift install

# Build, sign, install in ~/Applications, and launch the companion.
./script/build_and_run.sh --install

# Build, sign, and run from dist/; also available through Codex's Run action.
./script/build_and_run.sh

# Run the companion's service-boundary and panel-state tests.
swift test --package-path macos
```

The build script also supports `--build-only`, `--verify`, `--debug`, `--logs`, and `--telemetry`. `script/assemble_app.sh <app path> <configuration>` does the bundle assembly and signing on its own. The app and the helper both get hardened runtime and `swift/iMessageMax.entitlements`, because macOS charges the helper's Contacts and Apple Events access to the app. `APP_NAME`, `APP_BUNDLE_ID`, `HELPER_LABEL` and `HELPER_PORT` build a test variant that can run next to the real app. The signing identity is the Developer ID Application identity in your keychain that expires last, or the certificate SHA-1 in `SIGN_IDENTITY`. Without a Developer ID the build signs ad hoc and prints a warning, and Full Disk Access must be granted again after each build.

The build produces `dist/iMessage Max.app`. The helper is `Contents/MacOS/imessage-max`, and its agent plist, `Contents/Library/LaunchAgents/com.cyberpapiii.imessage-max.helper.plist`, comes from `macos/Resources/LaunchAgents/`. The build targets the host architecture, and the current local build is for Apple silicon.

## Installing, updating and replacing an older install

The helper runs from inside the app. **Set up iMessage Max** registers it with `SMAppService`, so it starts at login, restarts after a crash, and appears once, as iMessage Max, under "App Background Activity" in System Settings → General → Login Items & Extensions. Nothing is copied out of the bundle. The companion reads the label, port and log path from the bundled plist, so a test variant with its own label and port manages only its own helper.

An app run from outside `/Applications` or `~/Applications`, or translocated by Gatekeeper, offers **Move to Applications** and never registers from there. If the helper is turned off in Login Items, the panel says so and opens Login Items. After an update replaces the app, the next launch of the companion restarts a helper that started before the new binary landed.

An install from before 2.0 (the `local.imessage-max` agent, its plist in `~/Library/LaunchAgents`, and a helper copied to `~/Library/Application Support/iMessage Max/bin`) shows **Replace the older helper**. That button boots out the old job, removes the plist and the copied helper, and registers the app's helper. Each step reads what is there now, so a second run changes nothing. A helper that the old plist named elsewhere, such as a build in a checkout, stays. Only the released bundle id and label replace an older install. The companion controls only its own helper. When it confirms that a listener on its port is unrelated, it reports a conflict and leaves that listener alone.

macOS charges the helper's Full Disk Access, Contacts and Automation to the app. The Full Disk Access step asks you to turn on iMessage Max, shows the app in Finder, and offers a restart, because the grant applies only to a newly launched helper. Contacts is asked by the companion itself: a helper inside an app that asks for Contacts is denied with no prompt. The companion then restarts the helper, which reads Contacts access only at launch. Automation requests run in the helper, through a loopback setup endpoint that accepts only native requests. Setup opens Messages before it checks Automation, because macOS cannot check a closed target. If a grant already exists, setup finishes without another permission prompt. Afterward, the panel checks the running service again. It never treats a prompt or a command's exit as proof of a grant. The explicit CLI modes are still available for manual setup.

The setup endpoint is not one of the thirteen MCP tools. It rejects browser origins, requires an explicit native request header, accepts only Contacts or Automation requests, and is not available on externally bound listeners. Startup and ordinary tool calls never invoke it. It sends no message. If the companion quits while macOS is asking for consent, the companion stops waiting. The helper and the macOS dialog stay open until you answer.

## Implementation

`Sources/MaxCore` contains immutable diagnostic snapshots (the capability keys and words come from the shared `contract/` package), strict loopback configuration parsing, the modern MCP client, bounded actor-owned process execution, and the service controller. `ServiceState` is one enum derived from one observation of `SMAppService`, `launchctl print`, `diagnose` and `lsof`. Every part of macOS the controller touches sits behind the `ServiceSystem` protocol, which the tests and the design harness replace. `Sources/iMessageMaxMenu` contains MainActor observable UI state and SwiftUI views. `PanelState.swift` derives the home page's headline, primary button, and face from one reading of the service, so a copy change happens in one place. A narrow AppKit layer owns the status item and popover, so the same panel opens on first launch and when the app is reopened. Background checks run at most once per minute, stop during sleep, and merge with interactive checks. The app draws the face only while the panel is open. The face animates only in these cases: when its mood changes, on a click or good news, and continuously while an action is in progress.

## Design checks

The panel face, the app icon, and the cached menu bar artwork share the code in `Sources/MaxBrand`. `MessageMark.swift` holds the bubble outlines. The panel and the menu bar use the round one, and the app icon contains the original one. `MaxFace.swift` holds the poses, each one row of numbers on the same grid. It also holds `CompanionMood`, which picks each mood's pose for the panel and the menu bar. The build script prepends those sources to the app-icon renderer, so the drawings cannot drift apart. It compiles the renderer with optimisation because the renderer shades the icon's satin-silver bubble pixel by pixel. The companion uses its own round-stroke glyph family, switch, and buttons, and follows native appearance, contrast, and motion preferences.

Run design checks from a debug build. They do not touch the installed companion or the service:

```sh
swift build --package-path macos
macos/.build/debug/iMessageMaxMenu --design-window --design-state setup-contacts --design-dark
```

`--design-state` loads a fixture (`fresh`, `stopped`, `misplaced`, `legacy`, `blocked`, `setup-messages`, `setup-contacts`, `setup-sending`, `problem`, `working`, `checking`, `ready`) and never contacts the service. Instead, the real controller runs against a canned `ServiceSystem` from `Sources/iMessageMaxMenu/DesignHarness.swift`. That file holds every design flag. `--design-window` shows the panel in a floating window. `--design-open <connection|details|preferences>` opens a page, `--design-act <start|stop|allow|copy>` plays an action, and `--design-light`, `--design-dark`, `--design-reduce-motion`, and `--design-slow-motion` override appearance and motion for that process only. `--design-artwork <file.png>` writes every menu bar mood to a contact sheet and exits. `docs/design/2026-10-12-companion-overhaul.md` records the design decisions and the limits of their verification. The earlier pass is in `docs/design/2026-10-12-benji-polish.md`.
