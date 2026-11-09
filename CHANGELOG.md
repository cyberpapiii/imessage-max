# Changelog

## Unreleased

### Service

- New **Keep running** setting on the iMessage Max page of Settings, on by default. While it is on, the helper starts again after a plain quit from Activity Monitor or `kill`, not only after a crash. Turn it off and a quit leaves the helper stopped. The change applies at once, with no restart. Stop iMessage Max… keeps the helper stopped either way, until you start it again or log in again. The setting is the `stay-stopped` file in `~/Library/Application Support/iMessage Max/`.
- An update that changes the helper's launchd plist now takes effect. macOS keeps a registered helper on the plist it first loaded, so the app records the plist it registered (`registered-agent.sha256` in `~/Library/Application Support/iMessage Max/`) and, when the bundled plist differs, registers the helper again on launch or on `--register-helper`. A Mac updating from 2.0.0 has no record yet and registers again once, which loads the new Keep running behaviour. macOS may show its "background item added" notice that one time. Permissions are unaffected.
- iMessage Max works without you ever opening Messages. When the helper needs Messages, to check or ask for Automation and before a send, it starts Messages hidden: no Messages window comes on screen and focus stays where it was. A send no longer brings Messages up.
- `diagnose` no longer reports Automation as `unverified` with detail `messages_not_running` whenever Messages is closed. It reports the last answer macOS gave, which the helper keeps in `automation-answer` beside its token, and with none it starts Messages hidden once to get one. A send that Messages refuses for lack of Automation (-1743) updates the kept answer to denied.
- A send no longer waits 30 s on an Automation prompt nobody can see. Before its first script it asks macOS without prompting, and when Automation is denied or was never granted it returns `failed`, `not_started`, `retry_safe=true` with the fix at once, and keeps the answer. Previously a first send on a headless Mac timed out and reported `may_have_completed`, `retry_safe=false`, though nothing was sent.
- `diagnose` reports Automation `not_determined` as `permission-gated` with a fix ("Open iMessage Max and turn on Automation."), not `unverified`. A kept answer other than authorized, or a failed start of Messages, is checked again at most every 5 minutes, so a grant made in System Settings while Messages is closed shows up without restarting the helper.
- A Messages that is running but hung no longer hangs `diagnose` and every send. The Automation probe is bounded to 2 s with one probe in flight. `diagnose` then reports Automation `unverified` with detail `messages_not_responding` (a new `PermissionStatus` word), and a send fails at once as not started.
- osascript runs go through a gate of 4 at a time, and each run waits for its exit through a termination handler instead of a parked thread. A burst of sends no longer exhausts threads and reports finished scripts as timeouts.
- A file send's transfer-status polls start Messages hidden first, so a Messages that quit mid-transfer does not come back with its window.
- Send errors are classified by AppleScript error number, not English text, so they read the same on every language and region. "Operation not permitted" is no longer taken for an Automation refusal.
- `diagnose` reports `ready` whenever chat.db is readable. A Mac with Contacts left off is no longer `needs_setup`; `perm_contacts` and the send capabilities report Contacts and Automation.
- SIGUSR1 stops the helper for good: it drains as on SIGTERM, then exits 0 whatever Keep running says, so launchd leaves it down. The cask's `uninstall` now sends USR1 instead of TERM, because with Keep running on a SIGTERM exits 75 and launchd would relaunch the helper from the app `brew uninstall --cask` just deleted.
- A log write that fails, on a full disk, an I/O error or a closed stderr, no longer aborts the helper. The line is dropped, where before the helper crashed and launchd relaunched it into the same failure every 10 s.
- The stdio bridge that Codex, Claude Desktop and the `.mcpb` extension launch survives a helper restart (update, crash or Keep running relaunch). Before, every restart ended the session for good, and a client on a headless Mac stayed broken until someone reconnected it. The bridge now reconnects, replays the client's `initialize` and `notifications/initialized` for a legacy session, and sends on what the client wrote meanwhile (up to 64 messages). A request that was running when the helper went away gets a -32000 error that says to retry it, and to check the chat before retrying a send. The bridge waits up to 15 s for the helper, at start and after a drop, up from 3 s, which was shorter than launchd's 10 s relaunch throttle. When it gives up (exit 75) and this user is not logged in to the Mac's desktop, the error says that a desktop login is needed, where before it said to open iMessage Max, which cannot work over SSH.
- A NUL character (U+0000) in `send` text, a file path or a recipient no longer crashes the helper. `send` returns `failed` with disposition `not_started` and says why, and nothing is sent.
- When another process holds port 47821, such as iMessage Max for another user on the same Mac, the helper no longer exits every 10 s and takes the stdio socket down with it. It logs one line naming the port, keeps serving Codex, Claude Desktop and other stdio clients over its socket, and binds the port once it frees, retrying from 1 s up to every 30 s. `diagnose` reports `http.state` `port_in_use` with a fix. The `Started` log line now comes after the bind, with `http=port_in_use` while the port is taken.
- The helper's launchd plist sets `ExitTimeOut` to 20 s. launchd's 5 s default could SIGKILL a helper still draining a send on SIGTERM, and relaunch it even with Keep running off. The plist changed, so an update registers the helper again once.
- A token file in `~/Library/Application Support/iMessage Max/` that other users can read (for example mode 644 after a restore) is set to 600 with a warning in the log, instead of stopping the helper at every launch. A `--token-file` with such a mode still stops the server.
- A helper that cannot start logs one `Startup failed: <reason>` line before it exits.
- The helper checks its socket file every 30 s and listens again when the file was deleted, or when another helper held it at launch and has since gone. Open stdio sessions keep working.

