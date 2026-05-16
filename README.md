<p align="center">
  <img src="icon.png" alt="iMessage Max" width="128">
</p>

# iMessage Max

A high-performance MCP (Model Context Protocol) server for iMessage that lets AI agents read, search, and send your messages with proper contact resolution.

Built in Swift for native macOS integration - single binary, no runtime dependencies.

## Distribution Status

The project now ships a single Swift implementation:
- GitHub releases
- Homebrew
- source builds

The old Python package has been retired and removed from the repository.
Everything current lives under `swift/`.

## Features

- **11 Intent-Aligned Tools** - Work the way you naturally ask questions, not raw database queries
- **Contact Resolution** - See names instead of phone numbers via macOS Contacts
- **Smart Image Handling** - Efficient image variants (vision/thumb/full) to avoid token bloat
- **Session Grouping** - Messages grouped into conversation sessions with gap detection
- **Attachment Tracking** - Know which images are available locally vs offloaded to iCloud
- **Native Performance** - Swift with raw SQLite3, Core Image GPU acceleration
- **Read-Only Safe** - Only reads from chat.db, send requires explicit permission

## Why This Exists

Most iMessage tools expose raw database structures, requiring 3-5 tool calls per user intent. This MCP provides intent-aligned tools:

```
"What did Contact A and I talk about yesterday?"
→ find_chat(participants=["Contact A"]) + get_messages(since="yesterday")

"Show me the exact details for this thread before I reply"
→ get_chat_details(chat_id="chat123")

"Show me photos from the group chat"
→ list_attachments(chat_id="chat123", type="image")

"Find where we discussed the launch timeline"
→ search(query="launch timeline")
```

## Common Agent Workflows

The tools work best when an agent uses them as short workflows instead of isolated one-off calls.

Agents should treat `chat_id` values like `chat123` as internal handles for tool calls and exact sends. When explaining results to a person, use the returned chat name, group name, or participant-derived label instead of saying "Chat 123."

### Find the right conversation, then read it

```text
find_chat(participants=["Contact A"])
get_chat_details(chat_id="chat123")
get_messages(chat_id="chat123", since="yesterday", limit=50)
```

Use this when the person matters more than the exact thread id.

### Search first, then zoom in

```text
search(query="launch timeline", limit=10)
get_context(message_id="msg_456", before=5, after=10)
```

Use this when you know the topic but not where it was discussed.

### Check what needs attention

```text
get_unread()
get_active_conversations(hours=24, min_exchanges=2)
```

Use this to surface unread threads and active conversations after a broad chat-list sweep.

### Work with attachments safely

```text
list_attachments(chat_id="chat123", type="image", since="30d")
get_attachment(attachment_id="att123", variant="vision")
```

Use `list_attachments` to discover the message where files were shared first. It still returns exact attachment ids and local-availability state before you fetch a file.

### Send with exact targeting when it matters

```text
find_chat(participants=["Contact A", "Contact B"])
send(chat_id="chat456", text="Please use the latest draft")
```

For sensitive sends, prefer resolving the exact chat first and then using `chat_id` so the message lands in the intended thread.

## Installation

### Homebrew (Recommended)

```bash
brew tap cyberpapiii/tap
brew install imessage-max
```

### From Source

```bash
git clone https://github.com/cyberpapiii/imessage-max.git
cd imessage-max/swift
swift build -c release

# Binary is at .build/release/imessage-max
```

For local development, advanced setup, and the signed install workflow, see:

- [swift/README.md](swift/README.md)

## Setup

### 1. Grant Full Disk Access

Required to read `~/Library/Messages/chat.db`:

1. Open **System Settings** → **Privacy & Security** → **Full Disk Access**
2. Click **+** to add the binary

**For Homebrew installs:** The binary is at `/opt/homebrew/Cellar/imessage-max/VERSION/bin/imessage-max` (not the symlink at `/opt/homebrew/bin/`). Find it with:
```bash
# Open the folder containing the actual binary
open $(dirname $(readlink -f $(which imessage-max)))
```

**For source builds:** Add `.build/release/imessage-max` from your clone directory.

> **Tip:** In the file picker, press **⌘+Shift+G** and paste the path to navigate directly.

### 2. Grant Contacts Access

Required for resolving phone numbers to names. The app will request access on first run, or add manually:

**System Settings** → **Privacy & Security** → **Contacts** → add `imessage-max`

### 3. Configure Your MCP Client

Add `imessage-max` to your MCP client's server configuration.

Many MCP clients use a JSON structure like this:

**For Homebrew:**
```json
{
  "mcpServers": {
    "imessage": {
      "command": "/opt/homebrew/Cellar/imessage-max/VERSION/bin/imessage-max"
    }
  }
}
```

**For source builds:**
```json
{
  "mcpServers": {
    "imessage": {
      "command": "/path/to/imessage-max/swift/.build/release/imessage-max"
    }
  }
}
```

If your client uses a different config format, point it at the same binary path.

