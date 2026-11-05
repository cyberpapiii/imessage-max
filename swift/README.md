# iMessage Max

MCP server for iMessage, written in Swift and run natively on macOS.

This is the source of truth for the current project and its active
install/update workflow.

## Building

```bash
make build
# Binary: .build/release/imessage-max
```

`make build` passes `--build-system native`. Swift 6.4's default build
system writes the binary to `.build/out/Products/Release` instead, a path
the launchd service and its Full Disk Access grant do not use.

## Dev install workflow

Use the `Makefile` for normal development updates:

```bash
make setup-signing   # one-time: create persistent signing identity
make install         # build, sign, restart launchd service, verify health
```

Why it exists:
- the release binary path stays stable
- the binary is signed with a persistent local identity, so Full Disk Access
  survives rebuilds
- the launchd-managed HTTP service restarts automatically

Useful targets:

```bash
make status
make restart
make logs
make clean
```

The launchd label used by this workflow is `local.imessage-max`, and the
default HTTP port is `8080`.

## Requirements

- macOS 15+ (Sequoia or later)
- Xcode Command Line Tools or full Xcode

## Architecture

### Core components

The file-by-file map lives in the repository `AGENTS.md` (Directory structure), so it is kept in one place.

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

Implements MCP Streamable HTTP transport. Legacy sessions (specs through
2025-11-25) and the stateless 2026-07-28 era share one endpoint, with:

- Per-session Server instances, so each client gets isolated state and can
  reconnect cleanly
- Sessions time out after 1 hour and are cleaned up automatically
- Server-Sent Events carry server-to-client messages
- Origin validation blocks DNS rebinding; localhost only by default
- Request bodies must arrive within 30 seconds; a stalled upload gets HTTP 408 with a JSON-RPC error body, and connections idle for 60 seconds are closed
- JSON-shaped tools return both legacy text content and MCP `structuredContent`
- Latest-protocol initialize responses include PNG `serverInfo.icons`, and tools
  carry compact PNG icon metadata

```bash
./imessage-max --http --port 8080
```

Test with curl:
```bash
# Initialize session
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'

# Use session (include Mcp-Session-Id from response)
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: <session-id>" \
  -H "MCP-Protocol-Version: 2025-11-25" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
```

### CLI options

```
USAGE: imessage-max [--http] [--host <host>] [--port <port>] [--allow-external-bind]
                    [--contacts-policy <auto|request|skip>] [--request-contacts-access]

OPTIONS:
  --http                  Run with HTTP transport instead of stdio
  --host <host>           Host for HTTP transport (default: 127.0.0.1)
  --port <port>           Port for HTTP transport (default: 8080)
  --allow-external-bind   Allow a non-loopback host (exposes iMessage data to
                          the network; no authentication is provided)
  --contacts-policy <p>   When Contacts access is undetermined: auto (prompt
                          only from a terminal), request, or skip.
                          IMESSAGE_MAX_CONTACTS_POLICY=request|skip applies
                          when auto.
  --request-contacts-access
                          Ask macOS for Contacts access once, print the
                          status, and exit. Run it from a terminal.
  --version               Show the version
  -h, --help              Show help
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

Tools work best combined into short flows shaped around one question:

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

- One compiled binary, no interpreter to start
- Image resizing runs on the GPU through Core Image
- Ships self-contained for local installs and Homebrew

## License

MIT