### Docs

- New operator guides. [docs/headless.md](docs/headless.md) covers running on a headless Mac: why a desktop login is required, automatic login and FileVault, never logging out, power settings, one-time grants over Screen Sharing, updates, health checks over SSH and troubleshooting by symptom. [docs/fleet.md](docs/fleet.md) covers MDM deployment, with a sample profile that grants Full Disk Access, Contacts and Automation for Messages to `com.cyberpapiii.imessage-max.menubar` and allows its helper through Managed Login Items for team HJF7LN64XX; it is untested end to end. [docs/uninstall.md](docs/uninstall.md) covers removal for DMG and cask installs, including `--unregister-helper`, `tccutil reset` and the cask's zap. README and AGENTS.md link them.

### Companion app

- A helper that stops at every launch shows "iMessage Max can't start" with the reason from its log, such as an unusable folder, instead of Stopped. Stop still works.
- Another user's iMessage Max on the same port shows as a port conflict that says Plug can't connect while Codex and Claude Desktop still can, instead of "access key refused" and a restart that could not help.

- The menu bar bubble opens a plain macOS menu in place of the popover panel. Its header shows Max's face and one status word: Running, Needs attention, Stopped or Setting up. One more line names the next thing to do, such as Turn on Full Disk Access, and opens Settings on the page that fixes it. Below that are Connections (such as "Connections: Plug", or None), Settings… (⌘,) and Quit iMessage Max (⌘Q). Quitting still leaves the helper running.
- Setup, permissions, connections and help moved to a Settings window with a sidebar, back and forward buttons, and grouped forms built from stock controls, so macOS 26 draws its own Liquid Glass. The sidebar's first row, with the face and the status word, is the iMessage Max page itself, as the account row is in System Settings. Below it are Permissions, Connections, and About & Help. Buttons and switches use the system accent colour. Opening the app shows the window on Permissions.
- The switch that started and stopped the helper is now a Stop iMessage Max… button on the iMessage Max page, which asks first, and a Start iMessage Max button when it is stopped.
- Permissions lists Background activity, Full Disk Access, Contacts and Automation by their System Settings names, each with what it is for and its status: On or Off, Allowed or Not allowed, and Some contacts for limited Contacts access. The first missing permission shows its explanation and buttons in its row. Coming back to the window from System Settings checks again.
- The Automation row no longer asks you to open Messages ("Open Messages and Check"). It shows its status with Allow Messages Access or Open Automation Settings, and Check Again; the helper starts Messages hidden by itself.
- The Automation row keeps Allow Messages Access while macOS has never asked, now that the helper reports that state as `permission-gated`. Open Automation Settings appears only after a denial.
- Connecting an assistant is a section under Permissions once every permission is on and no assistant is connected. It leaves for good once one connects, an assistant calls a tool, or you choose Not Now.
- The Try it step and its sample prompt are gone. The first time an assistant uses iMessage Max, the menu header and the iMessage Max page say so, in place of a notice that covered the panel's content.
- The custom-painted cards, buttons, switch and glyphs are gone in favour of SF Symbols and system controls. Copy buttons say Copied on the button, and VoiceOver reads out the result of an action.
- The design harness shows the Settings window with `--design-window --design-open <general|permissions|connections|about>` and draws the status menu with `--design-menu`. Captures of every page and of the menu in each status are in `docs/design/settings/`.

