# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project overview

iMessage Max is an MCP (Model Context Protocol) server for iMessage, built for AI assistants to call.

The goal is to cut tool calls per user intent from 3-5 down to 1-2. Tools are shaped around what someone wants to know, not around the database tables.

## Current implementation

The project is written in Swift and lives in `/swift/`. The old Python implementation is gone.

### Build, install, run

After making code changes, build and deploy with:

```bash
cd swift
make install    # builds, signs, restarts launchd service, verifies health
```

Always run `make install` after code changes. It signs the binary, which is what keeps Full Disk Access from being revoked on every rebuild.

Other Makefile targets:
- `make test` runs the full test suite
- `make status` checks process, version, signature, health
- `make logs` tails the stderr log
- `make clean` removes debug artifacts and clears logs
- `make setup-signing` is one-time setup for a persistent code signing identity

The server runs as a launchd service (`local.imessage-max`) on port 8080, configured at `~/Library/LaunchAgents/local.imessage-max.plist`. It auto-starts on login and auto-restarts on crash.

Connected via MCP Router as `remote-streamable` at `http://127.0.0.1:8080`. After restarting the service, MCP Router clients may need to reconnect (e.g. `/mcp` in Codex).

### Manual build and run (without Makefile)

```bash
cd swift
swift build -c release

# stdio mode (for Codex Desktop)
./.build/release/imessage-max

# HTTP mode (for MCP Router, Inspector, etc.)
./.build/release/imessage-max --http --port 8080
```

### Running the test suite

```bash
cd swift
swift test                              # full suite
swift test --filter HTTPTransportTests  # one test class
make test                               # same as `swift test`
```

`swift test --filter` takes a substring of the test class or method name, so
`--filter LaunchdSafetyTests` runs just that class and
`--filter testNoTaskSleepInServiceSources` runs the single case.

### Test via MCP protocol

```bash
# stdio mode
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | ./.build/release/imessage-max

# HTTP mode, legacy era (session-based)
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'

# HTTP mode, modern era (MCP 2026-07-28, stateless)
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "MCP-Protocol-Version: 2026-07-28" \
  -H "Mcp-Method: server/discover" \
  -d '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/clientInfo":{"name":"test","version":"1.0"}}}}'
```

## Architecture

### Swift Stack
- Language: Swift 6.1
- MCP SDK: modelcontextprotocol/swift-sdk (version pinned in `swift/Package.swift` / `swift/Package.resolved`)
- HTTP server: Hummingbird 2.x (for `--http` mode)
- Database: raw SQLite3 C API for `~/Library/Messages/chat.db`
- Contacts: CNContactStore
- Images: Core Image for GPU-accelerated resizing
- Send: AppleScript/JXA backend for Messages.app

### Directory structure

```
swift/
├── Sources/iMessageMax/
│   ├── main.swift              # Entry point
│   ├── Server/
│   │   ├── MCPServer.swift     # Server lifecycle (stdio)
│   │   ├── HTTPTransport.swift # HTTP Streamable transport (dual-era)
│   │   ├── ModernProtocol.swift # MCP 2026-07-28 stateless dispatcher
│   │   ├── DualEraStdioTransport.swift # stdio era router
│   │   ├── SessionManager.swift # Per-session Server instances (legacy)
│   │   ├── SSEConnection.swift # Server-Sent Events
│   │   ├── OriginValidationMiddleware.swift
│   │   └── ToolRegistry.swift  # Tool registration
│   ├── Database/               # SQLite wrapper, query builder
│   ├── Tools/                  # 12 MCP tools
│   ├── Contacts/               # CNContactStore resolver
│   ├── Enrichment/             # Image/video/audio processors
│   └── Utilities/              # Time, phone formatting
├── Tests/
└── Package.swift
```

### Protocol support (dual-era)

The server serves two MCP protocol eras concurrently on both transports
(stdio and HTTP), selected per request:

- Modern era (MCP 2026-07-28, stateless). `ModernDispatcher`
  (`ModernProtocol.swift`) answers requests that carry the reserved
  `_meta` key `io.modelcontextprotocol/protocolVersion`, plus
  `server/discover`, the modern probe method. No initialize, no sessions.
  Implemented at the repo level because no Swift SDK release targets
  2026-07-28 yet; the pinned swift-sdk still drives the legacy lane only.
