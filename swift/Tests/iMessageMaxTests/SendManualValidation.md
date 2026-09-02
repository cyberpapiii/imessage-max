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

<!-- Section 6 removed with plan 075; reply_to is no longer a send parameter. -->

## Verified-Send Proof Vocabulary

Run these against a real iMessage account with Full Disk Access granted. The
`send` tool can return `confirmed`, `uncertain`, `mismatch`, `failed_delivery`,
`partial_failure`, `sent`, `pending_confirmation`, `ambiguous`, or `failed`. The
checks in this section cover the five statuses that report what actually happened
after Messages.app accepted the send. `sent`, `pending_confirmation`, and
`failed` are exercised by the Core and Failure Checks above, and `ambiguous` by
check 15.

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

### 8. Uncertain: send to address with no prior chat.db row

Call send to a valid handle where Messages.app accepts the command but the DB
polling window expires (for example, a brand-new iMessage address with no
previous DB rows). This is hard to reproduce reliably; alternatively, test with
a sandbox handle that reliably does NOT write a DB row.

Expected:

- `status` is `uncertain`
- `message` field contains "get_messages" hint
- No `verified_message_guid` or `verified_at` in the response
- The text appears in Messages.app even though status is uncertain

### 9. Mismatch: message lands in a different chat

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

### 10. Failed delivery: chat.db records a delivery error

Send to a handle that Messages.app will accept but cannot deliver to. chat.db
writes a non-zero `error` on the row and the verifier reports the failure
instead of confirming it.

The reproduction that needs no one else: send text to the account's own
sending alias by the participant route, meaning `to` is the same email the
account sends from. iMessage refuses self-delivery and writes an `error=22`
row immediately. Verified on 2026-08-07. An iMessage-only send to a number
with no iMessage registration, with SMS fallback unavailable, is the other
case, but it puts a message in a stranger's hands if the number turns out to
be reachable. Prefer the self-alias route.

Expected:

- `status` is `failed_delivery`
- `verified_message_guid` is a non-empty string, so the row was found
- `message` states the message was NOT delivered and names the error code
- The agent must not report this as a successful send
- Messages.app shows the send as not delivered

### 11. Partial failure: multi-payload send fails partway

`partial_failure` needs an earlier payload to dispatch and a later one to hard
fail. Files go before text, so the combination to aim for is two files where
the first succeeds and the second fails. A bad file in a single-file call is
caught by validation before anything dispatches and returns `failed`.

Both paths are validated up front and each file is staged at its own dispatch,
so the second file has to break after the call starts. What worked on
2026-08-07: send two readable files, then delete the second one about half a
second in, while the first is still transferring.

Expected:

- `status` is `partial_failure`
- `message` begins `PARTIAL SEND:` and names which payload was dispatched and
  which failed
- `message` says explicitly not to resend the already-dispatched payload
- The text is visible in the conversation; the attachment is not
- Re-running the same call blind would duplicate the text. Confirm the
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
- No accumulation across repeated sends. The directory count does not grow
- The original source file is untouched (the staging copy is a copy, never a
  move)

## Resolution Checks

### 15. Ambiguous destination is refused before sending

Nothing is sent in this check. The resolver refuses ahead of the send.

`to` must be a name. A phone number or email resolves directly and can never
be ambiguous.

`ContactResolver.searchByName` does a case-insensitive substring match over
the full display name and returns one row per handle, so the count that
matters is handles, not people. A single contact with a phone number and two
email addresses is already ambiguous on its own. A shared surname is the
easiest way to guarantee the condition.

Before running this, confirm the name you picked really does match more than
one handle. A name that matches exactly one handle sends the text for real.

Call:

```json
{
  "to": "<a surname several of your contacts share>",
  "text": "iMessage Max manual validation: ambiguous destination"
}
```

Expected:

- The MCP call comes back as a tool error, not a normal result. The JSON below
  is the error payload
- `status` is `ambiguous`
- `message` is "Multiple contacts match. Please specify using a phone number,
  email, or chat_id."
- `candidates` lists every matching handle, each with `name`, `handle`, and
  `last_contact`
- The same person appears once per handle, under the same `name`
- Candidates are ordered by most recent contact first. A handle you have never
  messaged shows `last_contact` of `never` and sorts last