### Server

- Phone numbers saved without a country code are read in the Mac's region. +1 is assumed only in the US, Canada and the rest of the North American Numbering Plan. Elsewhere a leading 00 (or the region's international prefix, such as 0011 in Australia) becomes +, a `(0)` trunk digit is dropped, and a national trunk 0 is replaced by the region's calling code, so "07911 123456" on a UK Mac is +447911123456. Extensions (`x12`, `ext. 12`) are ignored. Contact names now show for numbers saved this way outside the US, and a number that cannot be read without guessing is left unread instead of being taken as a US number.
- `send` by contact name no longer sends to a number or email that has no conversation in Messages. It returns `ambiguous` with that contact as the one candidate and sends nothing. Before, a contact's number saved without a country code was read as a US number, and a send by name could go at once to a stranger's +1 number.
- Contacts that have only a company name or a nickname are loaded. A contact's display name is the given and family name, else the nickname, else the company.
- `diagnose` fixes for the helper inside the app name the permission by its System Settings name, such as "Open iMessage Max and turn on Full Disk Access." `assistant_calls` is unchanged.
- `diagnose` from the HTTP helper, on any lane, has an `http` field: `port`, `state` (`starting`, `listening` or `port_in_use`) and, while the port is taken, a `fix`. A `--direct` stdio server leaves it out.

## 2.0.0

iMessage Max is now a Mac app. Someone who never opens Terminal can install it, grant its permissions, connect an assistant and try it, all from one panel. It installs from a notarized DMG or with `brew install --cask cyberpapiii/tap/imessage-max`, and the Homebrew formula is retired.

### Install

- Every build is signed with Developer ID and hardened runtime. The release is `iMessage-Max-<version>.dmg`, holding `iMessage Max.app`, with the app and the DMG notarized and stapled.
- The server runs as a helper inside the app (`Contents/MacOS/imessage-max`), registered with `SMAppService` under the label `com.cyberpapiii.imessage-max.helper`. It starts at login and restarts after a crash. macOS charges its Full Disk Access, Contacts and Automation to the app, so each Privacy list shows one "iMessage Max", and the grants survive updates.
- The cask `imessage-max` in `cyberpapiii/tap` installs the same DMG on Apple silicon with macOS 15 or later, and links `imessage-max` into Homebrew's `bin`. `brew upgrade --cask` leaves the helper running for the companion to restart on the new binary. `brew uninstall --cask` stops the helper and removes the app. `--zap` also removes the launchd job, token, socket, logs and preferences.
- Releases no longer ship `imessage-max-macos.tar.gz`, and the formula `cyberpapiii/tap/imessage-max` is disabled with a message that points at the cask.
- A Claude Desktop extension, `iMessage-Max-<version>.mcpb`, ships with each release. It runs the stdio bridge, so Claude Desktop needs no permissions of its own.
- `make install` builds the app, installs it over the released copy in `/Applications` or else in `~/Applications`, and registers the helper. `make install-agent` and `swift/launchd/local.imessage-max.plist` are gone.

