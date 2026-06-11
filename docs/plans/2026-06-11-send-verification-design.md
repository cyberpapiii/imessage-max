# Send Verification Design Spike

> **Type:** Design spike — no production code changes.
> **Plan reference:** Plan 009, written at commit `57a2ff3`, 2026-06-11.
> **Drift check result:** No drift on `Send.swift`, `SendResolution.swift`, or
> `AppleScript.swift` since the plan was authored.

---

## 1. Current flow

### 1.1 The four send paths

All four paths converge at `Send.swift:246–265` after resolution and
confirmation. The send target comes from `SendResolution.ResolvedTarget.target`
which is either `.participant(handle:chatId:)` or `.chat(guid:chatId:)`.

**Path A — Text → Participant** (`Send.swift:251–253`)

1. `SendResolver.resolve(chatId:to:)` returns `.participant(handle:String, chatId:Int?)`.
   `handle` is the raw iMessage address (phone number or email in `handle.id`).
   `chatId` is the DB ROWID of the most-recent one-on-one chat for this handle,
   or `nil` if no prior conversation exists in chat.db
   (`SendResolution.swift:228–245`, `findDirectChatForHandle`).
2. `AppleScriptRunner.sendTextToParticipant(handle:message:)` is called
   (`AppleScript.swift:129–141`).
3. The AppleScript (`AppleScript.swift:81–91`) calls `send messageText to
   targetBuddy` inside a `tell application "Messages"` block. Arguments are
   passed via `argv` to prevent shell injection.
4. `AppleScriptRunner.run(script:arguments:missingTargetError:)` (`AppleScript.swift:377–425`)
   invokes `/usr/bin/osascript` via `Process`, waits up to 30 seconds, checks
   `terminationStatus`. **Stdout is discarded.** Only stderr is examined for
   error classification.
5. On `terminationStatus == 0`, `run()` returns `.success(())`.
6. Back in `Send.send()`, every payload result is checked; if all succeed,
   `SendResponse.success(deliveredTo:chat:)` is returned with `status: "sent"`
   (`Send.swift:287`, `Send.swift:41–52`).

**Path B — Text → Chat** (`Send.swift:258–260`)

Same as Path A except:
- Resolution produced `.chat(guid:String, chatId:Int)`. The `guid` is the
  Messages-internal chat identifier (e.g., `iMessage;-;+15555550100` or
  `iMessage;+;chat12345`) from `chat.guid` in chat.db (`SendResolution.swift:55–67`).
- `AppleScriptRunner.sendTextToChat(guid:message:)` is called
  (`AppleScript.swift:144–157`).
- The AppleScript (`AppleScript.swift:93–102`) calls `send messageText to
  chat id chatGuid`. The chat GUID is the stable Messages identifier; this
  route guarantees the correct thread is targeted.

**Path C — File → Participant** (`Send.swift:252–255`)

1. Resolution same as Path A. `chatId` may be `nil`.
2. `AppleScriptRunner.sendFileToParticipant(handle:filePath:)` is called
   (`AppleScript.swift:159–179`).
3. Before the AppleScript call, `prepareTrackedOutgoingFile(sourcePath:)` is
   invoked (`AppleScript.swift:203–228`). It:
   a. Queries existing outgoing transfer statuses for the filename
      (`queryOutgoingTransferStatuses`, `AppleScript.swift:264–288`).
   b. Copies the file into `~/Pictures/imessage-max-staging/<UUID>/filename`.
   c. Returns a `PreparedOutgoingFile` with `trackingName` (original filename)
      and `existingOutgoingTransferCount` (baseline of transfers already
      in-flight under that name).
4. The handoff AppleScript runs (`AppleScript.swift:104–115`): `send
   attachmentFile to targetBuddy`.
5. On handoff success, `waitForTransferCompletion(preparedFile:)` begins
   (`AppleScript.swift:290–331`): a 15-second polling loop at 0.5s intervals.
   Each iteration calls `queryOutgoingTransferStatuses` and drops the first
   `existingOutgoingTransferCount` entries (to isolate the new transfer).
   `interpretTransferStatuses` maps results to `finished`, `failed`, `pending`,
   or `unknown` (`AppleScript.swift:230–245`). On `finished` → `.success(())`;
   on `failed` → `.failure(.transferFailed)`; on timeout with pending seen →
   `.failure(.transferPending)`; otherwise → `.failure(.transferStatusUnknown)`.