- Legacy era (dated revisions through 2025-11-25, session-based).
  `initialize` and all session traffic pass to the SDK `Server` unchanged.
  This lane is load-bearing: plug (HTTP, `protocol = "legacy"`), the mcpb
  stdio bundle, and Codex all use it. Do not remove it without verified
  proof that every real client has migrated.

Era selection is body-driven only. Real legacy clients (plug) send
`Mcp-Method` and `MCP-Protocol-Version` headers on legacy session
traffic, so header presence must never route a request to the modern
lane. The regression test for this is
`testLegacyRequestWithModernHeadersStaysOnLegacyLane`.

Every request logs one era line to stderr
(`era=modern|legacy transport=... version=... method=...`) with no
arguments or credentials.

Not implemented, by design (rationale in
`plans/018-mcp-2026-07-28-dual-era.md`): prompts, resources, completion,
logging capability, subscriptions/listen, MRTR (input-required results),
requestState, Tasks, MCP Apps, OAuth (loopback-only posture), and
`x-mcp-header` tool annotations.

Conformance (official suite, both eras) runs with a documented
expected-failures baseline:

```bash
npx @modelcontextprotocol/conformance server --url http://127.0.0.1:8080 \
  --suite draft  --expected-failures docs/conformance-baseline.yml
npx @modelcontextprotocol/conformance server --url http://127.0.0.1:8080 \
  --suite active --expected-failures docs/conformance-baseline.yml
```

Rollback: the modern lane is additive. Reverting
`ModernProtocol.swift`, `DualEraStdioTransport.swift`, and the era branch
in `HTTPTransport.handlePost` / `MCPServer.start` restores the previous
legacy-only behavior byte-for-byte.

### HTTP transport architecture

The HTTP mode implements MCP Streamable HTTP transport (legacy sessions
per spec 2025-03-26+, modern stateless per 2026-07-28):

```
┌─────────────────────────────────────────────────────────┐
│  HTTPTransport (Hummingbird HTTP Server)                │
│  POST / → modern `_meta` body → ModernDispatcher        │
│  POST / → legacy JSON-RPC → SessionManager              │
│  GET /  → SSE streaming ← Server notifications (legacy) │
│  DELETE / → Session termination (legacy)                │
├─────────────────────────────────────────────────────────┤
│  SessionManager (per-session isolation)                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │
│  │ Session A   │  │ Session B   │  │ Session C   │     │
│  │ Server inst │  │ Server inst │  │ Server inst │     │
│  │ Message strm│  │ Message strm│  │ Message strm│     │
│  └─────────────┘  └─────────────┘  └─────────────┘     │
│  - 1 hour timeout with automatic cleanup                │
│  - Clean reconnection (no "already initialized" error)  │
└─────────────────────────────────────────────────────────┘
```

## Database schema (iMessage chat.db)

- `chat` holds conversation metadata (ROWID, guid, display_name)
- `message` holds individual messages (text, attributedBody, date, is_from_me)
- `handle` holds phone numbers and emails
- `attachment` holds media files (filename, mime_type, total_bytes)
- `chat_handle_join` links chats to handles
- `chat_message_join` links messages to chats
- `message_attachment_join` links messages to attachments

### Apple epoch time

iMessage uses nanoseconds since 2001-01-01:
```swift
let APPLE_EPOCH = Date(timeIntervalSinceReferenceDate: 0)
let date = Date(timeIntervalSinceReferenceDate: TimeInterval(appleTimestamp) / 1_000_000_000)
```

### attributedBody Format

Message text is often stored in `attributedBody` (binary typedstream format) instead of `text` column. Parse by:
1. Find "NSString" or "NSMutableString" marker
2. Skip 5 bytes after marker
3. Read length byte (0x81 = 2-byte length, 0x82 = 3-byte length, else single byte)
4. Read UTF-8 text of that length

## Twelve core tools