### Companion app

- First run is six steps on the home page, in order: Allow in the background, Read messages, Show names, Send messages, Connect an assistant, and Try it. The first unfinished step opens in place with its buttons. Each step is judged again on every check, so reopening the app resumes where you left off, and a grant turned off in System Settings sends the panel back to its step.
- Connect an assistant, and the Connection page, find Claude, Claude Code, Codex, Plug and Cursor on this Mac and connect each with one button. The app edits only its own entry in a client's config and keeps a backup of the old file.
- Try it turns green once the helper serves its first tool call from an assistant. `diagnose` reports that count as `assistant_calls`.
- Contacts is asked by the app on the helper's behalf, then the helper restarts, because a helper inside an app cannot prompt for Contacts itself.

### Server

- Every `diagnose` fix names the step in the app that fixes it, not a Terminal command.
- `imessage-max` with no transport flag is a bridge that copies stdio to the running helper over `~/Library/Application Support/iMessage Max/mcp.sock` (mode 0600). Only the helper needs permissions. `--direct` serves stdio in process, as 1.x did.

### Breaking

- The HTTP endpoint moved from port 8080 to 47821, and every request needs `Authorization: Bearer <token>`. The token is in `~/Library/Application Support/iMessage Max/token`. The Connection page reconnects each client with it.
- Stdio clients that run `imessage-max` reach the helper through the bridge, so iMessage Max must be running.
- `--request-contacts-access` and `--request-messages-access` are gone. The app's Show names and Send messages steps ask for those grants.

### Upgrading from 1.x

1. Run `brew uninstall imessage-max`. The formula's `imessage-max` link would block the cask's.
2. Install the app from the DMG or the cask, then open it.
3. The panel opens on Finish the update. Choose **Replace the older helper**. It boots out the `local.imessage-max` agent, removes `~/Library/LaunchAgents/local.imessage-max.plist`, and registers the app's helper.
4. Follow the steps for the permissions, then connect each assistant again, because the port and token changed.

The 1.x logs, `~/Library/Logs/imessage-max.stdout.log` and `~/Library/Logs/imessage-max.stderr.log`, stay until you delete them or run `brew uninstall --zap --cask imessage-max`.

### Fixes

- SIGTERM exits 0 instead of aborting in the shutdown drain, so `make restart` and updates no longer leave a crash report.

## 1.8.0

### Performance

- `search` counts `filtered_hidden` from the filtered chats instead of a second scan of every message.

### Tooling

- `make verify` probes before it sleeps, so a healthy install verifies in about 0.1 s instead of 1.3 s. Every health probe in `make verify`, `verify-db` and `status` now times out, so a server that accepts connections but never answers fails the check instead of hanging `make`. `verify-db` ends the session it opens.
- `make build` uses the native build system. Swift 6.4's default build system writes the binary to `.build/out/Products/Release`, a path the existing Full Disk Access grant does not cover, so the service could not read chat.db after an upgrade.

### Observability

- Every `tools/call` logs one line when it ends: tool, lane, outcome (`ok`, `tool_error`, `internal_error`, `cancelled`, `unknown_tool`) and duration in ms. It never logs arguments. It replaces the legacy era line for tool calls.
- stderr lines now start with an ISO 8601 UTC timestamp, and startup logs the version, pid and transport.

### Fixes