6. `transferPending` and `transferStatusUnknown` errors are caught at
   `Send.swift:267–276` and produce `SendResponse.pending(...)` with
   `status: "pending_confirmation"`.

**Path D — File → Chat** (`Send.swift:260–263`)

Same as Path C except the handoff AppleScript targets `chat id chatGuid`
(`AppleScript.swift:117–127`). The transfer-observation loop is identical.

### 1.2 What AppleScript success actually proves

For all four paths, success means: **"Messages.app accepted the
`send` command without raising an AppleScript error."** This is transport
handoff, not delivery.

Specifically it does NOT prove:
- The message appeared in the intended conversation thread in chat.db.
- The message was delivered to the recipient's device.
- The message was not re-routed by Messages.app to an unexpected chat
  (e.g., a group chat instead of the DM when a participant handle is shared).
- For files: even the transfer-observation loop only observes the LOCAL
  file-transfer queue state, not end-to-end delivery.

The `send` verb in the Messages AppleScript dictionary returns a `message`
object per Apple's AppleScript spec. However, the production `run()` method
(`AppleScript.swift:377–425`) **discards stdout entirely** — only `stderr`
is examined. Therefore even if Messages.app returns a message guid, it is
lost. (See Section 2.4 for the JXA-returns-id investigation.)

### 1.3 Transfer-observation state machine scope

The file-transfer observation (`waitForTransferCompletion`) begins after the
handoff AppleScript returns successfully and ends when either `finished`,
`failed`, or the 15-second timeout is reached. The states are:
- `finished` — Messages accepted and queued the transfer locally.
- `failed` — Messages rejected the transfer.
- `pending` — Transfer is in-progress but not yet confirmed.
- `unknown` — No transfer record found under the tracking name.

This machine observes the **local Messages.app transfer queue**, not chat.db.
A `finished` transfer still does not prove the message row exists in the
intended conversation in chat.db.

### 1.4 ChatReference and deliveredTo population

`ChatReference` (`chat: ChatReference?` in `SendResponse`) is populated from
`SendResolution.ResolvedTarget.chat`:
- Chat sends (`SendResolution.swift:75–86`): constructed from the `chat.guid`
  and `chat.display_name` row fetched from chat.db during resolution. Always
  present for chat targets.
- Participant sends (`SendResolution.swift:132–143`, `159–170`, `186–198`):
  fetched via `chatReference(chatId:)` (`SendResolution.swift:290–301`) if a
  direct chat ROWID was found; `nil` if no prior chat exists in DB.

`deliveredTo` is the display names of resolved participants, set from
`resolved.deliveredTo` at resolution time — not from a post-send DB read.

---

## 2. Verification query design

### 2.1 What we have at send time

After resolution succeeds and before the AppleScript call, the following are
available:

| Available value | Chat send | Participant send |
|-----------------|-----------|------------------|
| `chat.ROWID` (Int) | Always (`chatId` from `.chat(guid:chatId:)`) | Optionally (`chatId?` from `.participant(handle:chatId:)`) |
| `chat.guid` (String) | Always | Not directly, but can be looked up from `chatId` |
| participant handle | No (only participants list) | Yes |
| send wall-clock time | Yes (capture `Date()` immediately before AppleScript call) | Yes |
| expected text | Yes (for text payloads) | Yes |
| expected filename | Yes (for file payloads, `trackingName`) | Yes |

**Action**: Capture `let sendTime = Date()` immediately before each AppleScript
call and pass it into the verification layer.

### 2.2 Candidate SQL query

This query is the primary re-read for text sends to a known chat ROWID:

