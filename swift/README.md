# iMessage Max (Swift)

High-performance MCP server for iMessage, rewritten in Swift for native macOS integration.

## Features

- **12 MCP Tools** - find_chat, get_messages, list_chats, search, get_context, get_active_conversations, list_attachments, get_unread, send, get_attachment, diagnose, update
- **Native Performance** - Raw SQLite3 with Swift safety, Core Image GPU acceleration
- **Single Binary** - No Python/runtime dependencies
- **Dual Transport** - stdio (default) + Streamable HTTP

## Installation

### Homebrew (Recommended)

```bash
brew install yourusername/tap/imessage-max
```

### Manual Build

```bash
cd swift
swift build -c release
# Binary at .build/release/imessage-max
```

## Usage

### Claude Desktop Configuration

```json
{
  "mcpServers": {
    "imessage": {
      "command": "/opt/homebrew/bin/imessage-max"
    }
  }
}
```

### HTTP Mode

```bash
imessage-max --http --port 8080
```

## Requirements

- macOS 13+ (Ventura)
- Full Disk Access (for ~/Library/Messages/chat.db)
- Contacts permission (for name resolution)
- Automation permission for Messages.app (send functionality)

## License

MIT
