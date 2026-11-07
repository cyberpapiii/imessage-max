# iMessage Max

An MCP server for iMessage, written in Swift. It runs natively on macOS.

This directory is the source of truth for the server and its developer
workflow. People install the released app from the DMG or with
`brew install --cask cyberpapiii/tap/imessage-max`. `docs/RELEASING.md`
covers how a release reaches them.

## Building

```bash
make build
# Binary: .build/release/imessage-max
```

`make build` passes `--build-system native`. Swift 6.4's default build
system writes the binary to `.build/out/Products/Release` instead, a path
`script/assemble_app.sh` does not copy into the app.

## Dev install workflow

Use the `Makefile` for normal development updates:

```bash
make install         # build the app, install it, register the helper, verify health
```

`make install` replaces the released app in `/Applications` when one is
there, so the Mac never holds two copies that claim the same helper.
Otherwise it installs to `~/Applications`. `brew upgrade` later replaces a
build installed over the cask's copy.

The workflow exists so that:
- the helper runs from inside `iMessage Max.app` under
  `SMAppService`, so macOS charges Full Disk Access, Contacts and Automation
  to the app, and each Privacy list shows one "iMessage Max"
- the app and the helper are signed with the Developer ID in your keychain,
  with hardened runtime and `iMessageMax.entitlements`, so grants survive
  rebuilds. Set `SIGN_IDENTITY` to a certificate SHA-1 to pick one. With no
  Developer ID the build signs ad hoc, prints a warning, and Full Disk Access
  must be granted again after each build
- the running helper restarts on the new binary

Other targets:

```bash
make status
make restart
make logs
make clean
```

The helper's launchd label is `com.cyberpapiii.imessage-max.helper`, its
log is `~/Library/Logs/iMessage Max/imessage-max.log`, and the default HTTP
port is `47821`. Opening the app with `--register-helper` replaces a pre-2.0
install.

## Requirements

- macOS 15+ (Sequoia or later) on Apple silicon
- Xcode Command Line Tools or full Xcode

## Architecture

### Core components

The directory map is in the repository's `AGENTS.md`, under "Where things live", so it stays in one place.

### Dependencies