```sql
-- Verification query: did a message I sent appear in the intended chat?
-- Inputs:
--   :chat_rowid      INT   -- DB ROWID of the intended chat (chat.ROWID)
--   :send_time_ns    INT64 -- AppleTime.fromDate(sendTime) nanoseconds
--   :skew_before_ns  INT64 -- lookahead before send (default: 2_000_000_000 = 2s)
--   :window_ns       INT64 -- forward window (default: 60_000_000_000 = 60s)

SELECT
    m.ROWID         AS message_rowid,
    m.guid          AS message_guid,
    m.date          AS message_date_ns,
    m.text          AS message_text,
    m.attributedBody AS attributed_body,
    m.is_sent       AS is_sent,
    m.cache_has_attachments AS has_attachments
FROM message m
JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
WHERE cmj.chat_id = :chat_rowid
  AND m.is_from_me = 1
  AND m.date >= (:send_time_ns - :skew_before_ns)
  AND m.date <= (:send_time_ns + :window_ns)
ORDER BY m.date ASC;
```

The query returns all outbound rows in the intended chat within the time
window. Text matching is done in Swift after fetching, using
`MessageTextExtractor.extract(text:attributedBody:)` to normalize both the
DB row and the expected text before comparison. This is intentional: SQL
TEXT equality would miss `attributedBody`-stored text.

**For participant sends where `chatId` is nil:**
Fall back to a scan across all chats for the handle:

```sql
-- Fallback: find outbound messages to any chat containing this handle,
-- within the time window. Used when chatId is nil or for mismatch detection.
SELECT
    m.ROWID, m.guid, m.date, m.text, m.attributedBody, m.is_sent,
    c.ROWID AS chat_rowid, c.guid AS chat_guid, c.display_name
FROM message m
JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
JOIN chat c ON cmj.chat_id = c.ROWID
JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
JOIN handle h ON chj.handle_id = h.ROWID
WHERE h.id = :handle
  AND m.is_from_me = 1
  AND m.date >= (:send_time_ns - :skew_before_ns)
  AND m.date <= (:send_time_ns + :window_ns)
ORDER BY m.date ASC;
```

This fallback also enables **mismatch detection** (R5): if the primary query
finds nothing but the fallback finds the message in a *different* chat, the
result is `mismatch`.

**For file sends:**
Replace text equality with `m.cache_has_attachments = 1` in the filter.
An exact filename match is not possible purely from chat.db (the filename is
in the `attachment` table joined via `message_attachment_join`). Optionally:

```sql
-- Filename-level match for file sends:
SELECT m.ROWID, m.guid, m.date, a.filename
FROM message m
JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
JOIN message_attachment_join maj ON m.ROWID = maj.message_id
JOIN attachment a ON maj.attachment_id = a.ROWID
WHERE cmj.chat_id = :chat_rowid
  AND m.is_from_me = 1
  AND m.date >= (:send_time_ns - :skew_before_ns)
  AND m.date <= (:send_time_ns + :window_ns)
  AND a.filename LIKE '%' || :tracking_name
ORDER BY m.date ASC;
```

### 2.3 Matching ambiguity table

| Failure mode | Description | Mitigation |
|---|---|---|
| **Unicode normalization mismatch** | Messages.app may normalize emoji or combining characters differently from what was passed via `argv`. E.g., a decomposed accent (NFD) vs. composed (NFC). | Compare using `String.compare(_:options:)` with `.caseInsensitive` and `.diacriticInsensitive` as a secondary fallback if exact match fails. |
| **Whitespace mangling** | Trailing whitespace or newlines may be stripped by Messages. | Trim both sides before comparison. |
| **`attributedBody` storage** | Messages stores some sent texts only in `attributedBody`, leaving `text` NULL (`MessageTextExtractor.swift:8–15`). Reactions, rich-link previews, and certain emoji messages use this path. | Always use `MessageTextExtractor.extract(text:attributedBody:)` for comparison, not raw `m.text`. |
| **Two rapid identical sends** | If the same text is sent twice within the skew window to the same chat, both will match. | Take the first match (earliest date). Flag a warning in the response if multiple candidates are found. |
| **Late DB write** | Messages.app may not flush the row to chat.db within the polling window. | This is the primary reason for `uncertain` state; measured in Step 3 (blocked). Design conservatively with a 30-second polling window total. |
| **No text column (audio/sticker)** | `m.text` is NULL and `attributedBody` may not contain extractable text. | For file sends, match on `cache_has_attachments = 1` plus optional filename join. |
| **chat.db read latency after write** | SQLite WAL mode: uncommitted transactions from Messages.app may not be visible to read-only connections immediately. | Use `PRAGMA wal_checkpoint` is not available to read-only connections. Use short poll intervals (1s) and tolerate some lag. |

