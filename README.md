<p align="center">
  <img src="icon.png" alt="iMessage Max" width="128">
</p>

# iMessage Max

For a Mac app to set it up and manage it, use the [native menu bar companion](macos/README.md). It checks setup, manages the local service, and copies the connection details your assistant needs.

iMessage Max is an MCP (Model Context Protocol) server for iMessage. AI agents use it to read, search, and send your messages. It resolves phone numbers to contact names.

It is written in Swift and ships as one Mac app with no runtime dependencies.

## Distribution

There is one Swift implementation, in `swift/`. It ships as:
- `iMessage Max.app` in a notarized DMG on GitHub releases (Apple silicon, macOS 15 or later)
- a Homebrew cask (`cyberpapiii/tap/imessage-max`) that installs the same app
- a Claude Desktop extension (`iMessage-Max-<version>.mcpb`) on GitHub releases
- source builds ([swift/README.md](swift/README.md))
- Codex plugin metadata (`.codex-plugin/`)
- Claude Desktop MCPB metadata (`mcpb/`)

## Features

- 13 tools, each shaped around a question people ask rather than around a database table
- Phone numbers resolve to names through macOS Contacts
- Three image variants: vision (1568px), thumb (400px), and full (original), so an agent can fetch a photo below full size
- A gap of 4 hours or more starts a new message session
- Attachment listings say whether each file is on disk or offloaded to iCloud
- Queries use raw SQLite3, and image resizing runs on the GPU through Core Image
- The server only reads chat.db. Sending needs Automation permission for Messages.app. You never have to open Messages: when the server needs it, it starts Messages hidden, with no window and no change of focus

## Why this exists

Most iMessage tools expose raw database structures, so one user request takes 3 to 5 tool calls. iMessage Max has tools that match what the user asks for:

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

## Common agent workflows

The tools work best when an agent chains them into short workflows instead of making isolated one-off calls.

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

Use this to find unread threads and active conversations after a broad sweep of the chat list.

### Work with attachments safely

```text
list_attachments(chat_id="chat123", type="image", since="30d")
get_attachment(attachment_id="att123", variant="vision")
```

Use `list_attachments` to find the message where files were shared. It returns exact attachment ids and says whether each file is on disk, so you know before you fetch.

### Send with exact targeting when it matters

```text
find_chat(participants=["Contact A", "Contact B"])
send(chat_id="chat456", text="Please use the latest draft")
```

For sensitive sends, prefer to resolve the exact chat first and then send with its `chat_id`. That way the message goes to the intended thread.

## Installation