- Cancelling one `tools/call` no longer aborts other clients' in-flight queries: the SQLite interrupt reaches only the cancelled call's connections. The stdio lane now shares the HTTP lanes' dispatch, so a cancelled stdio call interrupts its queries too.
- `make restart`, upgrades and any other SIGTERM no longer hang while a client holds an SSE stream open. The server closed nothing, waited for the stream forever, and launchd ended it with SIGKILL after 20 s. Shutdown now closes SSE streams first and takes about 0.2 s, with a 15 s cap on draining in-flight calls.
- Ending a session (DELETE, expiry) now ends its SSE response. The last chunk was never written, so the client's GET stayed open.
- Every internal timed wait (SSE keep-alive, request-body deadline, send verification, session sweeps) leaked its timer, continuation and gate. Waits now run on a cancellable Dispatch timer that is released when the wait ends.
- Live inbox notifications no longer stay off for the life of the process when chat.db is unreadable at startup (Full Disk Access not yet granted, disk not mounted). The watcher keeps retrying, logs one warning, and starts once chat.db can be read. A replaced chat.db (restore, reset) resets the watcher instead of silencing it until new ROWIDs pass the old maximum.
- `get_chat_details` for a well-formed chat id with no chat returns `chat_not_found` instead of `query_failed` "Internal error" and an ERROR log line. Not-found errors from `get_chat_details`, `get_messages`, `get_unread`, `get_context`, `get_attachment` and `send` now name the tool that returns a current id.
- `get_context` rejects a malformed `message_id` or `chat_id` as `invalid_id` before it opens chat.db. With the database unreadable it reported `permission_denied` instead.
- A client that holds an SSE stream open but sends no requests keeps its session. Only requests refreshed a session before, so a notification-only listener lost its session and its stream an hour after its last call, or after 5 minutes when the server was near its session cap.

## 1.7.1

### Fixes

- `search` and search `include_context` no longer hang on modern chat.db: the correlated `has_reactions` `instr`/`substr` subquery is gone; reactions are batched after the Swift trim. `search` also `instr`s `attributedBody` so a NULL-`text` inbox does not burn the 500-row fetch window. A cancelled `tools/call` interrupts in-flight SQLite.

## 1.7.0

