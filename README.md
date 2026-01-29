<p align="center">
  <img src="icon.png" alt="iMessage Max" width="128">
</p>

# iMessage Max

A high-performance MCP (Model Context Protocol) server for iMessage that lets AI assistants read, search, and send your messages with proper contact resolution.

Built in Swift for native macOS integration - single binary, no runtime dependencies.

## Features

- **12 Intent-Aligned Tools** - Work the way you naturally ask questions, not raw database queries
- **Contact Resolution** - See names instead of phone numbers via macOS Contacts
- **Smart Image Handling** - Efficient image variants (vision/thumb/full) to avoid token bloat
- **Session Grouping** - Messages grouped into conversation sessions with gap detection
- **Attachment Tracking** - Know which images are available locally vs offloaded to iCloud
- **Native Performance** - Swift with raw SQLite3, Core Image GPU acceleration
- **Read-Only Safe** - Only reads from chat.db, send requires explicit permission

## Why This Exists

Most iMessage tools expose raw database structures, requiring 3-5 tool calls per user intent. This MCP provides intent-aligned tools:

```
"What did Nick and I talk about yesterday?"
→ find_chat(participants=["Nick"]) + get_messages(since="yesterday")

"Show me photos from the group chat"
→ list_attachments(chat_id="chat123", type="image")

"Find where we discussed the trip"
→ search(query="trip")
```

## Installation

### From Source (Recommended)

```bash
git clone https://github.com/cyberpapiii/imessage-max.git
cd imessage-max/swift
swift build -c release

# Binary is at .build/release/imessage-max
```

### Homebrew (Coming Soon)

```bash
brew install cyberpapiii/tap/imessage-max
```

## Setup

### 1. Grant Full Disk Access

Required to read `~/Library/Messages/chat.db`:

1. Open **System Settings** → **Privacy & Security** → **Full Disk Access**
2. Click **+** and navigate to the `imessage-max` binary
3. Press **⌘+Shift+G** and enter the path to the binary

### 2. Grant Contacts Access

Required for resolving phone numbers to names:

1. Run `imessage-max` once - it will request access automatically
2. Or manually add to **System Settings** → **Privacy & Security** → **Contacts**

### 3. Configure Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "imessage": {
      "command": "/path/to/imessage-max"
    }
  }
}
```

### 4. Restart Claude Desktop

The MCP should now appear in Claude's tools.

## Tools

### find_chat
Find chats by participants, name, or recent content.

```python
find_chat(participants=["Nick"])           # Find DM with Nick
find_chat(participants=["Nick", "Andrew"]) # Find group with both
find_chat(name="Family")                   # Find by chat name
find_chat(contains_recent="dinner plans")  # Find by recent content
```

### get_messages
Retrieve messages with flexible filtering. Returns metadata for media.

```python
get_messages(chat_id="chat123", limit=50)      # Recent messages
get_messages(chat_id="chat123", since="24h")   # Last 24 hours
get_messages(chat_id="chat123", from_person="Nick")  # From specific person
```

### get_attachment
Retrieve image content by attachment ID with resolution variants.

```python
get_attachment(attachment_id="att123")                 # Default: vision (1568px)
get_attachment(attachment_id="att123", variant="thumb") # Quick preview (400px)
get_attachment(attachment_id="att123", variant="full")  # Original resolution
```

| Variant | Resolution | Use Case | Token Cost |
|---------|------------|----------|------------|
| `vision` (default) | 1568px | AI analysis, OCR | ~1,600 tokens |
| `thumb` | 400px | Quick preview | ~200 tokens |
| `full` | Original | Maximum detail | Varies |

### list_chats
Browse recent chats with previews.

```python
list_chats(limit=20)          # Recent chats
list_chats(is_group=True)     # Only group chats
list_chats(since="7d")        # Active in last week
```

### search
Full-text search across messages.

```python
search(query="dinner")                    # Search all messages
search(query="meeting", from_person="Nick")  # From specific person
search(query="party", is_group=True)      # Only in group chats
```

### get_context
Get messages surrounding a specific message.

```python
get_context(message_id="msg_123", before=5, after=10)
```

### get_active_conversations
Find chats with recent back-and-forth activity.

```python
get_active_conversations(hours=24)
get_active_conversations(is_group=True, min_exchanges=3)
```

### list_attachments
List attachments with metadata. Includes `available` field showing if file is on disk.

```python
list_attachments(type="image", since="7d")
list_attachments(chat_id="chat123", type="any")
```

### get_unread
Get unread messages or summary.

```python
get_unread()                  # Unread from last 7 days
get_unread(since="24h")       # Last 24 hours
get_unread(mode="summary")    # Summary by chat
```

### send
Send a message (requires Automation permission for Messages.app).

```python
send(to="Nick", text="Hey!")
send(chat_id="chat123", text="Running late")
```

### diagnose
Troubleshoot configuration and permission issues.

```python
diagnose()  # Returns: database status, contacts count, permissions
```

## HTTP Mode

For integration with other tools:

```bash
imessage-max --http --port 8080
```

## Troubleshooting

### Contacts showing as phone numbers

Run `diagnose` to check status. If `contacts_authorized` is false:
- Add the `imessage-max` binary to System Settings → Privacy & Security → Contacts

### "Database not found" error

Add the `imessage-max` binary to System Settings → Privacy & Security → Full Disk Access

### Images show "attachment_offloaded" error

Some attachments are stored in iCloud, not on disk. The `list_attachments` tool shows `available: true/false` for each attachment. To download offloaded attachments, open the conversation in Messages.app.

### MCP not loading in Claude Desktop

1. Check config file syntax is valid JSON
2. Verify the binary path is correct
3. Restart Claude Desktop completely (Cmd+Q)

## Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Claude/AI      │◄───►│  iMessage Max   │◄───►│  chat.db        │
│  Assistant      │     │  (Swift MCP)    │     │  (SQLite)       │
└─────────────────┘     └────────┬────────┘     └─────────────────┘
                                │
                                ▼
                        ┌─────────────────┐
                        │  Contacts.app   │
                        │  (CNContactStore)│
                        └─────────────────┘
```

## Requirements

- macOS 13+ (Ventura or later)
- Full Disk Access permission
- Contacts permission (for name resolution)
- Automation permission for Messages.app (send only)

## Development

```bash
cd swift
swift build           # Debug build
swift build -c release  # Release build
swift test            # Run tests
```

## License

MIT
