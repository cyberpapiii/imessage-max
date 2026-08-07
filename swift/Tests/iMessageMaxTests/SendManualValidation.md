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

## Verified-Send Proof Vocabulary

Run these against a real iMessage account with Full Disk Access granted. The
`send` tool can return `confirmed`, `uncertain`, `mismatch`, `failed_delivery`,
`partial_failure`, `sent`, `pending_confirmation`, `ambiguous`, or `failed`. The
checks in this section cover the five statuses that report what actually happened
after Messages.app accepted the send. `sent`, `pending_confirmation`, and
`failed` are exercised by the Core and Failure Checks above; `ambiguous` has no
manual check yet.

### 7. Confirmed delivery to a known 1:1 contact

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

### 8. Uncertain — send to address with no prior chat.db row

Call send to a valid handle where Messages.app accepts the command but the DB
polling window expires (for example, a brand-new iMessage address with no
previous DB rows). This is hard to reproduce reliably; alternatively, test with
a sandbox handle that reliably does NOT write a DB row.

Expected:

- `status` is `uncertain`
- `message` field contains "get_messages" hint
- No `verified_message_guid` or `verified_at` in the response
- The text appears in Messages.app even though status is uncertain

### 9. Mismatch — message lands in a different chat

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

### 10. Failed delivery — chat.db records a delivery error

Send to a handle that Messages.app will accept but cannot deliver to. The
reliable case is an iMessage-only send to a number with no iMessage
registration while SMS fallback is unavailable. Messages.app shows the red
"Not Delivered" badge and chat.db writes a non-zero `error` on the row.

Expected:

- `status` is `failed_delivery`
- `verified_message_guid` is a non-empty string — the row **was** found
- `message` states the message was NOT delivered and names the error code
- The agent must not report this as a successful send
- Messages.app shows the send as not delivered

### 11. Partial failure — multi-payload send fails partway

Call `send` with both `text` and `file_paths`, where the text will dispatch
fine and the attachment will not. For example, point `file_paths` at a file
that exists at validation time but is unreadable when the transfer starts, or
at an oversized file the transfer rejects.

Expected:

- `status` is `partial_failure`
- `message` begins `PARTIAL SEND:` and names which payload was dispatched and
  which failed
- `message` says explicitly not to resend the already-dispatched payload
- The text is visible in the conversation; the attachment is not
- Re-running the same call blind would duplicate the text — confirm the
  response makes that obvious

## Attachment Spot Checks

### 12. Existing image attachment variants

Run `get_attachment` against a known local image attachment with:

- `variant: "thumb"`
- `variant: "vision"`
- `variant: "full"`

Expected:

- Each request succeeds
- Thumb is visibly smaller than vision/full
- Vision stays within the documented AI-friendly size

### 13. Offloaded attachment

Run `get_attachment` against an attachment that is no longer local.

Expected:

- Tool returns an `attachment_offloaded` error
- The message clearly explains the iCloud/download state

### 14. Staged outgoing file is cleaned up

Outgoing attachments are copied into a per-send directory under
`~/Pictures/imessage-max-staging/` and the directory is removed once the
transfer completes. Check that it actually gets cleaned up:

1. Before the send, run `ls ~/Pictures/imessage-max-staging/ 2>/dev/null` and
   note what is there. An empty or missing directory is the normal state.
2. Send an attachment to a 1:1 contact and wait for the response.
3. After the response, run `ls ~/Pictures/imessage-max-staging/` again.

Expected:

- During the send, a UUID-named subdirectory exists containing a copy of the
  file under its original name
- After the send completes, that subdirectory is gone
- No accumulation across repeated sends — the directory count does not grow
- The original source file is untouched (the staging copy is a copy, never a
  move)

---

## Real-machine validation run — 2026-06-11

Performed against the production binary (commit `2f7f1f5`) over stdio MCP,
sending to the operator's own handle (`robdezendorf@gmail.com`, self-DM
chat ROWID 3813 — created by earlier latency probes).

| Check | Result |
|-------|--------|
| Resolution picks the true 1:1 DM (post `findDirectChatForHandle` fix) | PASS — `chat3813` resolved as intended chat |
| Full production send path (resolve → AppleScript → verify) | PASS — end-to-end through `tools/call send` |
| Verifier polls real chat.db | PASS |
| Failed delivery is NOT confirmed | PASS — iMessage refused self-delivery (row written with `error=22`, `is_sent=0`); verifier's `error = 0` gate excluded it; response was honest `uncertain` with `get_messages` guidance |
| `confirmed` happy path on a real delivery | PASS (same day, follow-up diagnostics) — two real deliveries confirmed end-to-end: chat-route send to the self-DM (`chat3813`) and participant-route send to the operator's phone alias; both rows landed with `error=0`, `is_sent=1` and the verifier returned `confirmed` with the exact `verified_message_guid` |

**Refined failure characterization (follow-up diagnostics, same day):** the
earlier `error=22` failures are specific to ONE combination — the AppleScript
*participant/buddy route* targeting the *same alias the account sends from*
(email→same email). The chat route to the same conversation succeeds, and the
participant route to a different self-alias (email→own phone number) succeeds.
Sends to other recipients were never affected (29k+ historical successful
sends from this alias). Practical note: a participant-route send to a handle
equal to the account's own sending alias will yield `uncertain` (error row
written); targeting the chat by `chat_id` instead delivers and confirms.

Follow-up identified: the verifier excludes `error != 0` rows entirely, so it
cannot distinguish "row never appeared" from "row appeared with a send error".
Detecting error rows in the window could yield a more precise state than
`uncertain` (e.g. surface the recorded send error). Tracked in
`plans/README.md` direction notes.
