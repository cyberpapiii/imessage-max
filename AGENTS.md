# AGENTS.md

This file is guidance for coding agents (Claude Code, Codex) and contributors.

## Project overview

iMessage Max is an MCP (Model Context Protocol) server for iMessage, built for AI assistants to call.

The goal is to cut tool calls per user intent from 3-5 down to 1-2. Tools are shaped around what someone wants to know, not around the database tables. The tool list and what each tool is for are in `README.md`.

The project is written in Swift and lives in `/swift/`.

## Build, install, run

```bash
cd swift
make install    # builds the app, installs it, registers the helper, verifies health
```

`make install` replaces the live service that every MCP client uses through plug. Run it when a change needs to reach that service, for example to check behaviour on real data. Code-only work verified by tests does not need it. Before installing, copy the current `iMessage Max.app` to a scratch folder so you can put it back.

It builds `dist/iMessage Max.app` with `script/assemble_app.sh`, removes the installed `iMessage Max.app` and copies the new bundle to the same place (never copy over a running signed binary: macOS kills the process). That place is `/Applications` when the DMG or the cask put a copy there, so one bundle owns the helper label, and `~/Applications` otherwise. Then it opens the app with `--register-helper`. That flag registers the helper with `SMAppService`, restarts a running one on the new binary, and replaces a pre-2.0 install. The helper runs from `Contents/MacOS/imessage-max` inside the app, under the agent plist `macos/Resources/LaunchAgents/com.cyberpapiii.imessage-max.helper.plist`, which the app bundles in `Contents/Library/LaunchAgents/`. macOS charges an in-bundle helper's Full Disk Access, Contacts and Automation to the app, so each Privacy list shows one "iMessage Max". Do not hand-write a plist into `~/Library/LaunchAgents`.

A live check that must not disturb the installed helper builds a test variant: `APP_NAME`, `APP_BUNDLE_ID`, `HELPER_LABEL`, `HELPER_PORT`, `HELPER_SOCKET` and `HELPER_TOKEN_FILE` override the app name, bundle id, label, port, socket path and token file in `script/assemble_app.sh`. The socket's and token's folders must already exist with mode 0700. Launch a test variant with `--client-root <folder>` to connect clients against fixture configs in that folder, never your own. A test variant never touches a pre-2.0 install. Remove it with `open "<app>" --args --unregister-helper`, then delete the app.

The binaries are signed with hardened runtime and the entitlements in `swift/iMessageMax.entitlements`, the app and the helper alike. The identity comes from `script/signing_identity.sh`: `SIGN_IDENTITY` (a certificate SHA-1) when set, otherwise the valid "Developer ID Application" identity in the keychain that expires last. A stable Developer ID signature keeps macOS from revoking Full Disk Access on every rebuild. A contributor without a Developer ID gets an ad-hoc signature and a printed warning, and must grant Full Disk Access again after each build. `make sign` builds and signs without touching the service.

Other Makefile targets:
- `make test` runs the full test suite (`FILTER=ClassOrMethod` for a subset)
- `make status` checks process, version, signature, health
- `make app` builds and signs `dist/iMessage Max.app` without installing it
- `make logs` tails the helper log, `~/Library/Logs/iMessage Max/imessage-max.log`. launchd cannot expand `~`, so the plist passes `--log-file` and the server opens the file itself
- `make restart` runs `launchctl kickstart -k` on the helper. A kickstart within the plist's 10 second `ThrottleInterval` of the last launch waits out the rest of it. The plist's `KeepAlive` has `SuccessfulExit` false, so launchd relaunches the helper after any exit but a zero one, a crash included, after the `ThrottleInterval`. On SIGTERM (`launchctl kill`, Activity Monitor) the helper drains, then exits 75 (`KeepRunning.relaunchExitCode`) so launchd starts it again, or exits 0 so it stays down when the companion's Keep running setting is off. That setting is the `stay-stopped` file beside the token (`ServiceDefaults.stayStoppedFileName`), so a helper with `--token-file` reads it from that file's folder. The helper reads it as it stops, so a change needs no restart. The companion stops the helper with `launchctl bootout`, which unloads the job whatever the setting says, until the next login or until it starts it again by registering.
- `make clean` removes debug artifacts and clears the helper log
- `make version` checks that the version sites agree, and `make release-check` runs everything that must pass before tagging (see `docs/RELEASING.md`)

The server runs as the launchd agent `com.cyberpapiii.imessage-max.helper`. The default port is 47821, and the bundled agent plist can pin another with `--port`. It starts at login and restarts after a crash. While Keep running is on (the default) it also restarts after a plain quit. Stop in the companion keeps it down until the next login. System Settings → General → Login Items & Extensions lists it once, as iMessage Max, under "App Background Activity".

