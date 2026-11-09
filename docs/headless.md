# Running iMessage Max on a headless Mac

This guide is for a Mac with no display, keyboard or person nearby, such as a Mac mini that you reach over SSH and Screen Sharing. It covers what the Mac needs, how to install and update iMessage Max, how to check it from SSH, and what to do when something breaks.

For MDM deployment to many Macs, see [fleet.md](fleet.md). To remove iMessage Max, see [uninstall.md](uninstall.md).

This guide describes 2.1.0. Keep running, Keep this Mac awake, the bridge's desktop-login message and its reconnect after a helper restart need 2.1.0 or later; [CHANGELOG.md](../CHANGELOG.md) lists what changed.

## Checklist

1. Log in to the desktop automatically, or over Screen Sharing after each restart.
2. Never log out. Disconnect Screen Sharing or lock the screen instead.
3. Turn off system sleep: `sudo pmset -a sleep 0 autorestart 1 womp 1`, or turn on **Keep this Mac awake** in the companion.
4. Turn on Remote Login (SSH) and Screen Sharing.
5. Install iMessage Max and grant its four permissions once, over Screen Sharing.
6. Sign in to iMessage in Messages once.
7. Run iMessage Max for one user per Mac.
8. Check health over SSH with `launchctl print` and `diagnose` (see [Check health over SSH](#check-health-over-ssh)).

## Why a desktop login is required

iMessage Max does not click the screen and does not need a display. It still needs a logged-in desktop session.

- The helper is a launchd agent that the app registers with `SMAppService`. macOS loads it in the user's GUI domain, `gui/<uid>`. That domain exists only while the user is logged in to the desktop (an Aqua session), on screen or switched out.
- Apple's `imagent`, which sends and receives iMessages, also runs only in that session.
- An SSH login does not create a GUI domain. From SSH alone, the helper cannot start.

When nobody is logged in to the desktop, a stdio client (Codex, Claude Desktop, the `.mcpb` extension) gets this error from the bridge: "iMessage Max is not running, and `<user>` is not logged in to this Mac's desktop." The fix is a desktop login, not opening the app.

To see who is logged in to the desktop, run:

```sh
stat -f%Su /dev/console
```

It prints the user at the console, or `root` at the login window. `echo 'show State:/Users/ConsoleUser' | scutil` lists every desktop session, including switched-out ones, under `SessionInfo`.

## Log in automatically

Turn on automatic login for the user that runs iMessage Max. Then the Mac logs that user in to the desktop after every restart, and the helper starts on its own.

- In System Settings → Users & Groups, set "Automatically log in as" to that user. You must be an administrator. ([Apple: Users & Groups settings](https://support.apple.com/guide/mac-help/change-users-groups-settings-mtusr001/mac), [Apple: log in automatically](https://support.apple.com/en-us/ht201476))
- Check it from SSH with `sysadminctl -autologin status`.

Automatic login requires FileVault off. Apple's help says: "If FileVault is turned on, automatic login is disabled." Check FileVault with `fdesetup status`.

Automatic login also means anyone who can restart the Mac gets the user's session. Decide whether that fits where the Mac lives.

### With FileVault on

Keep FileVault on if the disk must stay encrypted. Then someone must log in after every restart:

1. Connect with Screen Sharing.
2. Log in as the iMessage Max user at the login window.
3. Disconnect Screen Sharing. Do not log out.

On Apple silicon with macOS 26 or later, you can unlock FileVault over SSH after a restart, when Remote Login is on and a network connection is available ([Apple Platform Security: Managing FileVault in macOS](https://support.apple.com/guide/security/sec8447f5049/web)). **Not verified:** whether that SSH unlock goes on to a desktop login for the user, with the GUI domain, the helper and `imagent` running. Until someone tests it, plan to log in over Screen Sharing after the SSH unlock. Then check with `stat -f%Su /dev/console` and the health checks below.

## Never log out

Logging out ends the desktop session. The helper and `imagent` stop with it, and nothing starts them again until the next desktop login.

- When you finish with Screen Sharing, close the Screen Sharing window. The session stays logged in.
- To keep the session private, lock the screen first: Apple menu → Lock Screen, or Control-Command-Q.

**Not verified:** sends and the hidden Messages launch while the screen is locked. Reads from chat.db do not depend on the lock. Test a send to your own handle on a locked Mac before you rely on it.

## Keep the Mac awake

With system sleep on, the endpoint stops answering and the live inbox stalls until the Mac wakes. Turn system sleep off. Display sleep is fine.

```sh
sudo pmset -a sleep 0 autorestart 1 womp 1
```

- `sleep 0` turns off system sleep.
- `autorestart 1` starts the Mac again after a power failure. It exists on desktop Macs such as the Mac mini.
- `womp 1` wakes the Mac for a network magic packet.

Optionally also run `sudo pmset -a powernap 0`, and put the Mac on a UPS. Check the result with `pmset -g`. The `pmset` man page documents each setting (`man pmset`).

Without `sudo`, turn on **Keep this Mac awake** on the iMessage Max page of the companion's Settings. It is off by default. While it is on, the running helper holds a `PreventUserIdleSystemSleep` power assertion, so the Mac does not sleep while idle; the display can still sleep. It does not stop sleep from a closed lid, the Apple menu or a low battery, and it does nothing while the helper is stopped. The setting is the file `keep-awake` in `~/Library/Application Support/iMessage Max/`: present means on. The helper checks for it every 5 seconds, so a change needs no restart. `pmset -g assertions` lists the assertion as "iMessage Max: Keep this Mac awake". `autorestart` and `womp` still need `pmset`.

`diagnose` reports the sleep setting under `power`: `status` is `stays_awake` when system sleep is off or the helper holds its assertion, and `idle_sleep` with `sleep_minutes` and a `fix` when the Mac sleeps while idle.

## Turn on remote access

In System Settings → General → Sharing:

- Turn on **Remote Login** for SSH.
- Turn on **Screen Sharing** for the one-time setup and for logins after a restart.

## Install

Do the first install over Screen Sharing, because the permission steps need clicks.

With Homebrew:

```sh
brew install --cask cyberpapiii/tap/imessage-max
```

From the DMG on the [latest release](https://github.com/cyberpapiii/imessage-max/releases/latest):

```sh
hdiutil attach iMessage-Max-<version>.dmg -nobrowse
ditto "/Volumes/iMessage Max/iMessage Max.app" "/Applications/iMessage Max.app"
hdiutil detach "/Volumes/iMessage Max"
```

Newer macOS prints a deprecation warning for `hdiutil attach` and still mounts the image.

Then open `/Applications/iMessage Max.app` in the Screen Sharing window. The app must run from `/Applications` or `~/Applications`. From anywhere else it offers Move to Applications and does not register the helper.

## Grant permissions once, over Screen Sharing

The app opens its Settings window on Permissions. Turn on each permission while you watch the screen:

- **Background activity**, so launchd runs the helper. Leave iMessage Max on in System Settings → General → Login Items & Extensions.
- **Full Disk Access**, to read `~/Library/Messages/chat.db`.
- **Contacts**, to show names in place of numbers.
- **Automation** for Messages, to send. Click **Allow Messages Access** and answer the macOS prompt. Do not leave Automation "not determined": nobody will see the prompt later.

System Settings lists each one as "iMessage Max". On many Macs, an MDM profile can grant all of these without clicks. See [fleet.md](fleet.md).

On the iMessage Max page of Settings, consider turning on **Open at login**. The helper runs without the companion, and moves to a new binary on its own after an update. Only the companion can load a launchd plist that an update changed, and with Open at login it does that by itself (see [Update](#update)).

## Sign in to iMessage once

Open Messages over Screen Sharing and sign in to iMessage with the Apple Account the agent should use. Send or receive one message so `chat.db` exists.

The helper starts Messages hidden when it needs it, so nobody sees an alert that iMessage signed out. `diagnose` reads the account for you: `capabilities.imessage_account` is `supported` with detail `signed_in` while it works (see [Check health over SSH](#check-health-over-ssh)). Check it after an Apple Account password change and after every major macOS update.

SMS from a Mac goes through a paired iPhone (Text Message Forwarding), and Apple ties that to iMessage being signed in with the same Apple Account. So plan on iMessage being signed in even if the agent only texts phone numbers. If Messages does report a connected SMS account with no iMessage account turned on, `diagnose` says `sms_only`: sends to phone numbers go out as SMS, and email addresses cannot be reached.

## Keep attachments on disk

With Messages in iCloud on, macOS can keep older attachments only in iCloud. `get_attachment` then returns `attachment_offloaded` with `download_started: false`: iMessage Max cannot download the file, and retrying does not help. Messages downloads it when someone opens the conversation in Messages on this Mac. `diagnose` reports `attachments_offloaded` as `degraded` for this reason. If agents need old attachments, keep plenty of free disk space and turn off Optimize Mac Storage under System Settings → your Apple Account → iCloud. **Not verified:** which setting decides Messages attachment offload on macOS 15 and later.

## One user per Mac

The released app's helper always listens on port 47821. Run iMessage Max for one desktop user on each Mac. If a second user logs in with iMessage Max installed, their helper cannot bind the port and restarts every 10 seconds. Leave iMessage Max off in that user's Login Items, or do not log them in.

Each user's token lives in that user's `~/Library/Application Support/iMessage Max/token`. Run the SSH checks below as the iMessage Max user.

## Keep running

**Keep running** is on the iMessage Max page of the companion's Settings and is on by default. While it is on, launchd starts the helper again after a crash or a plain quit (from `kill` or Activity Monitor), after its 10 second throttle. Turn it off and a quit leaves the helper stopped. No setting keeps the helper running after a logout.

The companion's **Stop iMessage Max…** keeps the helper stopped either way, until you start it again or log in again. The setting is the file `stay-stopped` in `~/Library/Application Support/iMessage Max/`: present means Keep running is off.

In `launchctl print`, `last exit code = 75: EX_TEMPFAIL` means the helper stopped with Keep running on and launchd started it again. That is normal after an update or a restart.

## Update

With Homebrew:

```sh
brew upgrade --cask imessage-max
```

You do not need to open the app. The helper reads its own executable every 5 seconds. When an update replaces it, the helper waits until no tool call is running (at most 2 minutes), stops with exit code 75, and launchd starts the new binary about a second later. This works with the companion closed and with Keep running off. The helper log shows:

```
INFO Executable replaced on disk at /Applications/iMessage Max.app/Contents/MacOS/imessage-max; waiting for the copy to finish
INFO Update installed; stopping so launchd starts the new binary
INFO Stopped exit=75
INFO Started version=<new version> pid=<new pid> ...
```

If the companion is running, brew quits and reopens it, and it also checks every minute for a helper older than the app, answering or not.

Some updates also change the helper's launchd plist. launchd keeps the plist it loaded when the helper was registered, and only the app can load the new one. The helper still moves to the new binary on its own, then logs this warning:

```
WARN This update changed the helper's launchd plist, and launchd still runs the helper under the old one. Open iMessage Max, or run: open "/Applications/iMessage Max.app" --args --register-helper
```

When you see it, open the app over Screen Sharing, or run the two commands below from SSH. A companion that is running does this by itself within a minute.

To restart the helper on the new binary and plist from SSH at once, quit the companion, then open the app with `--register-helper`:

```sh
pkill -x iMessageMaxMenu
open "/Applications/iMessage Max.app" --args --register-helper
```

Quit the companion first. While it runs, `open --args` reaches the running copy and macOS drops the arguments. `--register-helper` also registers the helper again when the update changed its launchd plist.

`open` from SSH reaches the desktop session only when you SSH in as the user who is logged in to the desktop. **Not verified:** this on a Mac with no display or with a dummy display plug.

For a DMG update, replace the app as in [Install](#install). The helper moves to the new binary on its own; run the two commands above only if the log shows the plist warning.

Stdio clients (Codex, Claude Desktop) reconnect on their own after a helper restart. The bridge waits up to 15 seconds for the helper.

## Check health over SSH

SSH in as the iMessage Max user. These commands only read state.

Is someone logged in to the desktop?

```sh
stat -f%Su /dev/console
```

Is the helper loaded and running? This is the `launchctl` part of `make status`:

```sh
launchctl print gui/$(id -u)/com.cyberpapiii.imessage-max.helper | grep -E '^\s(state|pid|runs|last exit code) ='
```

A healthy helper shows `state = running` and a `pid`. "Could not find service" means nobody is logged in to the desktop, someone used Stop iMessage Max…, or the helper is not registered. A `runs` count that keeps climbing means it is crashing or failing to start.

Is something listening on the port?

```sh
lsof -nP -iTCP:47821 -sTCP:LISTEN
```

Does the helper answer, and is it ready? This calls the `diagnose` tool over HTTP. curl reads the token on stdin (`-K -`), so it never shows in `ps`. `/usr/bin/jq` ships with macOS 15 and later.

```sh
printf 'header = "Authorization: Bearer %s"\n' "$(cat "$HOME/Library/Application Support/iMessage Max/token")" |
curl -sS -m 15 -K - -X POST http://127.0.0.1:47821 \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "MCP-Protocol-Version: 2026-07-28" \
  -H "Mcp-Method: tools/call" \
  -H "Mcp-Name: diagnose" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"diagnose","arguments":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/clientInfo":{"name":"ssh-check","version":"1.0"}}}}' |
jq '.result.content[0].text | fromjson | {status, version, database: .database.status, contacts: .contacts.status, automation: .capabilities.perm_automation, imessage: .capabilities.imessage_account}'
```

A healthy Mac prints:

```json
{
  "status": "ready",
  "version": "2.1.0",
  "database": "accessible",
  "contacts": "authorized",
  "automation": {
    "state": "supported",
    "detail": "authorized"
  },
  "imessage": {
    "state": "supported",
    "detail": "signed_in"
  }
}
```

Drop the final `jq` filter to see every capability and its `fix`.

Is the app signed by the expected team? This is the signature part of `make status`:

```sh
codesign -dvv "/Applications/iMessage Max.app" 2>&1 | grep -E 'Authority|TeamIdentifier'
```

Expect `TeamIdentifier=HJF7LN64XX`.

What did the helper log? The log is `~/Library/Logs/iMessage Max/imessage-max.log`. Each line starts with a UTC timestamp. The log never holds message text, arguments or the token.

```sh
tail -n 50 "$HOME/Library/Logs/iMessage Max/imessage-max.log"
grep -E 'Started|WARN|ERROR|auth=rejected' "$HOME/Library/Logs/iMessage Max/imessage-max.log" | tail -n 20
```

Each start logs one `Started version=… pid=… transport=http addr=127.0.0.1:47821` line. Each tool call logs one `call tool=… outcome=… ms=…` line.

## Troubleshooting by symptom

**The bridge says the user "is not logged in to this Mac's desktop".** Nobody has a desktop session for that user. Log in over Screen Sharing, or turn on automatic login, then disconnect without logging out.

**`launchctl print` says "Could not find service".** Check `stat -f%Su /dev/console` first. If the user is logged in, someone used Stop iMessage Max…, which unloads the helper, or the helper is not registered. Run `open "/Applications/iMessage Max.app" --args --register-helper` (quit the companion first), or open the app over Screen Sharing and choose Start iMessage Max.

**The helper is loaded but not running, and `runs` does not climb.** It quit with Keep running off. Run the `--register-helper` command above, or open the app and choose Start iMessage Max. Also check that iMessage Max is on in System Settings → General → Login Items & Extensions.

**`runs` climbs every 10 seconds.** The helper starts and exits. Read the end of the log. Common causes are another process on port 47821 (`lsof -nP -iTCP:47821 -sTCP:LISTEN`), often a second user's helper, and a token file with the wrong mode or owner. The token file must be mode 0600 and owned by the user.

**curl gets `Connection refused`.** Nothing listens on 47821. Work through the three cases above.

**curl gets HTTP 401.** The token is wrong. Read it as the same user that runs the helper. The log shows one `auth=rejected` line per refused request.

**`diagnose` shows `database: "permission_denied"`.** Full Disk Access is off for iMessage Max. Turn it on over Screen Sharing. The helper reads the grant only at launch, so open the app afterwards: it restarts the helper and checks.

**`contacts` is `not_determined` or `denied`, and names show as numbers.** Open the app over Screen Sharing and choose Allow Contacts under Contacts. For `denied`, also turn on iMessage Max in System Settings → Privacy & Security → Contacts.

**`automation` is `permission-gated` with detail `not_determined` or `denied`.** Sends return `failed` with disposition `not_started` and send nothing. Over Screen Sharing, click Allow Messages Access on the Permissions page, or turn on Messages under iMessage Max in System Settings → Privacy & Security → Automation.

**`automation` is `unverified` with detail `messages_not_responding`.** Messages is running but hung. Sends fail at once until it answers. Quit it with `pkill -x Messages`. The helper starts it again, hidden, when it needs it.

**`imessage` is `degraded` with detail `signed_out`, `disabled` or `no_account`.** iMessage is signed out, turned off, or was never set up, and the send capabilities are `degraded` too. With `disabled` or `no_account`, a send to someone new returns `failed`, `not_started` and sends nothing; with `signed_out`, Messages takes the send but cannot deliver it, so it ends `uncertain` or `failed_delivery` and the result names the account state. Over Screen Sharing, open Messages → Settings → iMessage, sign in with the Apple Account the agent uses, and turn on Enable this account. `diagnose` keeps an answer for 60 s, so check again a minute later. `signed_out` also shows when the Mac is offline.

**`imessage` is `degraded` with detail `connecting`.** iMessage is still connecting, usually just after Messages started. Sends are not blocked. Check again in a minute; if it stays there, treat it as `signed_out`.

**`imessage` is `unverified`.** Diagnose could not read the account. Detail `messages_not_running`: Messages is closed, and diagnose starts it hidden only until it has read the account once; any send starts it again, or run `open -gj -a Messages` as the logged-in user. Detail `messages_not_responding`: Messages did not answer within 2 s, see the hung-Messages entry above. Detail `not_checked`: Automation is not granted, fix that first.

**Sends end `uncertain` or `failed` with no clear cause.** Check `imessage` in `diagnose` first. If it says `signed_in`, the recipient may not reach iMessage; check the chat with `get_messages`.

**The endpoint or the live inbox stops for a while, then catches up.** The Mac slept. Check `power.status` in `diagnose`, or `pmset -g` for `sleep 0`, and turn on Keep this Mac awake or turn off system sleep.

**An agent answers old messages as if they were new.** Messages in iCloud synced old history into `chat.db`. `get_messages_since` marks those rows `late: true`, and its `max_age` parameter skips anything older than you choose. See `get_messages_since` in the [README](../README.md).

**`get_attachment` returns `attachment_offloaded` for old files.** The file is only in iCloud. See [Keep attachments on disk](#keep-attachments-on-disk).

**`diagnose` reports an older version after an update.** The old helper is still running, usually because a tool call is still running (the helper waits for it up to 2 minutes) or the copy of the app has not finished. Check the log for `Executable replaced on disk`. If it does not change within a few minutes, run the two commands in [Update](#update).

## Not verified yet

These are open questions, not known failures. The Unverified scenarios table in the [088 plan](../plans/088-headless-reliability.md) has a test plan for the first three.

- Whether a macOS 26 FileVault unlock over SSH goes on to a desktop login.
- Whether the hidden Messages launch and Apple events work on a Mac with no display, or with a dummy display plug.
- Whether sends work while the screen is locked.
- Whether `open` from SSH reaches the desktop session on a Mac with no display.
- Which setting decides Messages attachment offload.
- What Messages reports for an account that signed out on its own: turned on but disconnected, turned off, or gone. `diagnose` reads all three as not signed in (`signed_out`, `disabled`, `no_account`), but only the signed-in case was checked on a real Mac.