### 2.4 JXA-returns-id investigation

**Finding: Messages.app's AppleScript dictionary declares `send` returns a
`message` object.** Per Apple's Messages.app scripting dictionary (accessible
via `osadecompile` or Script Editor), the `send` verb signature is:

```
send (text or file) to (buddy or chat) → message
```

This means the AppleScript `send` command *should* return a `message` object
from which `id` (the guid) can be extracted. However, the return value's
reliability across macOS versions is not confirmed.

**Current status in code: the return value is unconditionally discarded.**
The production `run()` method (`AppleScript.swift:377–425`) captures stdout
but never reads it — `stdoutPipe.fileHandleForReading.readDataToEndOfFile()`
is called but the result is only decoded to check that the process produced
some output. The `ScriptExecutionResult.stdout` field exists but is never
examined for the message guid.

By contrast, `runScriptForTesting()` (`AppleScript.swift:360–375`) does
return `stdout`, proving the infrastructure can capture it.

**To verify the guid return path** (cannot be confirmed in this spike without
a test send):

```applescript
-- Test script: does Messages return the message guid?
on run argv
    set recipientId to item 1 of argv
    set messageText to item 2 of argv
    tell application "Messages"
        set targetService to 1st account whose service type = iMessage
        set targetBuddy to participant recipientId of targetService
        set sentMsg to send messageText to targetBuddy
        return id of sentMsg
    end tell
end run
```

Run via `AppleScriptRunner.runScriptForTesting(script:arguments:)` with a
known handle and observe whether stdout contains a GUID string. If it does,
matching by guid eliminates all heuristic text-matching ambiguity entirely.

**Verdict: unknown without a live test send. The infrastructure can capture
it. If the guid is returned reliably, it should be used in preference to
timestamp+text matching.** This should be the first empirical test in the
latency measurement experiment (Step 3, blocked).

### 2.5 Polling design

Recommendation: up to **6 polls**, at intervals of **1s, 2s, 3s, 5s, 5s, 5s**
(total budget: ~21 seconds). Rationale:
- Text sends to a local Mac typically appear in chat.db within 1–3 seconds
  of the AppleScript call returning (hypothesis; to be measured in Step 3).
- A 21-second total budget fits within the typical MCP tool-call timeout
  headroom while covering edge cases (slow network, Messages.app disk flush
  latency).
- Exponential-ish backoff reduces chat.db read pressure on early polls.

State transitions during polling:
```
[start polling]
  → found in intended chat:     → confirmed
  → found in different chat:    → mismatch (stop immediately)
  → polls exhausted, not found: → uncertain
  → polling error (DB access):  → uncertain (log the error)
```

For file sends: the existing `waitForTransferCompletion` loop (15-second
budget, 0.5s intervals) handles the transfer-queue observation. The DB
re-read loop runs after `waitForTransferCompletion` returns `finished`. If
it returns `transferPending` or `transferStatusUnknown`, the state is
`pending` without DB verification (no change from today).

---

## 3. Chat.db write latency measurement

**NOT MEASURED — blocked on environment.**

The operator has not designated a test chat and has not consented to test
messages. The following experiment must be run by the operator before the
build plan for this slice can confirm the polling parameters in Section 2.5.

### Experiment script

