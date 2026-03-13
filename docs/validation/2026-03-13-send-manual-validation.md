# Send Manual Validation

This document records the intended manual validation flow for the public send
surface in `iMessage Max`. The goal is to validate the supported core feature
set without relying on private APIs or UI scripting.

## Preconditions

- `Messages.app` is signed in and responsive.
- The `imessage-max` binary has Automation permission for Messages.
- The operator has at least one existing 1:1 chat and one existing group chat.
- Any attachment paths used below exist locally and are readable.

## Scenarios

### 1. Participant Text Send

Call:

```json
{
  "to": "+15555550123",
  "text": "iMessage Max test: participant text send"
}
```

Expected:

- MCP returns `status: "sent"`
- Message lands in the expected 1:1 thread
- `delivered_to` contains the resolved participant display name

### 2. Exact DM Chat Text Send

Call:

```json
{
  "chat_id": "chat123",
  "text": "iMessage Max test: exact DM chat send"
}
```

Expected:

- MCP returns `status: "sent"`
- Message lands in the exact thread referenced by `chat_id`
- No DM fallback to a different conversation

### 3. Exact Group Chat Text Send

Call:

```json
{
  "chat_id": "chat456",
  "text": "iMessage Max test: exact group chat send"
}
```

Expected:

- MCP returns `status: "sent"`
- Message lands in the exact existing group thread
- No participant fallback to a 1:1 conversation

### 4. Participant File Send

Call:

```json
{
  "to": "+15555550123",
  "file_paths": ["/absolute/path/to/test-image.png"]
}
```

Expected:

- MCP returns either `status: "sent"` or `status: "pending_confirmation"`
- Attachment lands in the expected 1:1 thread

### 5. Exact Group Chat File Send

Call:

```json
{
  "chat_id": "chat456",
  "file_paths": ["/absolute/path/to/test-image.png"]
}
```

Expected:

- MCP returns either `status: "sent"` or `status: "pending_confirmation"`
- Attachment lands in the exact existing group thread

### 6. File Then Text Ordering

Call:

```json
{
  "chat_id": "chat456",
  "file_paths": ["/absolute/path/to/test-image.png"],
  "text": "iMessage Max test: file then text"
}
```

Expected:

- MCP returns `status: "sent"` if both payloads are confirmed
- MCP returns `status: "pending_confirmation"` if attachment confirmation remains pending
- Attachment is sent before the text bubble
- Thread target remains exact

### 7. Missing File

Call:

```json
{
  "chat_id": "chat456",
  "file_paths": ["/definitely/missing/file.png"]
}
```

Expected:

- MCP returns `status: "failed"`
- Error clearly indicates file validation failure
- No Messages send attempt occurs

### 8. Unsupported Reply

Call:

```json
{
  "chat_id": "chat456",
  "text": "reply test",
  "reply_to": "msg_123"
}
```

Expected:

- MCP returns `status: "failed"`
- Error clearly states that `reply_to` is unsupported

## Notes

- Conversation presentation is intentionally first-person:
  - chat labels show the other people in the thread
  - `me` appears in message history for outbound messages
  - the current visible participant list does not include self
- The resolver should preserve that UX model while still using exact `chat_id`
  targeting for sends.
