# iMessage Max

An MCP (Model Context Protocol) server for iMessage that lets AI assistants read and search your messages with proper contact resolution.

## Features

- **Contact Resolution** - See names instead of phone numbers (resolves via macOS Contacts)
- **Participant Lookup** - Find chats by typing names like `find_chat(participants=["Nick", "Andrew"])`
- **Session Grouping** - Messages grouped into conversation sessions with gap detection
- **Token Efficient** - Designed for AI consumption with compact responses and pagination
- **Read-Only Safe** - Only reads from chat.db, never modifies your messages

## Why This Exists

Most iMessage tools expose raw database structures, requiring 3-5 tool calls per user intent. This MCP provides intent-aligned tools that work the way you'd naturally ask questions:

```
"What did Nick and I talk about yesterday?"
→ find_chat(participants=["Nick"]) + get_messages(since="yesterday")

"Show me recent group chats"
→ list_chats(is_group=True)

"Find where we discussed the trip"
→ search(query="trip")
```

## Installation

### Using UV (Recommended)

```bash
# Install UV if you haven't
curl -LsSf https://astral.sh/uv/install.sh | sh

# Install imessage-max
uv pip install git+https://github.com/robdezendorf/imessage-max.git
```

### Using pip

```bash
pip install git+https://github.com/robdezendorf/imessage-max.git
```

## Setup

### 1. Grant Permissions

The MCP needs two macOS permissions to work properly:

#### Full Disk Access (Required)
Allows reading `~/Library/Messages/chat.db`

1. Open **System Settings** → **Privacy & Security** → **Full Disk Access**
2. Click **+** and add your terminal app (Terminal.app, iTerm, Warp, etc.)
3. If using Claude Desktop, add the process that runs Python:
   - For UV: Add `/Users/YOU/.local/share/uv/python/` (or find it with `which python`)

#### Contacts Access (Required for name resolution)
Allows resolving phone numbers to contact names

1. Open **System Settings** → **Privacy & Security** → **Contacts**
2. Add the same apps/processes as above
3. **Important:** If using UV, you need to add UV itself (`~/.cargo/bin/uv` or similar)

### 2. Configure Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "imessage": {
      "command": "uvx",
      "args": ["--from", "git+https://github.com/robdezendorf/imessage-max.git", "imessage-max"]
    }
  }
}
```

Or if installed via pip:

```json
{
  "mcpServers": {
    "imessage": {
      "command": "imessage-max"
    }
  }
}
```

### 3. Restart Claude Desktop

The MCP will request Contacts access on first run if not already granted.

## Tools

### find_chat
Find chats by participants, name, or recent content.

```python
# Find a DM by contact name
find_chat(participants=["Nick"])

# Find a group chat with multiple people
find_chat(participants=["Nick", "Andrew"])

# Find a named group chat
find_chat(name="Family")

# Find chat where you discussed something recently
find_chat(contains_recent="dinner plans")
```

### get_messages
Retrieve messages with flexible filtering.

```python
# Get recent messages from a chat
get_messages(chat_id="chat123", limit=50)

# Get messages from the last 24 hours
get_messages(chat_id="chat123", since="24h")

# Get only messages from a specific person
get_messages(chat_id="chat123", from_person="Nick")

# Get messages containing specific text
get_messages(chat_id="chat123", contains="flight")
```

### list_chats
Browse recent chats with previews.

```python
# List recent chats
list_chats(limit=20)

# List only group chats
list_chats(is_group=True)

# List chats active in the last week
list_chats(since="7d")
```

### search
Full-text search across all messages.

```python
# Search all messages
search(query="dinner")

# Search messages from a specific person
search(query="dinner", from_person="Nick")

# Search with time bounds
search(query="meeting", since="2024-01-01", before="2024-02-01")

# Search only in group chats
search(query="party", is_group=True)
```

### get_context
Get messages surrounding a specific message.

```python
# Get context around a message
get_context(message_id="msg123", before=5, after=10)

# Find message containing text and get context
get_context(chat_id="chat123", contains="that link", before=3, after=5)
```

### get_active_conversations
Find chats with recent back-and-forth activity.

```python
# Find active conversations in the last 24 hours
get_active_conversations(hours=24)

# Find active group conversations
get_active_conversations(is_group=True, min_exchanges=3)
```

### list_attachments
List attachments with metadata.

```python
# List recent attachments
list_attachments(limit=20)

# List images from a specific chat
list_attachments(chat_id="chat123", type="image")

# List attachments from a specific person
list_attachments(from_person="Nick", type="any")
```

### get_unread
Get unread messages or summary.

```python
# Get all unread messages
get_unread()

# Get unread summary by chat
get_unread(format="summary")

# Get unread from specific chat
get_unread(chat_id="chat123")
```

### send
Send a message (requires Automation permission for Messages.app).

```python
# Send to a contact
send(to="Nick", text="Hey, are we still on for dinner?")

# Send to a group chat
send(chat_id="chat123", text="Running 5 minutes late")
```

### diagnose
Troubleshoot configuration and permission issues.

```python
# Check setup
diagnose()
# Returns: pyobjc_available, contacts_authorized, contacts_loaded count
```

## Troubleshooting

### Contacts showing as phone numbers

Run the `diagnose` tool to check status:

```json
{
  "pyobjc_available": true,
  "contacts_authorized": false,
  "authorization_status": "not_determined"
}
```

**Fix:** Add your Python interpreter or UV to System Settings → Privacy & Security → Contacts.

### "Database not found" error

The MCP can't access `~/Library/Messages/chat.db`.

**Fix:** Add your terminal/Python to System Settings → Privacy & Security → Full Disk Access.

### Empty message previews

Some messages store text in `attributedBody` instead of `text` column. This is handled automatically as of v0.1.0.

### MCP not loading in Claude Desktop

1. Check your config file syntax is valid JSON
2. Ensure the command path is correct
3. Restart Claude Desktop completely (Cmd+Q, not just close window)

## Development

```bash
# Clone the repo
git clone https://github.com/robdezendorf/imessage-max.git
cd imessage-max

# Create virtual environment and install
uv venv
uv pip install -e ".[dev]"

# Run tests
pytest
```

## License

MIT