Every HTTP request needs `Authorization: Bearer <token>`, on every route and both eras. On first start the server writes a random token to `~/Library/Application Support/iMessage Max/token` (mode 0600, folder 0700) and reuses it after that. It refuses to start if the file is readable by other users, owned by someone else, or holds anything but a token, and it never overwrites that file. `--token-file <path>` points a dev or test server at another file, in a folder that already exists and belongs to you; the server leaves that folder's mode alone. A missing or wrong token gets 401 and one `auth=rejected` stderr line, which never holds the token. Stdio needs no token.

Clients reach it through plug (HTTP, `protocol = "legacy"`, with the token as `auth_token`). After restarting the service, clients may need to reconnect (for example with `/mcp` in Codex).

`make build` passes `--build-system native` so the binary stays at `.build/arm64-apple-macosx/release/imessage-max`, which `.build/release` links to. `script/assemble_app.sh` copies `swift/.build/release/imessage-max` into the app. Swift 6.4's default build system writes elsewhere.

### Manual build and run (without Makefile)

```bash
cd swift
make build   # a bare `swift build` omits the embedded Info.plist, so Contacts can never be granted
BIN=.build/arm64-apple-macosx/release/imessage-max

# stdio bridge (what Codex and Claude Desktop launch): copies stdio to the
# running helper's socket and reads no Messages data itself
$BIN

# stdio served in this process, for development; needs its own Full Disk Access
$BIN --direct

# HTTP mode (for plug, Inspector, etc.), with a scratch token and socket so it
# does not share the installed service's port, token or socket
mkdir -m 700 -p /tmp/imax-dev
$BIN --http --port 18484 --token-file /tmp/imax-dev/token --socket-path /tmp/imax-dev/mcp.sock
$BIN --socket-path /tmp/imax-dev/mcp.sock   # a bridge to that helper
```

A bare executable cannot hold a Contacts grant of its own. It never prompts when it runs headless, and System Settings cannot add an executable to Contacts by hand. Started from a terminal, it asks, and macOS records the grant for the terminal app, so the grant covers only processes that terminal starts. Work that needs contact names under launchd or an MCP client runs through the helper inside the app (`make install`).

## Running the test suite

```bash
cd swift
CI=true swift test                                      # full suite
CI=true swift test --filter 'iMessageMaxTests.HTTPTransportTests/'   # one class
CI=true make test FILTER=HTTPTransportTests             # via the Makefile
```

Set `CI=true` when running tests from an agent shell. Without it, some tests take a path meant for an interactive machine.

`--filter` matches a substring of the test class or method name, so `--filter testNoTaskSleepInServiceSources` runs a single case.

From an agent shell, xctest can hang forever in a cfprefsd XPC wait (`_CFPreferencesCopyAppValueWithContainerAndConfiguration`) as soon as a test touches ImageIO or `CNContactStore`. The fault is intermittent and comes from the environment, not the code. One hung class blocks the whole run with no output, and the machine has no `timeout` binary. If a full run stalls, check with `sample <xctest pid> 1`. Then run each class alone under a 90 s watchdog (`swift test --skip-build --filter 'iMessageMaxTests.<Class>/'`) and report any class that hung as unverified, not as passing.

A test that copies a WAL-mode SQLite fixture must run `PRAGMA journal_mode=DELETE;` on it first, or copy its `-wal` and `-shm` files too. `Database` opens `mode=ro`, and a WAL file without its `-shm` fails to open with an error that looks like an unreadable database.

The wire contract shared with the companion app has its own tests: `cd contract && swift test`.

### Test via MCP protocol

The HTTP examples pass the token to curl on stdin (`-K -`), because other users can read a process's arguments with `ps`.

```bash
# stdio mode, in process
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | ./.build/release/imessage-max --direct

# HTTP mode, legacy era (session-based)
printf 'header = "Authorization: Bearer %s"\n' "$(cat ~/Library/Application\ Support/iMessage\ Max/token)" |
curl -K - -X POST http://localhost:47821 \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'

# HTTP mode, modern era (MCP 2026-07-28, stateless)
printf 'header = "Authorization: Bearer %s"\n' "$(cat ~/Library/Application\ Support/iMessage\ Max/token)" |
curl -K - -X POST http://localhost:47821 \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "MCP-Protocol-Version: 2026-07-28" \
  -H "Mcp-Method: server/discover" \
  -d '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/clientInfo":{"name":"test","version":"1.0"}}}}'
```

