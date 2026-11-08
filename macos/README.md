# iMessage Max for the menu bar

This is a small native companion app for the existing iMessage Max service. It checks whether the service is ready, walks you through permission setup, starts and stops the helper, and copies connection details. It does not browse conversations or send messages.

## Use it

Open **iMessage Max.app**. A speech bubble appears in the menu bar, and the Settings window opens on Permissions. Opening the app again from Finder shows the window again. A launch at login stays quiet in the menu bar.

The bubble's menu is a plain macOS menu:

- A header with Max's face, **iMessage Max** and one status word: Running, Needs attention, Stopped or Setting up (or what it is doing, such as Checking…). Clicking it opens Settings. The first time an assistant uses iMessage Max, the header says so until you close the menu.
- If something needs doing, one more line names it, such as **Turn on Full Disk Access** or **Move iMessage Max to Applications**, and opens Settings on the page that fixes it. Once every permission is on and no assistant is connected yet, the line suggests **Connect your assistant**.
- **Connections:** names what is connected, such as Plug, or None, and opens Connections.
- **Settings…** (⌘,) and **Quit iMessage Max** (⌘Q). Quitting closes the companion and leaves the helper running.

The Settings window has a sidebar and a grouped form on each page, built from stock SwiftUI and AppKit controls, so macOS draws its own materials, controls and Liquid Glass. Back and forward buttons in the toolbar retrace the pages you opened. The app shows in the Dock and the app switcher only while the window is open.

The top of the sidebar shows the face, **iMessage Max** and the status word, like the account row in System Settings. Clicking it opens the page that needs you, or General.

- **General** shows what the helper is doing, with **Stop iMessage Max…** (which asks first) or **Start iMessage Max**, or the one button that clears a blocked state: Move to Applications, Replace Older Helper, Restart iMessage Max or Check Again. An error shows here with a Restart button. **Open at login** is off by default. If macOS requires approval, the page links to Login Items. **Keep running**, on by default, starts the helper again when it quits; Stop iMessage Max… still keeps it stopped.
- **Permissions** lists Background activity, Full Disk Access, Contacts and Automation by their System Settings names, each with a line on what it is for and its status (On or Off, Allowed, Some contacts or Not allowed, or Not checked while the helper is not running). The page looks the same during first run and after. The first missing permission shows its explanation and buttons in its row. Each permission is judged on every check, so a grant turned off in System Settings shows at the next check.
  - Full Disk Access and Contacts need a grant that macOS gives only to a newly started helper. When you open the menu or come back to the window with one of those missing, or you choose Check Again, the app restarts the helper itself and checks.
  - Once every permission is on, a **Connect your assistant** section lists the assistants found on this Mac with one Connect button each. It leaves for good once an assistant connects or calls a tool, or when you choose Not Now.
- **Connections** lists the assistants found on this Mac (Claude, Claude Code, Codex, Plug, Cursor), each with one Connect button that turns to Connected, or says that none were found. Plug is connected with its own `plug` command: `plug secret set` stores the access token in the Keychain from stdin, and `plug server add` or `plug server edit` points `[servers.imessage]` at the address with `keychain:imessage-max-token` as its bearer token. Plug shows as connected when its running service reports that server healthy at this address. Codex, and Plug on a Mac without the `plug` command, get their `[mcp_servers.imessage]` or `[servers.imessage]` table written with the address and the access token. The app edits only that table, saves the old file next to it as `<name>.imessage-max-backup`, and keeps the file's mode. A read-only file is left alone and the row shows the error. Claude Code is connected with `claude mcp add --scope user`. Claude and Cursor open their own install step, and the row turns to Connected once you accept it there. **Any other MCP client** shows the address with Copy buttons for it and for the access header.
- **About & Help** shows the helper's version, the live inbox and when it last checked, with Check Now. It copies a diagnostic report without messages or contact details, opens the local service log, restarts the helper, and opens Messages.

Every control supports keyboard focus and VoiceOver, and VoiceOver reads out the result of an action. The window follows the macOS Appearance, Reduce Motion, and Reduce Transparency settings. Captures of every page and of the menu in each status are in [`docs/design/settings/`](../docs/design/settings/), for example [Permissions](../docs/design/settings/permissions-light.png) and [the menu](../docs/design/settings/menu-attention-light.png).