- [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) for the protocol
- [Swift Argument Parser](https://github.com/apple/swift-argument-parser) for the CLI
- [Hummingbird](https://github.com/hummingbird-project/hummingbird) for the HTTP server in `--http` mode

### Key design decisions

1. Raw SQLite3, called through the C API, with no ORM in between
2. Core Image for GPU-accelerated image resizing across attachment variants
3. CNContactStore for contact resolution through the macOS Contacts framework
4. A typedstream parser, because most message text lives in `attributedBody`
   rather than the `text` column
5. Images returned as the MCP image content type, not base64 inside JSON

## Usage

### stdio mode (default)

```bash
./imessage-max
```

### HTTP mode

HTTP mode implements the MCP Streamable HTTP transport. Legacy sessions, for
spec revisions through 2025-11-25, and the stateless 2026-07-28 era share one
endpoint. In HTTP mode:

- Each session gets its own Server instance, so each client has isolated state
  and can reconnect cleanly.
- Sessions time out after 1 hour, and the server then removes them.
- Server-Sent Events carry server-to-client messages.
- Every request needs `Authorization: Bearer <token>`. The server creates the token on first start in
  `~/Library/Application Support/iMessage Max/token` (mode 0600) and reuses it after that.
  `--token-file <path>` reads or creates another file in a folder you own. The server never
  overwrites a file that holds anything but a token; it exits instead. A missing or wrong token
  gets HTTP 401.
- Origin validation blocks DNS rebinding. By default, only localhost is allowed.
- Request bodies must arrive within 30 seconds. A stalled upload gets HTTP 408 with a JSON-RPC error body, and the server closes connections that are idle for 60 seconds.
- JSON-shaped tools return both legacy text content and MCP `structuredContent`.
- Latest-protocol initialize responses include PNG `serverInfo.icons`, and tools
  carry compact PNG icon metadata.

```bash
./imessage-max --http
```

Test with curl:
```bash
# Initialize session
printf 'header = "Authorization: Bearer %s"\n' "$(cat ~/Library/Application\ Support/iMessage\ Max/token)" |
curl -K - -X POST http://localhost:47821 \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'

# Use session (include Mcp-Session-Id from response)
printf 'header = "Authorization: Bearer %s"\n' "$(cat ~/Library/Application\ Support/iMessage\ Max/token)" |
curl -K - -X POST http://localhost:47821 \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: <session-id>" \
  -H "MCP-Protocol-Version: 2025-11-25" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
```

### CLI options

```
USAGE: imessage-max [--http] [--host <host>] [--port <port>] [--allow-external-bind] [--token-file <token-file>] [--contacts-policy <contacts-policy>] [--log-file <log-file>] [--request-contacts-access] [--request-messages-access]

OPTIONS:
  --http                  Run with HTTP transport instead of stdio
  --host <host>           Host for HTTP transport (default: 127.0.0.1)
  --port <port>           Port for HTTP transport (default: 47821)
  --allow-external-bind   Allow binding the HTTP transport to a non-loopback
                          host (this exposes iMessage data and the access token
                          to the network over unencrypted HTTP)
  --token-file <token-file>
                          File holding the bearer token HTTP clients must send.
                          Created with mode 0600 if absent; its folder must
                          already exist and belong to you. An existing file
                          that holds anything but a token is left alone and the
                          server exits. Defaults to ~/Library/Application
                          Support/iMessage Max/token.
  --contacts-policy <contacts-policy>
                          What to do when Contacts authorization is not yet
                          determined: auto (prompt only if stdin is a
                          terminal), request, or skip. With auto, the server
                          honours IMESSAGE_MAX_CONTACTS_POLICY=request|skip.
                          (values: auto, request, skip; default: auto)
  --log-file <log-file>   Append diagnostics to this file instead of stderr. A
                          leading ~/ means the home directory, because launchd
                          does not expand it.
  --request-contacts-access
                          Ask macOS for Contacts access once, print the
                          resulting status, and exit. Run this from a terminal;
                          the server never prompts when it has no terminal.
  --request-messages-access
                          Ask macOS for Automation access to Messages once,
                          without sending a message, print the resulting
                          status, and exit.
  --version               Show the version.
  -h, --help              Show help information.
```

## Testing

```bash
# Run unit tests
make test

# Test MCP protocol manually
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | ./imessage-max
```

For real send-flow spot checks in Messages.app, use
`Tests/iMessageMaxTests/SendManualValidation.md`.

For a broader pre-release routine covering build, service health, permissions,
attachments, and live MCP checks, use:

- `../docs/validation/2026-04-09-release-checklist.md`
- `Tests/iMessageMaxTests/SendManualValidation.md`

## Recommended tool workflows

The tools work best in short flows, each built around one question.

Use `chat_id` values such as `chat123` as internal handles for follow-up tool calls and exact sends. In user-facing summaries, refer to conversations by returned chat names, group names, or participant-derived labels.

- Find a conversation, then read it:
  `find_chat(participants=["Contact A"])`, then `get_messages(chat_id="chat123", since="24h")`
- Inspect a known thread before opening message history:
  `get_chat_details(chat_id="chat123")`, then `get_messages(chat_id="chat123", since="24h")`
- Search broadly, then zoom in:
  `search(query="launch timeline")`, then `get_context(message_id="msg_123", before=5, after=10)`
- Discover attachments before fetching them:
  `list_attachments(chat_id="chat123", type="image")`, then `get_attachment(attachment_id="att123", variant="vision")`
- Resolve an exact target before sending:
  `find_chat(participants=["Contact A", "Contact B"])`, then `send(chat_id="chat456", text="Please use the latest draft")`

## Performance

- The server is one compiled binary, so there is no interpreter to start
- Image resizing runs on the GPU through Core Image
- The helper is self-contained inside the app bundle

## License

MIT