- No `chat`, `chat_id`, or `delivered_to` in the response
- Nothing appears in any Messages conversation. Confirm this on the device
- Repeating the call with one candidate's `handle` as `to` sends normally

---

## Real-machine validation run, 2026-08-07

Ran checks 10, 11, 14, and 15 against the installed v1.4.0 binary over the
stdio MCP server, all targeting the operator's own handles. Every previously
unrun check now has a result.

| Check | Result |
|-------|--------|
| 15, ambiguous destination | PASS. `to` set to a surname eleven contacts share returned `status: "ambiguous"` with all eleven handles, ordered most recent first, the four never-messaged handles last with `last_contact: "never"`. Nothing was sent |
| 10, failed delivery | PASS. Text to the account's own sending alias returned `status: "failed_delivery"` naming error 22, with a `verified_message_guid`, so the row was found rather than missed |
| 11, partial failure | PASS. Two files with the second deleted mid-call returned `status: "partial_failure"`, naming the dispatched file and the failed one, and saying not to resend the dispatched one |
| 14, staged file cleanup | PASS. A sampler watching `~/Pictures/imessage-max-staging/` caught a UUID directory holding the file under its original name, gone by the time the call returned. Two sends left nothing behind, and the source files were untouched |

Cleanup also runs on the failure path: a chat-route send that failed in
AppleScript staged its directory and removed it anyway.

The first chat-route send of the session failed with AppleScript error -1728,
`can't get chat id "any;-;<handle>"`. The same call succeeded later in the
session, and an `osascript` probe resolved that exact chat id without error,
so this is a cold-start condition in Messages.app rather than a property of
`any;-;` chats. Every chat in this database carries an `any;-;` GUID and
chat-route sends work against them. The service-qualified form
(`iMessage;-;<handle>`) is what AppleScript rejects. If a chat-route send
fails on the first call after a quiet period, retry before concluding the
chat is unreachable.

That failure did surface a real bug, now fixed. AppleScript writes the
typographic apostrophe in its errors, so `can’t get chat` never matched the
straight-form `can't get chat` test in the stderr classifier. Every one of
those errors fell through to the raw-stderr branch, and the client got
`186:202: execution error: ...` instead of "Could not find chat ... in
Messages.app." The classifier now normalizes the apostrophe first, and
`AppleScriptRunnerValidationTests` covers both forms.

---

## Real-machine validation run, 2026-06-11

Performed against the production binary (commit `2f7f1f5`) over stdio MCP,
sending to the operator's own handle (`robdezendorf@gmail.com`, self-DM
chat ROWID 3813, created by earlier latency probes).

| Check | Result |
|-------|--------|
| Resolution picks the true 1:1 DM (post `findDirectChatForHandle` fix) | PASS. `chat3813` resolved as intended chat |
| Full production send path (resolve, AppleScript, verify) | PASS, end to end through `tools/call send` |
| Verifier polls real chat.db | PASS |
| Failed delivery is NOT confirmed | PASS. iMessage refused self-delivery, writing a row with `error=22`, `is_sent=0`. The verifier's `error = 0` gate excluded it and the response was an honest `uncertain` with `get_messages` guidance |
| `confirmed` happy path on a real delivery | PASS (same day, follow-up diagnostics). Two real deliveries confirmed end to end: a chat-route send to the self-DM (`chat3813`) and a participant-route send to the operator's phone alias. Both rows landed with `error=0`, `is_sent=1`, and the verifier returned `confirmed` with the exact `verified_message_guid` |

**Refined failure characterization (follow-up diagnostics, same day):** the
earlier `error=22` failures are specific to ONE combination: the AppleScript
*participant/buddy route* targeting the *same alias the account sends from*
(email to that same email). The chat route to the same conversation succeeds, and the
participant route to a different self-alias (email to own phone number) succeeds.
Sends to other recipients were never affected (29k+ historical successful
sends from this alias). Practical note: a participant-route send to a handle
equal to the account's own sending alias will yield `uncertain` (error row
written); targeting the chat by `chat_id` instead delivers and confirms.

Follow-up identified: the verifier excludes `error != 0` rows entirely, so it
cannot distinguish "row never appeared" from "row appeared with a send error".
Detecting error rows in the window could yield a more precise state than
`uncertain` (e.g. surface the recorded send error). Tracked in
`plans/README.md` direction notes.