## Build and install

The companion requires macOS 15 or newer and the repository's Swift toolchain. It is a separate Swift 6 package with no third-party dependencies. It imports the repository's `contract/` package for the wire types and words it shares with the server.

From the repository root:

```sh
# Builds the app, installs it over the copy in /Applications or else in
# ~/Applications, and registers its helper.
make -C swift install

# Build, sign, install in ~/Applications, and launch the companion.
./script/build_and_run.sh --install

# Build, sign, and run from dist/; also available through Codex's Run action.
./script/build_and_run.sh

# Run the companion's service-boundary, state and menu tests.
swift test --package-path macos
```

The build script also supports `--build-only`, `--verify`, `--debug`, `--logs`, and `--telemetry`. `script/assemble_app.sh <app path> <configuration>` does the bundle assembly and signing on its own. The app and the helper both get hardened runtime and `swift/iMessageMax.entitlements`, because macOS charges the helper's Contacts and Apple Events access to the app. `APP_NAME`, `APP_BUNDLE_ID`, `HELPER_LABEL`, `HELPER_PORT`, `HELPER_SOCKET` and `HELPER_TOKEN_FILE` build a test variant that can run next to the real app. A test variant launched with `--client-root <folder>` reads and writes client configs under that folder, finds Claude and Cursor only in `<folder>/Applications` and command-line tools only under `<folder>`, and logs what it would open to `<folder>/open-requests.log` instead of opening it. The released app ignores the flag. The signing identity is the Developer ID Application identity in your keychain that expires last, or the certificate SHA-1 in `SIGN_IDENTITY`. Without a Developer ID the build signs ad hoc and prints a warning, and Full Disk Access must be granted again after each build.

The build produces `dist/iMessage Max.app`. The helper is `Contents/MacOS/imessage-max`, and its agent plist, `Contents/Library/LaunchAgents/com.cyberpapiii.imessage-max.helper.plist`, comes from `macos/Resources/LaunchAgents/`. The build targets the host architecture, and the current local build is for Apple silicon.

## Installing, updating and replacing an older install

People install the app from the notarized DMG on the GitHub release, or with `brew install --cask cyberpapiii/tap/imessage-max`. The cask also links `imessage-max`, the stdio bridge, into Homebrew's `bin`. `brew upgrade --cask imessage-max` replaces the app and leaves the helper running. If the companion was open, brew quits and reopens it, and the reopened companion restarts the helper on the new binary. Otherwise the helper moves to the new binary the next time you open the app or log in. `brew uninstall --cask imessage-max` quits the companion, stops the helper and removes the app. Adding `--zap` also removes the launchd job, the token, the socket, the logs and the preferences.

The helper runs from inside the app. **Set up iMessage Max** registers it with `SMAppService`, so it starts at login, restarts after a crash (and after a plain quit while Keep running is on), and appears once, as iMessage Max, under "App Background Activity" in System Settings → General → Login Items & Extensions. Nothing is copied out of the bundle. The companion reads the label, port and log path from the bundled plist, so a test variant with its own label and port manages only its own helper.

An app run from outside `/Applications` or `~/Applications`, or translocated by Gatekeeper, offers **Move to Applications** and never registers from there. If the helper is turned off in Login Items, Permissions says so and opens Login Items. After an update replaces the app, the next launch of the companion restarts a helper that started before the new binary landed.

An install from before 2.0 (the `local.imessage-max` agent, its plist in `~/Library/LaunchAgents`, and a helper copied to `~/Library/Application Support/iMessage Max/bin`) shows **Replace the older helper**. That button boots out the old job, removes the plist and the copied helper, and registers the app's helper. Each step reads what is there now, so a second run changes nothing. A helper that the old plist named elsewhere, such as a build in a checkout, stays. Only the released bundle id and label replace an older install. The companion controls only its own helper. When it confirms that a listener on its port is unrelated, it reports a conflict and leaves that listener alone.