```bash
#!/usr/bin/env bash
# /tmp/measure_send_latency.sh
# Prerequisites:
#   - Operator has designated a TEST_HANDLE (phone or email)
#   - Operator has designated a TEST_CHAT_ROWID (integer, from list_chats)
#   - Full Disk Access granted to Terminal
#   - Messages.app running

set -euo pipefail

TEST_HANDLE="${1:?Usage: $0 <handle> <chat_rowid>}"
TEST_CHAT_ROWID="${2:?Usage: $0 <handle> <chat_rowid>}"
DB="$HOME/Library/Messages/chat.db"
MARKER="imessage-max-latency-test-$(date +%s)"

echo "=== Send latency experiment ==="
echo "Handle:  $TEST_HANDLE"
echo "Chat ID: $TEST_CHAT_ROWID"
echo "Marker:  $MARKER"
echo ""
echo "Sending message..."

SEND_TIME_UNIX=$(python3 -c "import time; print(int(time.time() * 1e9))")
# Apple epoch offset: 978307200 seconds (2001-01-01 - 1970-01-01)
APPLE_EPOCH_OFFSET=$((978307200 * 1000000000))
SEND_TIME_APPLE=$((SEND_TIME_UNIX - APPLE_EPOCH_OFFSET))

osascript -e "
    on run argv
        set recipientId to item 1 of argv
        set messageText to item 2 of argv
        tell application \"Messages\"
            set targetService to 1st account whose service type = iMessage
            set targetBuddy to participant recipientId of targetService
            set sentMsg to send messageText to targetBuddy
            return id of sentMsg
        end tell
    end run
" -- "$TEST_HANDLE" "$MARKER"

echo "Send command returned. Polling chat.db..."
echo ""

for i in $(seq 1 30); do
    sleep 0.5
    ELAPSED=$(echo "scale=1; $i * 0.5" | bc)
    RESULT=$(sqlite3 "file:$DB?mode=ro" \
        "SELECT m.ROWID, m.guid, m.date FROM message m \
         JOIN chat_message_join cmj ON m.ROWID = cmj.message_id \
         WHERE cmj.chat_id = $TEST_CHAT_ROWID \
           AND m.is_from_me = 1 \
           AND m.text = '$MARKER' \
           AND m.date >= ($SEND_TIME_APPLE - 5000000000) \
         LIMIT 1;" 2>&1)
    if [ -n "$RESULT" ]; then
        echo "FOUND at elapsed ${ELAPSED}s: $RESULT"
        break
    else
        echo "Not yet visible at ${ELAPSED}s"
    fi
done
```

### Operator steps to run the experiment

1. In iMessage Max, call `list_chats` to find the ROWID of a safe test
   conversation (a chat you can send test messages to without confusion).
2. Note the chat ROWID (the integer part of the `chat_id`, e.g., `chat42` →
   rowid `42`) and the participant's handle.
3. Grant Full Disk Access to Terminal (or the shell running the experiment).
4. Run: `bash /tmp/measure_send_latency.sh "<handle>" <chat_rowid>`
5. Repeat 3–5 times and record:
   - Whether `osascript` stdout contains a message guid (confirms JXA return).
   - The elapsed time until the row appears in chat.db.
   - Any gaps or errors.
6. Record findings in the build plan that implements the verification loop;
   use them to tune the polling budget in Section 2.5.

### Also verify during this experiment

- Whether `osascript` stdout contains the sent message's guid (see Section 2.4).
- Whether `m.text` or `m.attributedBody` (or both) are populated for the
  sent row; and whether the text matches the input exactly (Unicode check).
- Whether `m.is_sent = 1` is set on the initial write or updated later.

---

## 4. Proof-state machine

### 4.1 State set

The following states replace the current `"sent"` return-on-transport-success
behavior with an honest proof vocabulary aligned to R1–R3.

| State | `status` string | Trigger condition |
|-------|-----------------|-------------------|
| `confirmed` | `"confirmed"` | DB re-read found the outbound message row in the intended chat within the polling window |
| `uncertain` | `"uncertain"` | Transport succeeded, polling exhausted (N polls, T seconds), row not found in DB |
| `mismatch` | `"mismatch"` | DB re-read found the message in a *different* chat than the intended target |
| `pending` | `"pending_confirmation"` | (a) File transfer in-flight per AppleScript observation; (b) text send polling not yet exhausted (intermediate, not surfaced to MCP clients in synchronous mode) |
| `failed` | `"failed"` | AppleScript returned an error OR file transfer observed as `failed` |
| `cancelled` | `"cancelled"` | User elicitation returned declined |
| `ambiguous` | `"ambiguous"` | Multiple contacts matched the `to` parameter |