## Architecture

Swift (tools-version 6.3; builds with the 6.4 toolchain), the modelcontextprotocol/swift-sdk (pinned in `swift/Package.resolved`), Hummingbird 2.x for `--http`, the raw SQLite3 C API against `~/Library/Messages/chat.db`, CNContactStore, Core Image, and AppleScript/JXA for sending.

### Where things live

- `contract/` holds the wire types shared with the companion app: diagnose and setup types, capability keys, status words, defaults (host, port, launchd label), CLI flags and the protocol version. Edit a wire word here, not in either app.
- `macos/` is the companion menu bar app.
- `swift/Sources/iMessageMax/Server/Version.swift` is the source of truth for the version and the server instructions.
- `swift/Sources/iMessageMax/Database/` holds each chat.db rule once: `SQLFragments` for the SQL rules, `ChatScope` for which chats are hidden, `ChatLookup` for resolving a chat id. Reuse them instead of writing the rule again in a tool.
- `swift/Sources/iMessageMax/Tools/` has one file per MCP tool.
- `swift/Sources/iMessageMax/Utilities/ChatPage.swift` builds the chat summaries that several tools return.

### Protocol support (dual-era)

The server serves two MCP protocol eras concurrently on both transports
(stdio and HTTP), selected per request:

- Modern era (MCP 2026-07-28, stateless). `ModernDispatcher`
  (`ModernProtocol.swift`) answers requests that carry the reserved
  `_meta` key `io.modelcontextprotocol/protocolVersion`, plus
  `server/discover`, the modern probe method. This era has no initialize
  and no sessions. The repo implements it itself because no Swift SDK
  release targets 2026-07-28 yet. The pinned swift-sdk still drives only
  the legacy lane.
- Legacy era (dated revisions through 2025-11-25, session-based).
  `initialize` and all session traffic pass to the SDK `Server` unchanged.
  Plug (HTTP, `protocol = "legacy"`), the mcpb stdio bundle and Codex
  all use this lane. Do not remove it without verified proof that every
  real client has migrated.

Only the request body selects the era (`JSONRPCMessage.era`, the one
rule both transports use). Real legacy clients (plug) send
`Mcp-Method` and `MCP-Protocol-Version` headers on legacy session
traffic, so header presence must never route a request to the modern
lane. The regression test for this is
`testLegacyRequestWithModernHeadersStaysOnLegacyLane`.

Every request except a legacy `tools/call` logs one era line to stderr
(`era=modern|legacy transport=... version=... method=...`). Every
`tools/call`, on any lane, logs one call line when it ends
(`call tool=... lane=legacy-http|legacy-stdio|modern-http|modern-stdio
outcome=ok|tool_error|internal_error|cancelled|unknown_tool ms=...`,
plus `session=` on legacy HTTP). Neither carries arguments or
credentials. Every stderr line starts with an ISO 8601 UTC timestamp,
and startup logs a `Started version=... pid=... transport=...` line.

These features are not implemented, by design (rationale in
`plans/018-mcp-2026-07-28-dual-era.md`): prompts, resources, completion,
logging capability, subscriptions/listen, MRTR (input-required results),
requestState, Tasks, MCP Apps, OAuth (loopback-only posture), and
`x-mcp-header` tool annotations.

The official conformance suite (@0.2.0-alpha.11) runs against both eras with a
documented expected-failures baseline. The suite is pinned to that alpha tag because it tracks the 2026-07-28 draft the modern lane implements; npm `latest` (0.1.16) does not.

The suite has no option for request headers, so `scripts/conformance-auth.mjs` adds the token to each request it makes to the `--url` host (or `IMESSAGE_MAX_URL`), and to no other host. Run it against a scratch server, not the installed service:

```bash
mkdir -m 700 -p /tmp/imax-conf
swift/.build/arm64-apple-macosx/release/imessage-max --http --port 18484 --token-file /tmp/imax-conf/token &
export NODE_OPTIONS="--import $PWD/scripts/conformance-auth.mjs" IMESSAGE_MAX_TOKEN_FILE=/tmp/imax-conf/token
npx @modelcontextprotocol/conformance@0.2.0-alpha.11 server --url http://127.0.0.1:18484 \
  --suite draft  --expected-failures docs/conformance-baseline.yml
npx @modelcontextprotocol/conformance@0.2.0-alpha.11 server --url http://127.0.0.1:18484 \
  --suite active --expected-failures docs/conformance-baseline.yml
```

