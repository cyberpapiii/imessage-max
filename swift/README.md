# iMessage Max

Native macOS MCP server for iMessage, built in Swift for optimal performance.

This is the source of truth for the current project and its active
install/update workflow.

## Building

```bash
swift build -c release
# Binary: .build/release/imessage-max
```

## Dev Install Workflow

Use the `Makefile` for normal development updates:

```bash
make setup-signing   # one-time: create persistent signing identity
make install         # build, sign, restart launchd service, verify health
```

This workflow exists to avoid the usual macOS development pain:
- the release binary path stays stable
- the binary is signed with a persistent local identity
- Full Disk Access can persist across rebuilds
- the launchd-managed HTTP service is restarted automatically

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

- macOS 13+ (Ventura)
- Xcode Command Line Tools or full Xcode

## Architecture

### Core Components

```
Sources/iMessageMax/
├── main.swift              # Entry point, CLI parsing
├── Server/
│   ├── MCPServer.swift     # Server lifecycle (stdio mode)
│   ├── HTTPTransport.swift # HTTP Streamable transport (MCP spec 2025-03-26)
│   ├── SessionManager.swift # Per-session Server instances
│   ├── SSEConnection.swift # Server-Sent Events streaming
│   ├── OriginValidationMiddleware.swift # DNS rebinding protection
│   └── ToolRegistry.swift  # Tool registration
├── Database/
│   ├── Database.swift      # SQLite wrapper
│   └── QueryBuilder.swift  # SQL construction
├── Tools/                  # 12 MCP tools
│   ├── FindChat.swift
│   ├── GetMessages.swift
│   ├── ListChats.swift
│   ├── Search.swift
│   ├── GetContext.swift
│   ├── GetActiveConversations.swift
│   ├── ListAttachments.swift
│   ├── GetUnread.swift
│   ├── Send.swift
│   ├── GetAttachment.swift
│   └── Diagnose.swift
├── Contacts/
│   └── ContactResolver.swift  # CNContactStore integration
├── Enrichment/
│   ├── ImageProcessor.swift   # Core Image resizing
│   ├── VideoProcessor.swift   # AVFoundation metadata
│   └── AudioProcessor.swift   # Audio duration extraction
└── Utilities/
    ├── AppleTime.swift        # Apple epoch conversion
    ├── PhoneUtils.swift       # Phone number formatting
    └── TimeUtils.swift        # ISO/relative time formatting
```

### Dependencies

- [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) - Protocol implementation
- [Swift Argument Parser](https://github.com/apple/swift-argument-parser) - CLI interface
- [Hummingbird](https://github.com/hummingbird-project/hummingbird) - HTTP server (for `--http` mode)

### Key Design Decisions

1. **Raw SQLite3** - Direct C API calls for maximum performance
2. **Core Image** - GPU-accelerated image resizing for attachment variants
3. **CNContactStore** - Native contact resolution through the macOS Contacts framework
4. **Typedstream Parsing** - Proper extraction of text from iMessage's `attributedBody` format
5. **MCP Image Content** - Images returned as proper MCP image type, not base64 in JSON

## Usage

### stdio Mode (Default)

```bash
./imessage-max
```

### HTTP Mode

Implements MCP Streamable HTTP transport (spec 2025-03-26) with:

- **Per-session Server instances** - Each client gets isolated state, enabling clean reconnection
- **Session management** - 1-hour timeout with automatic cleanup
- **SSE streaming** - Server-Sent Events for server→client messages
- **Origin validation** - DNS rebinding protection (localhost only by default)

```bash
./imessage-max --http --port 8080
```

Test with curl:
```bash
# Initialize session
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'

# Use session (include Mcp-Session-Id from response)
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -H "Mcp-Session-Id: <session-id>" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
```

### CLI Options

```
USAGE: imessage-max [--http] [--host <host>] [--port <port>] [--version]

OPTIONS:
  --http                  Run in HTTP mode instead of stdio
  --host <host>           HTTP host (default: 127.0.0.1 for security)
  --port <port>           HTTP port (default: 8080)
  --version               Show version
  -h, --help              Show help
```

## Testing

```bash
# Run unit tests
swift test

# Test MCP protocol manually
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | ./imessage-max
```

For real send-flow spot checks in Messages.app, use
`Tests/iMessageMaxTests/SendManualValidation.md`.

For a broader pre-release routine covering build, service health, permissions,
attachments, and live MCP checks, use:

- `../docs/validation/2026-04-09-release-checklist.md`
- `Tests/iMessageMaxTests/SendManualValidation.md`

## Recommended Tool Workflows

The server is most effective when tools are combined in short, intent-shaped flows:

Use `chat_id` values such as `chat123` as internal handles for follow-up tool calls and exact sends. In user-facing summaries, refer to conversations by returned chat names, group names, or participant-derived labels.

- Find a conversation, then read it:
  `find_chat(participants=["Contact A"])` → `get_messages(chat_id="chat123", since="24h")`
- Inspect a known thread before opening message history:
  `get_chat_details(chat_id="chat123")` → `get_messages(chat_id="chat123", since="24h")`
- Search broadly, then zoom in:
  `search(query="launch timeline")` → `get_context(message_id="msg_123", before=5, after=10)`
- Discover attachments before fetching them:
  `list_attachments(chat_id="chat123", type="image")` → `get_attachment(attachment_id="att123", variant="vision")`
- Resolve an exact target before sending:
  `find_chat(participants=["Contact A", "Contact B"])` → `send(chat_id="chat456", text="Please use the latest draft")`

## Performance

The current implementation is optimized for native macOS use:

- **Fast startup** from a single compiled binary
- **Low runtime overhead** without an interpreter layer
- **GPU-accelerated image processing** via Core Image
- **Self-contained distribution** for local installs and Homebrew

## License

MIT