### 4.2 Per-state detail

**`confirmed`**

- *Trigger:* Primary SQL query (Section 2.2) returns at least one row whose
  extracted text matches the sent text (or whose `cache_has_attachments = 1`
  matches a file send), within the polling window.
- *Response fields:*
  ```json
  {
    "status": "confirmed",
    "timestamp": "<ISO8601 send time>",
    "verified_at": "<ISO8601 time when DB row was found>",
    "verified_message_guid": "<m.guid from chat.db>",
    "chat": { "id": "chat42", "name": "Alice" },
    "delivered_to": ["Alice"]
  }
  ```
- *Agent behavior:* Report delivery as confirmed with evidence. Conversation
  is safe to reference in follow-up calls.

**`uncertain`**

- *Trigger:* Transport succeeded (AppleScript exit 0), but DB polling
  exhausted without finding a matching row in the intended chat.
- *Response fields:*
  ```json
  {
    "status": "uncertain",
    "timestamp": "<ISO8601 send time>",
    "chat": { "id": "chat42", "name": "Alice" },
    "delivered_to": ["Alice"],
    "message": "Send accepted by Messages.app but could not be verified in chat.db within the polling window. The message was probably sent. Use get_messages on chat42 to confirm."
  }
  ```
- *Agent behavior:* Inform the user that the send cannot be confirmed;
  suggest a follow-up `get_messages` call on the intended chat. Do not
  treat as failure.

**`mismatch`**

- *Trigger:* Primary query finds no row in the intended chat, but the
  fallback handle-scan query (Section 2.2) finds the message in a different
  chat. This is the R5 violation surface.
- *Response fields:*
  ```json
  {
    "status": "mismatch",
    "timestamp": "<ISO8601 send time>",
    "intended_chat": { "id": "chat42", "name": "Alice" },
    "actual_chat_id": "chat99",
    "actual_chat_guid": "<guid>",
    "delivered_to": ["Alice"],
    "message": "Message was found in a different chat than intended. This is a routing mismatch. Do not treat as confirmed."
  }
  ```
- *Agent behavior:* Alert loudly. Do not treat as success. Escalate to the
  user for manual review. Do not retry without explicit target clarification.

**`pending`** (file transfers only in synchronous mode)

- *Trigger:* `waitForTransferCompletion` returns `.failure(.transferPending)`
  or `.failure(.transferStatusUnknown)` — the file transfer is in-flight but
  timed out (15 seconds). No change from today's `"pending_confirmation"`.
- *Response fields:* Same as today's `pending` constructor (`Send.swift:54–65`).
  Optionally add `"message"` guidance to re-check with `get_messages`.
- *Agent behavior:* Inform the user the file transfer is in progress. Suggest
  follow-up `get_messages` to confirm arrival. Do not retry the send.

**`failed`**

- *Trigger:* AppleScript returned an error (non-zero `terminationStatus`), or
  file transfer observed as `failed` by `waitForTransferCompletion`.
- *Response fields:* Unchanged from today's `error` constructor (`Send.swift:80–91`).
- *Agent behavior:* Report failure. User may retry after addressing the
  underlying cause (permissions, recipient not found, etc.).

**`cancelled`**

- *Trigger:* User elicitation returned declined, or `confirmSendWithClientIfAvailable`
  returned `.declined`.
- *Response fields:* Unchanged from today's `cancelled` constructor (`Send.swift:67–78`).
- *Agent behavior:* Acknowledge cancellation. No message was sent.

**`ambiguous`**

- *Trigger:* Multiple contacts matched the `to` parameter.
- *Response fields:* Unchanged from today's `ambiguous` constructor
  (`Send.swift:93–104`).
- *Agent behavior:* Present candidates; ask user to disambiguate with a
  handle or `chat_id`.

### 4.3 The `"sent"` → `"confirmed"` compatibility question

**Problem:** Today `"sent"` means "transport accepted" (an overclaim). Existing
agents may dispatch on `"sent"` to treat the send as complete. If we rename
or redefine it, those agents break or behave incorrectly.