Open the DMG from the [latest release](https://github.com/cyberpapiii/imessage-max/releases/latest) and drag iMessage Max to Applications.
Or run `brew install --cask cyberpapiii/tap/imessage-max`.

### Upgrading from 1.x

Version 1.x installed a Homebrew formula and a launch agent you set up by hand. The formula is retired. Run `brew uninstall imessage-max` first, because the cask links the same `imessage-max` command. Then install the app and open it. It offers **Replace the older helper**, which stops the old agent and removes its files. The new helper listens on port 47821 and needs a token, so reconnect each assistant from the app's Connections page.

## Protocol support

iMessage Max is a dual-era MCP server. Both transports, stdio and HTTP,
serve both eras at the same time. The server picks the era for each request:

| Era | Revisions | Lifecycle | Selected by |
| --- | --- | --- | --- |
| Modern | `2026-07-28` | Stateless, per-request `_meta` | `io.modelcontextprotocol/protocolVersion` in the request `_meta` (or `server/discover`) |
| Legacy | `2025-03-26` … `2025-11-25` | `initialize` + session | `initialize` request / `Mcp-Session-Id` |

Modern clients probe with `server/discover` and send the required
`MCP-Protocol-Version`, `Mcp-Method`, and (for `tools/call`) `Mcp-Name`
headers over HTTP. Legacy clients keep working without changes. No client
has to migrate, and legacy support stays as long as real clients depend
on it.

Stdio clients do not run the server themselves. `imessage-max` launched
with no transport flag is a bridge: it copies stdin and stdout to the running
helper (`imessage-max --http`) over the Unix socket
`~/Library/Application Support/iMessage Max/mcp.sock` (mode 0600), so only the
helper needs Full Disk Access, Contacts and Automation. Each bridge connection
is its own stdio session, serving both eras. When the helper is not running,
the bridge answers the first request with "Open iMessage Max to start it." and
exits. `imessage-max --direct` serves stdio in process, as before, for
development. If the home folder path is too long for a socket address, both
sides use `imessage-max.sock` in the per-user temporary folder instead.

The server implements only tools. By design, it has no prompts, resources,
completion, subscriptions, tasks, or MRTR flows. The official
conformance suite runs against both eras with the documented baseline in
`docs/conformance-baseline.yml`.

## Client icon metadata

iMessage Max ships icons for the MCP protocol itself and for each client
package format that carries its own metadata:

- MCP `2025-11-25` initialize responses include PNG `serverInfo.icons`.
- Each tool advertises a compact PNG tool icon.
- Codex plugin metadata lives in `.codex-plugin/plugin.json` and uses
  `assets/codex/icon.png` plus `assets/codex/logo.png`.
- Claude Desktop / MCPB metadata lives in `mcpb/manifest.json` and uses PNG
  assets under `mcpb/assets/`.

The source PNGs are committed under `assets/icons/` in these sizes: `16x16`,
`32x32`, `64x64`, `128x128`, `256x256`, and `512x512`.

## Setup

### 1. Open iMessage Max and grant its permissions

Open iMessage Max from Applications. It adds a speech bubble to the menu bar and opens its Settings window on Permissions, which lists four permissions with the status of each. The first one that is missing shows a button that grants it:

- Background activity, so the helper keeps serving your assistants after you close the window or quit the app, and starts again at login
- Full Disk Access, to read `~/Library/Messages/chat.db`
- Contacts, to turn phone numbers into names
- Automation for Messages, to send

System Settings lists each of them as "iMessage Max".

For contact names, choose Allow Contacts under Contacts. The app asks macOS for Contacts on the helper's behalf, because macOS charges the helper's grants to the app, and then restarts the helper. A bare `imessage-max` from a source build cannot hold a Contacts grant of its own. Under launchd or an MCP client it still reads messages, and shows phone numbers in place of names. `--contacts-policy request|skip`, or `IMESSAGE_MAX_CONTACTS_POLICY`, overrides its terminal detection.

### 2. Connect your assistant

Once every permission is on, the Permissions page offers to connect the assistant you use. The app's Connections page lists the assistants it finds on this Mac (Claude, Claude Code, Codex, Plug and Cursor) and connects each with one button. To set up another client by hand, use one of three ways to reach the helper:

- HTTP, for Plug, Codex and Claude Code: `http://127.0.0.1:47821`, with the header `Authorization: Bearer <token>`. The token is in `~/Library/Application Support/iMessage Max/token`.
- stdio, for any client that runs a command: `imessage-max`. The cask links that command. With the DMG, use `/Applications/iMessage Max.app/Contents/MacOS/imessage-max`. It is a bridge to the helper, so it needs no permissions of its own.
- Claude Desktop: open `iMessage-Max-<version>.mcpb` from the release.

```json
{
  "mcpServers": {
    "imessage": {
      "command": "imessage-max"
    }
  }
}
```

### 3. Reconnect your assistant

After you save the config, reconnect or restart your assistant. The tools then appear in it. Run `diagnose` to check the connection.

## Tools

### find_chat
Find chats by participants, name, or recent content.

By default, `find_chat` hides chats that Messages.app has filtered into Unknown Senders or Junk. The response carries `filtered_hidden`, the number of chats the filter removed from this view. Pass `include_filtered=True` to see them.

```text
find_chat(participants=["Contact A"])              # Find a direct chat
find_chat(participants=["Contact A", "Contact B"]) # Find a group with both
find_chat(name="Project Group")                    # Find by chat name
find_chat(contains_recent="latest draft")          # Find by recent content
find_chat(name="Project Group", include_filtered=True)  # Also search junk / unknown-sender chats
```

### get_chat_details
Inspect a known thread without opening the full conversation.

```text
get_chat_details(chat_id="chat123")                          # Participants, handles, state, last message
get_chat_details(chat_id="chat123", include_shared_summary=false) # Skip recent shared summary
```

### get_messages
Retrieve messages, filtered by time, sender, or content type. For media, it returns metadata. A lookup by explicit `chat_id` is never filtered.

```text
get_messages(chat_id="chat123", limit=50)           # Recent messages
get_messages(chat_id="chat123", since="24h")        # Last 24 hours
get_messages(chat_id="chat123", from_person="Contact A")  # From specific person
get_messages(chat_id="chat123", has="links")        # Messages that contain a URL
```

`has` filters by content type: `links`, `attachments`, or `images`. `links` also matches link messages that Messages stores as URL preview balloons, which is the common case on macOS 26.

Group system messages (renames, members added or removed, someone
leaving) come back with `text: null` and an `event` object:
`{"type": "rename", "title": "Trip"}`, `{"type": "participant_added", "participant": "Alice"}`,
`{"type": "participant_removed", ...}`, `{"type": "left"}`, or
`{"type": "other", "item_type": N}` for event kinds the server does not
name. Chat previews describe the same events in words
("renamed the group to Trip").

For reactions, replies, and edits, each message may include `reactions`
(`["❤️ alice"]` for standard tapbacks; custom emoji show the emoji
itself; sticker reactions use the token `🩵 sticker`), `reply_to`
(`msg_<rowid>` of the originator), `reply_count`, and `edited: true`.
Removed tapbacks are omitted. All four fields are optional and omitted
when empty. `search` and `get_context` carry the same four fields.
The server only reads these. It cannot send them, so `diagnose` still
reports `tapbacks` and `edit_unsend` as `unsupported`.

### get_messages_since
New messages across all chats after a ROWID cursor, in arrival order. Pass the returned `next_rowid` back as `since_rowid` to page or poll. `next_rowid` may be larger than the last returned message's rowid because consumed rows (reactions, filtered chats, orphans) advance it. Omit `since_rowid` to get only the current cursor. A cursor is valid only against this Mac's `chat.db`.

```text
get_messages_since()                          # Current cursor only
get_messages_since(since_rowid=234000)        # Messages after that row
get_messages_since(since_rowid=234000, limit=50)
get_messages_since(since_rowid=234000, chat_id="chat123")
get_messages_since(since_rowid=234000, include_filtered=True)
```

| Parameter | Type | Default | Meaning |
|-----------|------|---------|---------|
| `since_rowid` | integer | omitted | Exclusive ROWID cursor. Omit or pass `-1` for the current cursor only. |
| `chat_id` | string | omitted | Restrict to one chat (`chat123` or `123`) |
| `limit` | integer | 100 | Maximum messages to return (1–500) |
| `include_filtered` | boolean | false | Include junk / unknown-sender chats |
| `include_reactions` | boolean | true | Attach reaction strings to returned messages |

Example response:

```json
{
  "since_rowid": 234000,
  "messages": [
    {
      "id": "msg_234001",
      "rowid": 234001,
      "chat": {"id": "chat12", "name": "Alice Smith"},
      "from": "Alice Smith",
      "text": "on my way",
      "ts": "2026-09-02T15:00:00Z"
    },
    {
      "id": "msg_234010",
      "rowid": 234010,
      "chat": {"id": "chat40", "name": "Weekend"},
      "from": "me",
      "text": "see you there",
      "ts": "2026-09-02T15:01:00Z"
    }
  ],
  "next_rowid": 234050,
  "has_more": false,
  "current_rowid": 234050,
  "stalled": false,
  "filtered_hidden": 1
}
```

To poll, call once without `since_rowid` and store `next_rowid`. Then call with it on whatever schedule you choose. When `stalled` is true, wait about one second and retry with the same cursor. Never compare `next_rowid` to message ids.

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

By default, `list_chats` hides chats that Messages.app has filtered into Unknown Senders or Junk. The response carries `filtered_hidden`, the number of chats the filter removed. Pass `include_filtered=True` to see them.

```text
list_chats(limit=20)          # Recent chats
list_chats(is_group=True)     # Only group chats
list_chats(since="7d")        # Active in last week
list_chats(include_filtered=True)   # Also show junk / unknown-sender chats
```

### search
Full-text search across messages.

By default, `search` hides junk and unknown-sender chats. The response carries `filtered_hidden`. Pass `include_filtered=True` to search them too.

```text
search(query="draft")                           # Search all messages
search(query="budget", from_person="Contact A") # From specific person
search(query="launch", is_group=True)           # Only in group chats
search(query="draft", include_filtered=True)    # Also search junk / unknown-sender chats
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

`list_attachments` skips attachments that Messages hides with `hide_attachment`, such as link-preview payloads. `get_attachment` still returns them by id.

### get_unread
Get unread threads or unread messages. By default, it returns a summary by chat.

By default, `get_unread` hides junk and unknown-sender chats. The response carries `filtered_hidden`. Pass `include_filtered=True` to include them.

```text
get_unread()                         # Summary by chat for last 7 days
get_unread(since="24h")              # Summary by chat for last 24 hours
get_unread(format="messages")        # Row-level unread messages
get_unread(include_filtered=True)    # Also show junk / unknown-sender chats
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
- If you pass both, `send` sends the files first and the text last

Attachment paths must be absolute or start with `~/`. `send` checks the
path one component at a time and refuses it if any component is a symbolic
link. `/tmp`, `/var`, and `/etc` are allowed and read as `/private/...`.
`send` opens the file without following links, and the file must be a
regular file. `send` copies it from that open handle into a private `0700`
directory under `~/Pictures/imessage-max-staging/`. Messages only ever sees
the copy. If `~/Pictures` itself is a symlink on your Mac, `send` with a file
refuses to stage it until `~/Pictures` points at a real directory.

### diagnose
Troubleshoot configuration and permission issues.

```text
diagnose()  # Returns: database status, contacts count, permissions, capabilities
```

`capabilities.verified_send` is `supported` when chat.db is readable and Messages Automation is OK, `degraded` when the database is readable but Automation is not OK, and `permission-gated` when the database is not readable.

`database.features` lists which optional `chat.db` columns exist on this Mac, keyed `table.column` (for example `message.date_edited`). When one is `false`, the tools that read it degrade instead of failing: no `reply_to` or `reply_count` without `message.thread_originator_guid`, no `edited` without `message.date_edited`, no custom-emoji reaction text without `message.associated_message_emoji`.

`contacts.status` is one of `authorized`, `limited`, `denied`, `restricted`, `not_determined`, `not_requested_headless`, or `<status>_load_failed`. A headless process that skipped the prompt reports `not_requested_headless`.

Every `fix` for the helper inside `iMessage Max.app` names a permission in the app, such as "Open iMessage Max and turn on Full Disk Access." The permissions are Background activity, Full Disk Access, Contacts and Automation. For a bare executable, a fix names the System Settings switch to turn on. No fix names a terminal command.

`assistant_calls` counts the `tools/call` requests this helper process has received from clients other than the companion app. The app tells you once, the first time it is above zero.

## Release checks

Before a release, work through:

- [docs/RELEASING.md](docs/RELEASING.md), the release procedure
- [docs/validation/2026-04-09-release-checklist.md](docs/validation/2026-04-09-release-checklist.md), live spot checks
- [swift/Tests/iMessageMaxTests/SendManualValidation.md](swift/Tests/iMessageMaxTests/SendManualValidation.md), manual send checks in Messages.app

One more note on sends:
- When the destination is exact, `send` sends at once. There is no confirmation step. `send` refuses an ambiguous destination with `status: "ambiguous"`. The `confirm` parameter is deprecated and ignored, and it remains only for compatibility. The user authorizes a send in their conversation with the agent and in the client's tool-approval UI, not on the server.

After a text send, the server checks chat.db for the sent message. Each `status` means:
- `status: "confirmed"` means the server found the outbound row in chat.db within the verification window, with no error. `verified_message_guid` is the evidence. It is not a delivery receipt.
- `status: "uncertain"` means the transport accepted the send, but the server did not find the row within the polling window. Follow up with `get_messages`.
- `status: "mismatch"` means the message went to a different chat than intended. Do not treat it as success.
- `status: "failed_delivery"` means the server found the message row with a delivery error recorded. The message did not deliver, and `verified_message_guid` plus the error code are the evidence.
- `status: "partial_failure"` means a multi-payload send dispatched some payloads before a later one failed. `message` lists what was dispatched and what failed. Retry only the failed payload, never the whole call.
- `status: "sent"` means verification was unavailable because the database was unreadable. The only evidence is that the transport accepted the send.
- `status: "pending_confirmation"` means Messages accepted an attachment send, but the server could not confirm within the polling window that the file transfer finished.
- `status: "failed"` means the send failed.
- `status: "ambiguous"` means the server could not resolve the target safely: several contacts match, or the one matching contact's number or email has no conversation in Messages. `candidates` lists the matches, and nothing was sent.

#### Disposition and retry_safe

Every `send` response also carries `disposition` and `retry_safe`. `disposition` describes the transport, that is, whether the Apple event went out. `status` describes what chat.db shows.

| status | disposition | retry_safe |
|---|---|---|
| confirmed, uncertain, mismatch, sent | `completed` | `false` |
| failed_delivery | `completed` | `true` |
| pending_confirmation | `may_have_completed` | `false` |
| failed (transport) | from the send | `true` only when `not_started` |
| failed (validation / resolution) | `not_started` | `true` |
| partial_failure | failing payload's disposition | `false` |
| ambiguous | `not_started` | `true` |

```json
{"status":"failed","disposition":"not_started","retry_safe":true,"error":"Could not find chat 'iMessage;-;does-not-exist' in Messages.app."}
{"status":"failed","disposition":"may_have_completed","retry_safe":false,"error":"Send operation timed out. Messages.app may be unresponsive."}
```

Notes:
- `pending_confirmation` is a normal, non-fatal attachment state. It is not a hard failure.
- A send by `chat_id` goes to the existing conversation with that id.
- JSON-shaped tools return MCP `structuredContent` as well as legacy text content for older clients.

Examples:
- `{"status":"confirmed","verified_message_guid":"...",...}` means the outbound row was found in chat.db. It is not a delivery receipt.
- `{"status":"pending_confirmation","success":false,...}` means Messages accepted the attachment, but the server could not yet confirm that the transfer finished

## Troubleshooting

### Contacts showing as phone numbers

Run `diagnose` and read `contacts.status`. If it is `denied`, `not_determined` or `not_requested_headless`, open iMessage Max and turn on Contacts. If it is `denied`, also turn on iMessage Max in System Settings → Privacy & Security → Contacts. A bare `imessage-max` executable cannot hold a Contacts grant of its own, so use the helper inside the app. Names refresh within 30 seconds of a Contacts change. The server drops them as soon as access is revoked, and no restart is needed.

### "Cannot read the iMessage database" / `permission_denied`

Full Disk Access is missing for the **process that opens chat.db**. For
the helper inside `iMessage Max.app`, macOS charges the access to the app,
so turn on iMessage Max. For a bare `imessage-max` launchd service, that
process is the binary itself. Stdio clients reach the helper through the
bridge, so they need no grant of their own. Only `--direct` makes the app
that spawns the binary need it. Run `diagnose`. For the helper inside the
app, its `database.fix` field reads "Open iMessage Max and turn on Full
Disk Access." For a bare executable, it names the executable and steps 1 to 3:

1. System Settings → Privacy & Security → Full Disk Access → add that
   executable (or its launching app).
2. If it is already listed, toggle it off and on. A grant bound to an
   earlier code signature looks present but does not work. `make sign`
   uses the Developer ID in your keychain when one exists, which gives the
   binary a stable identity so rebuilds keep the grant. An ad-hoc build
   does not. The first build after moving from the old self-signed
   "iMessage Max Dev" identity to Developer ID needs this toggle once.
3. The grant applies only to newly launched processes. For the helper inside
   the app, open iMessage Max again: while Full Disk Access shows Not
   allowed, it restarts the helper and checks. For a bare service, run `cd swift && make restart`, which runs
   `launchctl kickstart -k`. A restart within 10 seconds of the last launch
   waits out launchd's throttle.
4. To narrow it down yourself, run `sqlite3 -readonly ~/Library/Messages/chat.db 'pragma quick_check;'` from a terminal.
   `ok` means your terminal has access and the server process does not.
   `unable to open database file` means the grant is missing for your user.

`make install` ends with `make verify-db`, which calls `diagnose` over
HTTP and fails if `database.accessible` is false. Run it on its own after
changing Full Disk Access:

    cd swift && make verify-db

### "Database not found" error

`~/Library/Messages/chat.db` does not exist. Sign in to iMessage and send or
receive one message.

### Images show "attachment_offloaded" error

Some attachments are stored in iCloud, not on disk. `list_attachments` includes nested attachment summaries with `available: true/false` for each file. To download offloaded attachments, open the conversation in Messages.app.

### MCP client not loading the server

1. Check that the config file is valid JSON
2. Check that the binary path is correct
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

- macOS 15+ (Sequoia or later) on Apple silicon
- Full Disk Access permission
- Contacts permission (for name resolution)
- Automation permission for Messages.app (send only)

## Advanced setup

For HTTP mode, the local background service, development commands, and the
contributor workflow, see the Swift README. Request bodies must arrive within
30 seconds. A stalled upload gets HTTP 408 with a JSON-RPC error body, and the
server closes connections that are idle for 60 seconds. See also:

- [swift/README.md](swift/README.md)

## License

MIT
