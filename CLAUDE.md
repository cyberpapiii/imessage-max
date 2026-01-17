# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is **iMessage Max** - an MCP (Model Context Protocol) server for iMessage designed specifically for AI assistant consumption.

The core goal is to reduce tool calls per user intent from 3-5 down to 1-2 by providing intent-aligned tools rather than exposing raw database structures.

## Architecture

### Target Stack
- **Language:** Python with FastMCP framework
- **Database:** Read-only access to `~/Library/Messages/chat.db` (SQLite)
- **Contacts:** PyObjC integration with macOS AddressBook (CNContactStore)
- **Send:** AppleScript/JXA backend for Messages.app

### Key Data Sources
```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Claude/AI      │◄───►│  iMessage Max   │◄───►│  chat.db        │
│  Assistant      │     │  Server         │     │  (SQLite)       │
└─────────────────┘     └────────┬────────┘     └─────────────────┘
                                │
                                ▼
                        ┌─────────────────┐
                        │  AddressBook    │
                        │  (Contacts.app) │
                        └─────────────────┘
```

### Database Schema (iMessage chat.db)
- `chat` - conversation metadata (ROWID, guid, display_name)
- `message` - individual messages (text, date, is_from_me, associated_message_type for reactions)
- `handle` - phone numbers/emails
- `chat_handle_join` - links chats to handles
- `chat_message_join` - links messages to chats

### Apple Epoch Time
iMessage uses nanoseconds since 2001-01-01. Convert with:
```python
APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)
seconds = apple_timestamp / 1_000_000_000
dt = APPLE_EPOCH + timedelta(seconds=seconds)
```

## Nine Core Tools

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

## Critical Implementation Details

### macOS Tahoe Connection Management
macOS Tahoe (26.x) terminates Messages.app when external processes hold open connections. Use aggressive connection lifecycle:
```python
@contextmanager
def get_db_connection():
    conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)
    try:
        yield conn
    finally:
        conn.close()  # CRITICAL: Close immediately after each query
```

### Reaction Type Mapping
| `associated_message_type` | Reaction |
|---------------------------|----------|
| 2000 | Loved ❤️ |
| 2001 | Liked 👍 |
| 2002 | Disliked 👎 |
| 2003 | Laughed 😂 |
| 2004 | Emphasized ‼️ |
| 2005 | Questioned ❓ |
| 3000-3005 | Removal of above |

### Token-Efficient Response Design
- Deduplicate participants (define once, reference by short key)
- Use ISO timestamps for messages (AI temporal reasoning), relative for summaries
- Short keys: `ts` not `timestamp`, `msgs` not `message_count`
- Reactions as compact strings: `["❤️ andrew", "😂 nick"]`
- Omit obvious fields (no `is_group: false` on 2-person chats)

### Display Name Generation
When `display_name` is null, generate like Messages.app:
1. All in contacts: comma-separated names ("Nick, Andrew, Mike")
2. Some unknown: names + formatted numbers ("Nick, +1 (702) 555-1234")
3. More than 4: first 3 + "and N others"

## Required macOS Permissions
- Full Disk Access (for ~/Library/Messages/chat.db)
- Contacts access (for AddressBook resolution)
- Automation permission for Messages.app (send functionality)
