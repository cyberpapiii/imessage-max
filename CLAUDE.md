# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**iMessage Max** is an MCP (Model Context Protocol) server for iMessage designed specifically for AI assistant consumption.

The core goal is to reduce tool calls per user intent from 3-5 down to 1-2 by providing intent-aligned tools rather than exposing raw database structures.

## Current Implementation

The project has been rewritten in **Swift** (located in `/swift/`) for native macOS integration. The Python version in the root directory is legacy.

### Build & Run

```bash
cd swift
swift build -c release
./.build/release/imessage-max
```

### Test via MCP Protocol

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | ./.build/release/imessage-max
```

## Architecture

### Swift Stack
- **Language:** Swift 6.0
- **MCP SDK:** modelcontextprotocol/swift-sdk v0.10.0
- **Database:** Raw SQLite3 C API for `~/Library/Messages/chat.db`
- **Contacts:** CNContactStore (native macOS)
- **Images:** Core Image for GPU-accelerated resizing
- **Send:** AppleScript/JXA backend for Messages.app

### Directory Structure

```
swift/
├── Sources/iMessageMax/
│   ├── main.swift              # Entry point
│   ├── Server/                 # MCP server lifecycle
│   ├── Database/               # SQLite wrapper, query builder
│   ├── Tools/                  # 12 MCP tools
│   ├── Contacts/               # CNContactStore resolver
│   ├── Enrichment/             # Image/video/audio processors
│   └── Utilities/              # Time, phone formatting
├── Tests/
└── Package.swift
```

## Database Schema (iMessage chat.db)

- `chat` - conversation metadata (ROWID, guid, display_name)
- `message` - individual messages (text, attributedBody, date, is_from_me)
- `handle` - phone numbers/emails
- `attachment` - media files (filename, mime_type, total_bytes)
- `chat_handle_join` - links chats to handles
- `chat_message_join` - links messages to chats
- `message_attachment_join` - links messages to attachments

### Apple Epoch Time

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

## Twelve Core Tools

| Tool | Purpose |
|------|---------|
| `find_chat` | Locate chat by participants, name, or content |
| `get_messages` | Retrieve messages with flexible filtering |
| `get_context` | Get messages surrounding a specific message |
| `search` | Full-text search with compound filters |
| `list_chats` | Browse recent/active chats with previews |
| `send` | Send a message to person or group |
| `get_active_conversations` | Find chats with recent back-and-forth |
| `list_attachments` | List attachments by type, person, chat (includes `available` field) |
| `get_unread` | Get unread messages or summary |
| `get_attachment` | Get image content with variant options (vision/thumb/full) |
| `update` | Mark messages as read |
| `diagnose` | Troubleshoot configuration and permissions |

## Critical Implementation Details

### Image Handling

Images are returned using MCP's native image content type (not base64 in JSON text) to avoid token bloat:
```swift
return [
    .text("photo.jpg (800x600, 45KB)"),
    .image(data: base64String, mimeType: "image/jpeg", metadata: nil)
]
```

### Attachment Availability

Attachments can be offloaded to iCloud. `list_attachments` includes `available: true/false` field. When `get_attachment` encounters an offloaded file, it returns a helpful error message.

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
- Use ISO timestamps for messages, relative for summaries
- Short keys: `ts` not `timestamp`, `msgs` not `message_count`
- Reactions as compact strings: `["❤️ andrew", "😂 nick"]`
- Omit obvious fields (no `is_group: false` on 2-person chats)

## Required macOS Permissions

- **Full Disk Access** - for ~/Library/Messages/chat.db
- **Contacts** - for AddressBook resolution
- **Automation** - for Messages.app (send functionality only)