macOS charges the helper's Full Disk Access, Contacts and Automation to the app. The Full Disk Access step asks you to turn on iMessage Max, shows the app in Finder, and offers a restart, because the grant applies only to a newly launched helper. Contacts is asked by the companion itself: a helper inside an app that asks for Contacts is denied with no prompt. The companion then restarts the helper, which reads Contacts access only at launch. Automation requests run in the helper, through a loopback setup endpoint that accepts only native requests. macOS cannot check Automation for a closed app, so the helper starts Messages hidden first: no Messages window appears and focus does not move. You never have to open Messages, for setup or for sending. While Messages is closed, the Automation row shows the last answer macOS gave. If a grant already exists, setup finishes without another permission prompt. Afterward, the app checks the running service again. It never treats a prompt or a command's exit as proof of a grant. The explicit CLI modes are still available for manual setup.

The setup endpoint is not one of the thirteen MCP tools. It rejects browser origins, requires an explicit native request header, accepts only Contacts or Automation requests, and is not available on externally bound listeners. Startup and ordinary tool calls never invoke it. It sends no message. If the companion quits while macOS is asking for consent, the companion stops waiting. The helper and the macOS dialog stay open until you answer.

## Implementation

`Sources/MaxCore` contains immutable diagnostic snapshots (the capability keys and words come from the shared `contract/` package), strict loopback configuration parsing, the modern MCP client, bounded actor-owned process execution, and the service controller. `ServiceState` is one enum derived from one observation of `SMAppService`, `launchctl print`, `diagnose` and `lsof`. Every part of macOS the controller touches sits behind the `ServiceSystem` protocol, which the tests and the design harness replace. `Sources/iMessageMaxMenu` contains MainActor observable UI state and SwiftUI views. `PanelState.swift` derives the status word, the next step and the page that fixes it, the service button and the face from one reading of the service, so a copy change happens in one place. The status menu's lines come from the same state (`PanelState.menu`), so the menu, its design drawing and the tests read one list. A narrow AppKit layer owns the status item, its `NSMenu`, and the Settings window: an `NSSplitViewController` with a sidebar item and an `NSToolbar`, holding SwiftUI in each pane. The public MenuBarExtra and Settings scenes cannot open a window on first launch or on reopen. Background checks run at most once per minute, stop during sleep, and merge with interactive checks. The app draws the face only while the menu or the window is open. The face animates only in these cases: when its mood changes, on a click or good news, and continuously while an action is in progress.

## Design checks

The face in the menu and the window, the app icon, and the cached menu bar artwork share the code in `Sources/MaxBrand`. `MessageMark.swift` holds the bubble outlines. The face and the menu bar use the round one, and the app icon contains the original one. `MaxFace.swift` holds the poses, each one row of numbers on the same grid. It also holds `CompanionMood`, which picks each mood's pose for the face and the menu bar. The build script prepends those sources to the app-icon renderer, so the drawings cannot drift apart. It compiles the renderer with optimisation because the renderer shades the icon's satin-silver bubble pixel by pixel. Everything else is stock: SF Symbols, system buttons and toggles, grouped forms and semantic colours, with the bubble's blue as the accent.

Run design checks from a debug build. They do not touch the installed companion or the service:

```sh
swift build --package-path macos
macos/.build/debug/iMessageMaxMenu --design-window --design-menu --design-state setup-contacts --design-dark
```

`--design-state` loads a fixture (`fresh`, `stopped`, `misplaced`, `legacy`, `blocked`, `setup-messages`, `setup-contacts`, `setup-sending`, `contacts-denied`, `connect`, `revoked`, `problem`, `working`, `checking`, `ready`) and never contacts the service. Instead, the real controller runs against a canned `ServiceSystem` from `Sources/iMessageMaxMenu/DesignHarness.swift`. That file holds every design flag. `--design-window` shows the Settings window without taking focus, on Permissions or on the page `--design-open <general|permissions|connections|about>` names. `--design-menu` draws the status menu in a window, because an open menu takes over the pointer. Each prints its window number on its own line, the Settings window first, for `screencapture -x -o -l <number>`. `--design-act <start|stop|allow|copy>` plays an action, and `--design-light`, `--design-dark`, `--design-reduce-motion`, and `--design-slow-motion` override appearance and motion for that process only. `--design-artwork <file.png>` writes every menu bar mood to a contact sheet and exits. `docs/design/settings/` holds the current captures. `docs/design/2026-10-12-companion-overhaul.md` and `docs/design/2026-10-12-benji-polish.md` record the earlier popover panel.