| Tool | Purpose |
|------|---------|
| `find_chat` | Locate chat by participants, name, or content |
| `get_chat_details` | Inspect a known chat's participants, handles, state, and recent shared summary |
| `get_messages` | Retrieve messages with flexible filtering |
| `get_context` | Get messages surrounding a specific message |
| `search` | Full-text search with compound filters |
| `list_chats` | Browse recent/active chats with previews |
| `send` | Send a message to person or group |
| `get_active_conversations` | Find chats with recent back-and-forth |
| `list_attachments` | Browse shared items grouped by message, with exact attachment ids for fetches |
| `get_unread` | Get unread messages or summary |
| `get_attachment` | Get image content with variant options (vision/thumb/full) |
| `diagnose` | Troubleshoot configuration and permissions |

## Critical implementation details

### No Task.sleep in the service runtime

Sleeping Swift tasks abort intermittently inside the launchd-run service
(`swift_task_dealloc` / "freed pointer was not the last allocation").
Use Dispatch timers instead: `AsyncTimeout.sleep` for tool code, or the
cancellable `DispatchSourceTimer` pattern in
`HTTPTransport.storePendingRequest` (not `asyncAfter`: a cancelled
asyncAfter work item stays enqueued until its deadline, which retained
every request's 300 s timeout timer under load — R0-02). This
crashed production on 2026-06-11 (send-confirmation timeout path); do not
reintroduce.

### Send contract (no confirmation gate)

The `send` tool is agent-native (plan 017):

- An exact destination sends immediately, then verifies against chat.db.
  Result is `confirmed`, `uncertain`, `mismatch`, `failed_delivery`,
  `partial_failure`, or `sent`.
- An ambiguous destination returns status `ambiguous` and sends nothing.
  Invalid input returns status `failed` and sends nothing.
- The `confirm` parameter is deprecated and inert: accepted for
  compatibility, ignored.
- File transfers keep the bounded Messages.app observation states
  (`pending_confirmation` while a transfer hasn't completed).

Interactive human-confirmation popups (MCP elicitation) and server-side send
gating are intentionally not part of the send path: authorization happens in
the user's conversation with the agent and in harness-level tool approval,
and a send tool must return synchronously. Do not reintroduce either without
operator sign-off and proof of a working elicitation round trip for the
current session.

### Image handling

Images are returned using MCP's native image content type (not base64 in JSON text) to avoid token bloat. Use the `.plainText`/`.plainImage` helpers defined in `Server/ServerExtensions.swift` (annotations-free wrappers over the SDK's content cases):
```swift
return [
    .plainText(try FormatUtils.encodeJSON(metadata)),
    .plainImage(data: base64String, mimeType: "image/jpeg")
]
```

### Attachment availability

Attachments can be offloaded to iCloud. `list_attachments` includes nested attachment summaries with `available: true/false` for each file. When `get_attachment` hits an offloaded file, the error says so and tells the caller to retry.

### Reaction type mapping

| `associated_message_type` | Reaction |
|---------------------------|----------|
| 2000 | Loved ❤️ |
| 2001 | Liked 👍 |
| 2002 | Disliked 👎 |
| 2003 | Laughed 😂 |
| 2004 | Emphasized ‼️ |
| 2005 | Questioned ❓ |
| 3000-3005 | Removal of above |

### Token-efficient response design

- Deduplicate participants (define once, reference by short key)
- Use ISO timestamps for messages, relative for summaries
- Short keys: `ts` not `timestamp`, `msgs` not `message_count`
- Reactions as compact strings: `["❤️ andrew", "😂 nick"]`
- Omit obvious fields (no `is_group: false` on 2-person chats)

## Required macOS permissions

- Full Disk Access, for ~/Library/Messages/chat.db
- Contacts, for AddressBook resolution
- Automation, for Messages.app (sending only)

## Maintainer notes

For current tradeoffs and "why we did it this way" context, see:

- `docs/maintainers/2026-04-09-maintainer-notes.md`

### Knowledge store

- `docs/solutions/` holds solved problems and design lessons with
  searchable YAML frontmatter. Search here before re-investigating an
  error or re-litigating a design decision, such as the send
  confirmation gate.
- `CONCEPTS.md` holds shared domain vocabulary: send statuses, verified
  send, the capability contract.