To roll back the modern lane, route every message to the legacy lane in
`HTTPTransport.handlePost` and `DualEraStdio.start`, and drop
`ModernProtocol.swift`. The lane is additive, but it is no longer a few
self-contained files. The shared JSON-RPC and startup code stays.

## Critical implementation details

### No Task.sleep in the service runtime

Sleeping Swift tasks abort intermittently inside the launchd-run service
(`swift_task_dealloc` / "freed pointer was not the last allocation").
Use Dispatch timers instead. Use `AsyncTimeout.sleep` in tool code, or
the cancellable `DispatchSourceTimer` pattern in
`PendingRequestRegistry.store`. Do not use `asyncAfter` for a timer that
can be cancelled. A cancelled asyncAfter work item stays enqueued until
its deadline, and under load it retains each request's timeout timer. `Task.sleep` crashed production on
2026-06-11 in the send-confirmation timeout path. Do not reintroduce it.
The rule covers library code you configure into a sleep too. ServiceGroup's
`maximumGracefulShutdownDuration` made every release-build SIGTERM abort
(#27), so `HTTPTransport` bounds the drain with its own Dispatch timer.
`LaunchdSafetyTests` enforces this rule, and `SignalShutdownTests` checks
that a spawned server exits plainly on SIGTERM, with 0 or the Keep running
code as the setting says.

### Send contract (no confirmation gate)

The `send` tool is agent-native (plan 017):

- An exact destination sends immediately, then verifies against chat.db.
  The result is `confirmed`, `uncertain`, `mismatch`, `failed_delivery`,
  `partial_failure`, or `sent`.
- An ambiguous destination returns status `ambiguous` and sends nothing.
  Invalid input returns status `failed` and sends nothing.
- The `confirm` parameter is deprecated and has no effect. The server
  accepts it for compatibility and ignores it.
- File transfers keep the bounded Messages.app observation states
  (`pending_confirmation` while a transfer hasn't completed).

The send path deliberately has no interactive human-confirmation popups (MCP
elicitation) and no server-side send gating. Authorization happens in the
user's conversation with the agent and in harness-level tool approval, and a
send tool must return synchronously. Do not reintroduce either without
operator sign-off and proof of a working elicitation round trip for the
current session.

The full status vocabulary that agents read is the `send` tool description in
`Send/SendTool.swift`. `CONCEPTS.md` defines the terms.

### Image handling

Tools return images as MCP's native image content type, not as base64 in JSON text, to keep token counts down. Use the `.plainText`/`.plainImage` helpers defined in `Server/ServerExtensions.swift` (annotations-free wrappers over the SDK's content cases):
```swift
return [
    .plainText(try FormatUtils.encodeJSON(metadata)),
    .plainImage(data: base64String, mimeType: "image/jpeg")
]
```

### Token-efficient response design

- Deduplicate participants (define once, reference by short key)
- Use ISO timestamps for messages, relative for summaries
- Short keys where they are unambiguous (`ts` not `timestamp`)
- Reactions as compact strings: `["❤️ andrew", "😂 nick"]`
- Omit obvious fields (no `is_group: false` on 2-person chats)

## Required macOS permissions

macOS charges the helper's grants to `iMessage Max.app`, so the app is where a user grants them. Every `diagnose` fix for the helper inside the app names a permission in the app by its System Settings name, such as "Open iMessage Max and turn on Full Disk Access.", and never a terminal command. The titles live in `contract/Sources/IMessageMaxContract/SetupStep.swift`, which both the server and the companion read. A bare executable (`--direct`, or a build run outside the app) gets fixes that name the System Settings switch, and no fix names `make`, `swift build` or Terminal.

- Background activity, so launchd runs the helper (the app's Login Items registration)
- Full Disk Access, for ~/Library/Messages/chat.db
- Contacts, for AddressBook resolution. The companion asks in its own process and then restarts the helper, which reads Contacts access only at launch. A helper inside an app that asks for itself is denied with no prompt. A bare executable cannot hold a Contacts grant of its own (see the build section above). A bare `swift build` also omits the embedded Info.plist, and diagnose then reports `missing_usage_description`
- Automation, for Messages.app, sending only. The helper's own request shows a prompt that names the app

## Maintainer notes

For current tradeoffs and "why we did it this way" context, see
`docs/maintainers/2026-04-09-maintainer-notes.md`.

### Knowledge store

- `docs/solutions/` holds solved problems and design lessons with
  searchable YAML frontmatter. Search here before re-investigating an
  error or re-litigating a design decision, such as the send
  confirmation gate.
- `CONCEPTS.md` holds shared domain vocabulary: send statuses, verified
  send, the capability contract.
