# iMessage Max

AI-optimized MCP server for iMessage on macOS. Read, search, and send messages.

<!-- mcp-name: io.github.cyberpapiii/imessage-max -->

## Installation

```bash
pip install imessage-max
```

Or with uv:

```bash
uvx imessage-max
```

## Configuration

Add to your Claude Desktop config (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "imessage": {
      "command": "uvx",
      "args": ["imessage-max"]
    }
  }
}
```

## Requirements

- macOS only (uses iMessage database)
- Full Disk Access permission (for `~/Library/Messages/chat.db`)
- Contacts access (for name resolution)
- Automation permission for Messages.app (for sending)

## Tools

| Tool | Purpose |
|------|---------|
| `find_chat` | Locate chat by participants, name, or content |
| `get_messages` | Retrieve messages with flexible filtering |
| `get_context` | Get messages surrounding a specific message |
| `search` | Full-text search with compound filters |
| `list_chats` | Browse recent/active chats with previews |
| `send` | Send a message to person or group |
| `get_active_conversations` | Find chats with recent back-and-forth |
| `list_attachments` | Retrieve attachments by type, person, chat |
| `get_unread` | Get unread messages or summary |

## Why iMessage Max?

Existing iMessage MCP servers expose raw database structures, requiring 3-5 tool calls per user intent. iMessage Max provides intent-aligned tools that reduce this to 1-2 calls, with:

- Smart contact resolution (names, nicknames, phone numbers)
- Conversation session boundaries
- Reaction aggregation
- Token-efficient responses

## License

MIT