**Options:**

| Option | Description | Trade-off |
|--------|-------------|-----------|
| A. Hard rename | `"sent"` → `"confirmed"` everywhere. | Most honest. Breaking change for any MCP client that pattern-matches `"sent"`. Requires a version bump and client migration. |
| B. Alias during transition | Emit both `status: "confirmed"` and `legacy_status: "sent"` for one release. | Backward compatible but clutters the response shape. Requires sunset date. |
| C. Redefine in place | `"sent"` stays, but now means "confirmed via DB re-read". | Zero client changes, but the status string is semantically confusing going forward. |
| D. Expand the vocabulary | `"sent"` keeps its current meaning (transport accepted, not verified). Add `"confirmed"` as a stronger state. Only returned when DB re-read succeeds. | Backward compatible. Honest. Agents that care about proof upgrade to checking for `"confirmed"`. The downside: `"sent"` remains and still overclaims for clients that don't check for `"confirmed"`. |

**Recommendation: Option D for v2.**

Rationale:
- Preserves backward compatibility for existing agents.
- Honest: `"confirmed"` is a new, stronger guarantee available only when
  verification succeeds.
- Agents aware of the v2 vocabulary can upgrade their behavior incrementally.
- If `"sent"` is later determined to be confusing, a future breaking-change
  release can remove it with clear communication.

The open question of whether to eventually hard-rename `"sent"` is deferred
to the maintainer (see Section 5.3).

---

## 5. Build outline and open questions

### 5.1 Incremental build slices

**Slice 1: Verification query as a pure function with DB fixture tests**
- Introduce `SendVerifier` as a new type (not touching `SendTool`).
- Expose a method: `func verify(chatRowId: Int, sendTime: Date, expectedText: String?, hasAttachment: Bool) async throws -> VerificationResult`.
- `VerificationResult` is an enum: `confirmed(guid: String, date: Date)`, `mismatch(actualChatRowId: Int)`, `notFound`.
- Write XCTest cases against the existing fixture DB (or an in-memory SQLite
  fixture created in setUp).
- **No production code change.** `SendTool` is untouched.
- Effort: ~1 day.

**Slice 2: Verification loop behind the `ScriptRunning` seam**
- Introduce `protocol ScriptRunning` with four methods:
  ```swift
  protocol ScriptRunning {
      func sendTextToParticipant(handle: String, message: String) -> Result<Void, SendError>
      func sendFileToParticipant(handle: String, filePath: String) -> Result<Void, SendError>
      func sendTextToChat(guid: String, message: String) -> Result<Void, SendError>
      func sendFileToChat(guid: String, filePath: String) -> Result<Void, SendError>
  }
  ```
  `AppleScriptRunner` conforms to `ScriptRunning` as a trivial adapter.
- `SendTool` accepts a `ScriptRunning` dependency (defaulting to
  `AppleScriptRunner`). This is the seam for test injection.
- Add the verification loop to `SendTool.send(...)`: after each text payload
  returns `.success`, call `SendVerifier.verify(...)` with the polling
  parameters from Section 2.5.
- Update `SendResponse` to carry `verified_message_guid` and `verified_at`
  fields (nil when not confirmed).
- **Compatibility**: `status` behavior follows Option D from Section 4.3.
- Effort: ~1.5 days.

**Slice 3: Response/status migration with compatibility shims**
- Formally add `"confirmed"`, `"uncertain"`, and `"mismatch"` as status
  values to `SendResponse`.
- Add static constructors `SendResponse.confirmed(...)`, `SendResponse.uncertain(...)`,
  `SendResponse.mismatch(...)`.
- Update tool description and output schema comment to document the new states.
- If Option D recommendation is accepted, `"sent"` is preserved as a status
  value for transport-only success (backward compat).
- Effort: ~0.5 days.

**Slice 4: Tool description updates**
- Update `send` tool description to explain the proof vocabulary.
- Update `diagnose` capability output to report `send_verification: "db_reread"`.
- Update manual validation plan (`SendManualValidation.md`) with confirmed/
  uncertain/mismatch scenarios.
- Effort: ~0.5 days.