### 4. Reconnect Your MCP Client

After saving the config, reconnect or restart your MCP client. The server should appear in the available tools, and you can verify the connection with `diagnose`.

## Tools

### find_chat
Find chats by participants, name, or recent content.

```text
find_chat(participants=["Contact A"])              # Find a direct chat
find_chat(participants=["Contact A", "Contact B"]) # Find a group with both
find_chat(name="Project Group")                    # Find by chat name
find_chat(contains_recent="latest draft")          # Find by recent content
```

### get_chat_details
Inspect a known thread without opening the full conversation.

```text
get_chat_details(chat_id="chat123")                          # Participants, handles, state, last message
get_chat_details(chat_id="chat123", include_shared_summary=false) # Skip recent shared summary
```

### get_messages
Retrieve messages with flexible filtering. Returns metadata for media.

```text
get_messages(chat_id="chat123", limit=50)           # Recent messages
get_messages(chat_id="chat123", since="24h")        # Last 24 hours
get_messages(chat_id="chat123", from_person="Contact A")  # From specific person
```

### get_attachment
Retrieve image content by attachment ID with resolution variants.

```text
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

```text
list_chats(limit=20)          # Recent chats
list_chats(is_group=True)     # Only group chats
list_chats(since="7d")        # Active in last week
```

### search
Full-text search across messages.

```text
search(query="draft")                           # Search all messages
search(query="budget", from_person="Contact A") # From specific person
search(query="launch", is_group=True)           # Only in group chats
```

### get_context
Get messages surrounding a specific message.

```text
get_context(message_id="msg_123", before=5, after=10)
```

### get_active_conversations
Find chats with recent back-and-forth activity.

```text
get_active_conversations(hours=24)
get_active_conversations(is_group=True, min_exchanges=3)
```

### list_attachments
Browse shared items grouped by message. Each row includes exact attachment ids for follow-up fetches.

```text
list_attachments(type="image", since="7d")
list_attachments(chat_id="chat123", type="any")
```

### get_unread
Get unread threads or unread messages. Default is summary by chat.

```text
get_unread()                         # Summary by chat for last 7 days
get_unread(since="24h")              # Summary by chat for last 24 hours
get_unread(format="messages")        # Row-level unread messages
```

### send
Send a message or file attachment (requires Automation permission for Messages.app).

```text
send(to="Contact A", text="Checking in")
send(chat_id="chat123", text="Please use the latest draft")
send(chat_id="chat123", file_paths=["/path/save-the-date.jpg"])
send(to="Contact A", file_paths=["/path/reference.png"], text="Sharing the file here")
```

Rules:
- Exactly one of `to` or `chat_id`
- At least one of `text` or `file_paths`
- If both are provided, files are sent first and text is sent last

## Release Checks

For a lightweight pre-release routine, use:

- [docs/validation/2026-04-09-release-checklist.md](docs/validation/2026-04-09-release-checklist.md)
- [docs/validation/2026-03-13-send-manual-validation.md](docs/validation/2026-03-13-send-manual-validation.md)

Additional send note:
- `reply_to` is currently unsupported

Send result semantics:
- `status: "sent"` means the message or attachment was confirmed successfully
- `status: "pending_confirmation"` means Messages accepted an attachment send, but it was not confirmed as finished within the polling window
- `status: "failed"` means the send failed
- `status: "ambiguous"` means the target could not be resolved safely

Notes:
- `pending_confirmation` is a normal non-fatal attachment state, not the same as a hard failure
- exact chat sends target the existing conversation identified by `chat_id`

Examples:
- `{"status":"sent","success":true,...}` means delivery was confirmed within the polling window
- `{"status":"pending_confirmation","success":false,...}` means Messages accepted the attachment, but the MCP could not yet confirm final completion

### diagnose
Troubleshoot configuration and permission issues.

```text
diagnose()  # Returns: database status, contacts count, permissions, capabilities
```

## Troubleshooting

### Contacts showing as phone numbers

Run `diagnose` to check status. If `contacts_authorized` is false:
- Add the `imessage-max` binary to System Settings → Privacy & Security → Contacts

### "Database not found" error

Add the `imessage-max` binary to System Settings → Privacy & Security → Full Disk Access

### Images show "attachment_offloaded" error

Some attachments are stored in iCloud, not on disk. `list_attachments` includes nested attachment summaries with `available: true/false` for each file. To download offloaded attachments, open the conversation in Messages.app.

### MCP client not loading the server

1. Check config file syntax is valid JSON
2. Verify the binary path is correct
3. Reconnect or fully restart your MCP client

## Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  MCP Client /   │◄───►│  iMessage Max   │◄───►│  chat.db        │
│  Agent          │     │  (Swift MCP)    │     │  (SQLite)       │
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

## Advanced Setup

For HTTP mode, local background service setup, development commands, and
contributor-focused workflow details, see:

- [swift/README.md](swift/README.md)

## License

MIT