Seven techniques borrowed from a study of [openclaw/imsg](https://github.com/openclaw/imsg) (plans 079 to 085).

### Added

- `get_messages_since`: ROWID-cursor pull of new messages across chats, in arrival order. Call it with no cursor to get the current cursor, then poll with `since_rowid`.
- HTTP mode watches `chat.db` (kqueue on the db, wal, and shm files with inode re-arm, plus a fallback poll) and pushes `notifications/imessage/new_messages` over the legacy SSE stream when MAX(ROWID) grows. `diagnose` reports `live_inbox` as `supported` while the watcher runs.
- `send` responses carry `disposition` (`completed`, `not_started`, or `may_have_completed`) and `retry_safe`, derived from the phase the AppleScript reached. `confirmed` is documented as a chat.db row match within the verification window, not a delivery receipt.
- `diagnose` reports `database.features` from a schema probe of `chat.db`; the reply, edit, and custom-emoji columns are guarded by those flags instead of assumed.
- Headless Contacts access policy: the server asks for Contacts access only when started from a terminal. `--request-contacts-access` grants it once; `--contacts-policy request|skip` and `IMESSAGE_MAX_CONTACTS_POLICY` override the terminal detection. `diagnose` reports `not_requested_headless` with the exact command to run.
- `make verify-db` calls `diagnose` over HTTP after install and fails with Full Disk Access remediation when the database is not readable; `make install` is gated on it. The startup log and the `database.fix` string name the binary to add to Full Disk Access.

### Fixes

- `get_messages has:"links"` and `search has:"link"` match URL preview balloon rows; link-preview payload attachments are no longer listed.
- Send attachments are staged through a symlink-safe file handle into a 0700 directory; `SecurePath` normalizes the path lexically and rejects symlinks on every component.
- Contacts cache refreshes on a Contacts change and on a 30 s TTL, and is dropped as soon as access is revoked; no restart needed.
- A `permission_denied` database probe retries on the next query, so granting Full Disk Access takes effect without a restart.
- `perm_contacts` stays `supported` when the CI guard skips contact loading.

## 1.6.0

### Added

- `get_messages` renders group system messages (renames, member adds and removes) as a typed `event` object instead of null-text rows; previews describe them too.
- Messages carry `reply_to`, `reply_count`, and `edited`, mirrored onto `search` and `get_context` results.
- Custom emoji and sticker reactions are surfaced, and reaction removals are applied.
- `list_chats`, `search`, `get_unread`, and `find_chat` hide Apple-flagged filtered chats by default, report the hidden count as `filtered_hidden`, and accept `include_filtered`.
- `get_context contains` searches past the newest 500 messages and reports `not_found_in_window` at the cap.

### Removed

- The `reply_to` parameter on `send`. It was never implemented; the Messages scripting interface has no reply primitive.

### Fixes

- Paginated tools derive `more` from the cursor, so `more:true` with a null cursor no longer appears on a no-message tail.
- `ChatIdentifier` rejects sign-prefixed row ids; `get_unread chat_not_found` is valid JSON; `queryFailed` and `invalidData` map to the fixed internal-error text.
- `Database.prepare` checks every `sqlite3_bind_*` return code.
- `terminateSession` removes the session before stopping its server; `ResumeGate.arm` no longer enqueues a timer for an already-resumed task.
- HTTP request body reads are bounded by a 408 deadline; the Hummingbird idle timeout is enabled on the HTTP1 channel.
- `diagnose` reports contacts as `skipped_ci` when the CI guard is active.

### Performance

- Recent senders and attachment types are prefetched once per page in `list_chats`, `find_chat`, `get_active_conversations`, and `get_unread`.
- Search bounds context windows per anchor, builds the link detector and preview regexes once, and produces one `ChatIdentity` per chat.

### Internals and DX

- `ChatIdentity` is the only chat display-name producer.
- `PendingRequestRegistry` and request parsing are extracted from `HTTPTransport`; `list_attachments` and `get_active_conversations` use `QueryBuilder`.
- Release workflow times out, checks the tag, asserts the version, and publishes the tarball sha256; actions are SHA-pinned with Dependabot; the Formula is part of the version check.
- Spike findings for a one-call catch-up sweep and send delivery semantics live under `docs/plans/`.

## 1.5.0

Breaking for the install base: the deployment floor is **macOS 15** (Homebrew `:sequoia`), Swift tools-version 6.3, and dependencies were bumped (hummingbird 2.26, swift-sdk 0.12.1, argument-parser 1.8.2).

### Fixes

- International numbers keep an explicit `+` country code instead of being rewritten to `+1`.
- Short numeric destinations that are not valid phone numbers fall through to contact-name lookup.
- `search` and `find_chat contains_recent` scan the rows they claim to search, including attributedBody-only text.
- `AsyncTimeout.sleep` resumes when cancellation precedes arming; the regression test now fails in 2s instead of hanging.
- Duplicate `chat_handle_join` handles no longer trap participant dictionaries; display names are deduped before disambiguation.
- Session cap holds under concurrency; `server.stop()` runs on terminate; staged attachments are removed on every exit.
- `unanswered_hours`, search/find_chat/get_messages limits, and AppleTime overflow are clamped instead of trapping.
- LIKE wildcards are escaped (including the constant link filter); diagnose no longer leaks the home directory.
- Contact search matches on word boundaries and rejects empty queries.
- Relative dates use a pinned locale and the current time zone.

### Performance

- find_chat, search `include_context`, get_unread, list_chats totals, and send-by-name last-contact lookups are batched.
- Tool JSON is encoded in one pass; image dimensions are checked before a full decode; osascript pipes drain after timeout.
- HTTP transport starts before Contacts enumeration.

### Internals and DX

- One `Log` helper for stderr; `make verify` distinguishes a down server from bad JSON; launchd plist is shipped.
- Shared `ChatIdentifier`, `ChatSummaryQueries`, `ToolErrorMapping`, `TimelineCursor`, and `UnansweredHeuristics`.
- `QueryBuilder.where` accepts an array of bindings.
- `--version` prints `iMessage Max <version>`; `scripts/check-version.sh` and `make release-check` keep the four version sites aligned.
- CI and release workflows target `macos-26`, current action majors, and an arm64-only release asset.