**Total estimated effort: ~3.5 days across four slices.**

### 5.2 Shape changes needed from the `ScriptRunning` seam

The verification loop needs to capture wall-clock time *before* the
AppleScript call. The seam must expose the send time so the caller can
pass it to `SendVerifier`. Two options:
1. `SendTool` captures `Date()` before calling `ScriptRunning`; preferred.
2. `ScriptRunning` returns a timestamp alongside the result; more complex.

Option 1 is simpler and keeps the seam minimal. The `ScriptRunning` protocol
stays purely about transport.

For file sends: the seam needs to expose the `trackingName` that
`prepareTrackedOutgoingFile` generates, since that name is used for both
the transfer observation loop and (optionally) the filename-match SQL.
Current `sendFileToParticipant/sendFileToChat` in `AppleScriptRunner`
encapsulate this internally. The seam could either:
- Return the tracking name alongside the result (preferred for testability), or
- Keep the current opaque interface and match only on `cache_has_attachments`.

The maintainer should decide before Slice 2 begins.

### 5.3 Open questions for maintainer decision

1. **`"sent"` rename vs. Option D.** The recommendation is Option D (expand
   the vocabulary, keep `"sent"` for backward compat). If the maintainer
   decides on a hard rename, Slice 2 becomes a breaking change and needs a
   changelog entry and client coordination.

2. **Polling budget vs. tool-call latency.** The Section 2.5 recommendation
   is ~21 seconds total (6 polls). This adds latency to every successful
   text send. If `"uncertain"` is acceptable for most users and only
   `"confirmed"` matters for high-stakes sends, the polling could be gated
   on a new `verify: true` parameter to keep the default fast. Should
   verification always run, or be opt-in?

3. **Should `"uncertain"` auto-suggest a follow-up `get_messages` call?**
   The recommendation includes a human-readable `message` field suggesting
   the follow-up. Should the response also include a structured hint
   (e.g., `"follow_up_tool": "get_messages", "follow_up_args": {...}`) so
   agents can act on it programmatically?

4. **Mismatch severity.** Should `mismatch` throw a `ToolError` (treated as
   an error by MCP clients, same as `"failed"` and `"ambiguous"` today at
   `Send.swift:180–182`) or return as a non-error response? Treating it as
   a `ToolError` makes it hard to miss but gives agents less context.
   Returning as a regular response with a loud `message` field lets agents
   read the details. Recommendation: treat `mismatch` as a `ToolError`
   (same code path as `failed`).

5. **`chatId` nil on participant sends.** When `SendResolver` returns
   `.participant(handle:chatId:nil)` (no prior DM found), there is no chat
   ROWID for the primary query. Options: (a) attempt the fallback
   handle-scan query immediately (may be slow); (b) leave the `chatId` nil
   and return `uncertain` without verification; (c) perform a post-send
   chat lookup by handle. Which is acceptable?

### 5.4 What this spike did NOT investigate

- **Actual chat.db write latency.** The critical empirical input for polling
  parameters is absent (blocked, see Section 3).
- **JXA `send` return value under macOS Sequoia/Tahoe.** Whether Messages
  returns the message guid reliably is unconfirmed without a live test send.
- **`is_sent` flag timing.** Whether `m.is_sent = 1` is set on the initial
  write or only after delivery confirmation — relevant to whether we can
  filter on it during verification.
- **Behavior for SMS-fallback sends.** When an iMessage fails to deliver and
  falls back to SMS, the chat.db row appears with `service = "SMS"`. The
  verification query does not filter on `service`, so an SMS fallback would
  count as `confirmed` in the iMessage-targeted chat. This may be acceptable
  or may need a `service = 'iMessage'` guard.
- **Multi-payload sends (file + text).** When both file and text are sent in
  one tool call, they are dispatched sequentially (`Send.swift:246–285`).
  The verification design covers each payload independently, but the combined
  response shape for mixed-payload confirmed sends is not fully specified.
- **Live inbox / delta surface.** Post-send verification is read-only polling;
  it does not address the broader live-inbox problem. See R19 and "Deferred
  for later" in the brainstorm doc.
