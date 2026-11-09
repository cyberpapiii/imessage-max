# Uninstalling iMessage Max

This guide removes the app, its background helper, its files and its privacy grants. Each step works from Terminal or over SSH, as the user who ran iMessage Max, unless it says otherwise.

Do the steps in this order. Reset the privacy grants (step 3) before you delete the app (step 4), so `tccutil` can still find the app's bundle id.

## 1. Quit the companion

Choose Quit iMessage Max (⌘Q) in the menu bar bubble, or run:

```sh
pkill -x iMessageMaxMenu
```

Quitting leaves the helper running. Quit first anyway: while the companion runs, `open --args` reaches the running copy and macOS drops the arguments, so the next step would do nothing.

If you turned on **Open at login** on the iMessage Max page of Settings, turn it off before you quit, or remove iMessage Max later in System Settings → General → Login Items & Extensions.

## 2. Remove the helper

```sh
open "/Applications/iMessage Max.app" --args --unregister-helper
```

This launches the app without a window. It unregisters the helper's background item with macOS and then quits. Run it while the user is logged in to the desktop, since `open` needs that session. Use `~/Applications/iMessage Max.app` if that is where the app lives.

Check that the helper is gone after a few seconds:

```sh
launchctl print gui/$(id -u)/com.cyberpapiii.imessage-max.helper
```

Expect a line that starts `Could not find service "com.cyberpapiii.imessage-max.helper"`. If it still prints a running job, stop it the way the companion's Stop does:

```sh
launchctl bootout gui/$(id -u)/com.cyberpapiii.imessage-max.helper
```

## 3. Reset the privacy grants

macOS records the helper's Full Disk Access, Contacts and Automation grants under the app's bundle id, `com.cyberpapiii.imessage-max.menubar`.

```sh
tccutil reset SystemPolicyAllFiles com.cyberpapiii.imessage-max.menubar
tccutil reset AddressBook com.cyberpapiii.imessage-max.menubar
tccutil reset AppleEvents com.cyberpapiii.imessage-max.menubar
```

`tccutil reset All com.cyberpapiii.imessage-max.menubar` resets every service at once. `tccutil` cannot remove a grant that an MDM profile set. Remove that profile from your MDM instead (see [fleet.md](fleet.md)).

A source build or a 1.x install may also appear in Full Disk Access as a bare `imessage-max` executable. Select it in System Settings → Privacy & Security → Full Disk Access and click the minus button.

## 4. Remove the app

For a DMG install, drag iMessage Max from Applications to the Trash, or run:

```sh
rm -rf "/Applications/iMessage Max.app"
```

For a cask install, use Homebrew instead, and skip step 5:

```sh
brew uninstall --zap --cask imessage-max
```

The cask's `uninstall` quits the companion, stops the helper and removes the app and the `imessage-max` link. From the release after 2.0.0, it stops the helper with SIGUSR1, which the helper treats as a stop that stays stopped, so launchd does not start it again from the deleted app. The 2.0.0 cask sends SIGTERM, which stops a 2.0.0 helper for good too, because 2.0.0 has no Keep running setting. `--zap` also removes the launchd job and every path in step 5. Without `--zap`, `brew uninstall --cask imessage-max` leaves those files behind.

## 5. Remove the files

These are the paths the cask's `zap` removes:

```sh
rm -rf "$HOME/Library/Application Support/iMessage Max"
rm -rf "$HOME/Library/Logs/iMessage Max"
rm -rf "$HOME/Library/Caches/com.cyberpapiii.imessage-max.menubar"
rm -rf "$HOME/Library/HTTPStorages/com.cyberpapiii.imessage-max.menubar"
rm -f  "$HOME/Library/Preferences/com.cyberpapiii.imessage-max.menubar.plist"
rm -f  "$HOME/Library/Logs/imessage-max.stderr.log" "$HOME/Library/Logs/imessage-max.stdout.log"
```

- `Application Support/iMessage Max` holds the token, the socket `mcp.sock`, and the `stay-stopped`, `keep-awake`, `automation-answer` and `registered-agent.sha256` files. A 1.x install also kept a copied helper in its `bin` folder.
- `Logs/iMessage Max` holds the helper log, `imessage-max.log`.
- The last line removes the 1.x logs, if any.

A 1.x install also left `~/Library/LaunchAgents/local.imessage-max.plist`. If it is still there, unload and remove it:

```sh
launchctl bootout gui/$(id -u)/local.imessage-max
rm -f "$HOME/Library/LaunchAgents/local.imessage-max.plist"
```

## 6. Disconnect your assistants

Each client keeps an `imessage` entry that now points at nothing. Remove the ones you connected:

```sh
claude mcp remove --scope user imessage
codex mcp remove imessage
plug server remove imessage
plug secret rm imessage-max-token
```

For a client you set up by hand, delete its `imessage` entry from its config file. When the app connected a client by editing its config, it saved the old file next to it as `<name>.imessage-max-backup`. You can delete those backups.

Claude Desktop lists the `.mcpb` extension under Settings → Extensions. Remove it there.

## Check that nothing is left

```sh
launchctl print gui/$(id -u)/com.cyberpapiii.imessage-max.helper
lsof -nP -iTCP:47821 -sTCP:LISTEN
ls "$HOME/Library/Application Support/iMessage Max" "$HOME/Library/Logs/iMessage Max"
```

Expect "Could not find service", no listener, and "No such file or directory" for both folders.
