# Send Manual Validation

Use this checklist when you want a quick human check of the real send flows in
Messages.app before a release.

## Preconditions

- `Messages.app` is open, signed in, and responsive.
- The installed `imessage-max` binary has Automation permission for Messages.
- You have one known 1:1 chat and one known group chat available.
- Any file attachment used below exists locally and is readable.

## Core Checks

### 1. Send text to a 1:1 contact

Call:

```json
{
  "to": "+15555550123",
  "text": "iMessage Max manual validation: 1:1 text"
}
```

Expected:

- Result status is `sent`
- Message appears in the expected 1:1 conversation
- `delivered_to` names the intended person

### 2. Send text to an exact group chat

Call:

```json
{
  "chat_id": "chat456",
  "text": "iMessage Max manual validation: group text"
}
```

Expected:

- Result status is `sent`
- Message appears in the exact existing group thread
- No fallback to a different conversation

### 3. Send an attachment to a 1:1 contact

Call:

```json
{
  "to": "+15555550123",
  "file_paths": ["/absolute/path/to/test-image.png"]
}
```

Expected:

- Result status is `sent` or `pending_confirmation`
- Attachment appears in the expected 1:1 conversation

### 4. Send attachment plus text to an exact group chat

Call:

```json
{
  "chat_id": "chat456",
  "file_paths": ["/absolute/path/to/test-image.png"],
  "text": "iMessage Max manual validation: attachment then text"
}
```

Expected:

- Result status is `sent` or `pending_confirmation`
- Attachment arrives before the text bubble
- Conversation target stays exact

## Failure Checks

### 5. Missing attachment path

Call:

```json
{
  "chat_id": "chat456",
  "file_paths": ["/definitely/missing/file.png"]
}
```

Expected:

- Result status is `failed`
- Error clearly says the file could not be read
- No send attempt is made in Messages

### 6. Unsupported reply-to

Call:

```json
{
  "chat_id": "chat456",
  "text": "reply test",
  "reply_to": "msg_123"
}
```

Expected:

- Result status is `failed`
- Error clearly says `reply_to` is unsupported

## Attachment Spot Checks

### 7. Existing image attachment variants

Run `get_attachment` against a known local image attachment with:

- `variant: "thumb"`
- `variant: "vision"`
- `variant: "full"`

Expected:

- Each request succeeds
- Thumb is visibly smaller than vision/full
- Vision stays within the documented AI-friendly size

### 8. Offloaded attachment

Run `get_attachment` against an attachment that is no longer local.

Expected:

- Tool returns an `attachment_offloaded` error
- The message clearly explains the iCloud/download state
