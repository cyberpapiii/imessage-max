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

## Verified-Send Proof Vocabulary (Plan 012)

These scenarios validate the `confirmed` / `uncertain` / `mismatch` status values
added in plan 012. Run against a real iMessage account with Full Disk Access granted.

### 9. Confirmed delivery to a known 1:1 contact

Call:

```json
{
  "to": "+15555550123",
  "text": "iMessage Max plan-012 confirm test"
}
```

Expected:

- `status` is `confirmed`
- `verified_message_guid` is a non-empty string (the DB GUID)
- `verified_at` is a recent ISO timestamp
- `chat.id` matches the known DM chat ID
- Message appears in the conversation on the device

### 10. Uncertain — send to address with no prior chat.db row

Call send to a valid handle where Messages.app accepts the command but the DB
polling window expires (for example, a brand-new iMessage address with no
previous DB rows). This is hard to reproduce reliably; alternatively, test with
a sandbox handle that reliably does NOT write a DB row.

Expected:

- `status` is `uncertain`
- `message` field contains "get_messages" hint
- No `verified_message_guid` or `verified_at` in the response
- The text appears in Messages.app even though status is uncertain

### 11. Mismatch — message lands in a different chat

This requires a contrived scenario where the AppleScript `send` routes the
message to a different thread than the one resolved by `to`. This is most
likely with a handle that appears in multiple group chats. Use the experiment
in the design doc (docs/plans/2026-06-11-send-verification-design.md §3) to
set up the condition.

Expected:

- `status` is `mismatch`
- `intended_chat` reflects the originally resolved chat
- `actual_chat_id` identifies the chat where the message actually landed
- `message` contains routing-mismatch language
- Agent should NOT treat this as a successful send

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
