# 078: SPIKE: send delivery semantics

Planned at commit `639529e` on 2026-09-01. Baseline: `cd swift && swift build && swift test` passes with 370 tests, 0 failures.

## Executor instructions

This is a spike. The deliverable is a measurement document with exact SQL and a recommendation. No code is merged. Read this whole file, then run the drift check.

### Drift check

```bash
cd /Users/robdezendorf/Documents/GitHub/imessage-max
git rev-parse --short HEAD                                                 # expect 639529e or a descendant
grep -n 'SELECT m.guid, m.date, m.text, m.attributedBody, m.error' swift/Sources/iMessageMax/Tools/SendVerifier.swift   # expect one hit near :130
grep -n 'case .confirmed(let guid, _):' swift/Sources/iMessageMax/Tools/Send.swift   # expect :469
grep -n 'verifiedMessageGuid\|verified_message_guid' swift/Sources/iMessageMax/Tools/Send.swift   # expect struct field and CodingKey in :20-49
sqlite3 -readonly ~/Library/Messages/chat.db "PRAGMA table_info(message)" | grep -c 'is_delivered\|date_delivered\|date_read'   # expect 3
```

## Status

- Priority: P2
- Size: M
- Kind: SPIKE (measurement + recommendation, no merge)
- Depends on: nothing
- Blocks: a future implementation plan if the recommendation is "add fields"

## Why

`send` returns `confirmed` when the verifier finds the row in chat.db with `error == 0`:

```swift
// swift/Sources/iMessageMax/Tools/SendVerifier.swift:158-166 (excerpt)
if row.error == 0 { return .confirmed(guid: row.guid, ...) }
```

The verifier's scan selects no delivery columns:

```swift
// SendVerifier.swift:130-143 (excerpt)
SELECT m.guid, m.date, m.text, m.attributedBody, m.error
...
LIMIT 200
```

So `confirmed` means "Messages.app accepted the message and wrote it to chat.db without an error code". It does not mean the recipient's device received it. The tool description at `Send.swift:250-262` is careful about this, and the response carries `verified_message_guid` so a caller could in principle look again later. But nothing in the server offers that second look, and nobody has measured how `is_delivered` actually behaves over time, so we do not know whether a second look would be worth anything.

Live data on 2026-09-01, outbound iMessage rows with `error = 0` and `associated_message_type = 0` in the last 180 days:

| `is_delivered` | Rows |
|---------------:|-----:|
| 0 | 1,530 |
| 1 | 2,678 |

Read receipts over all outbound type-0 rows in 180 days: 235 of 5,172 have `date_read != 0`.

Roughly a third of successful sends never flip `is_delivered`. Whether that is "not delivered yet at the time of the poll" (a timing question) or "this column is unreliable" (a semantics question) determines whether a `delivered` field is worth exposing. This spike answers that with age buckets.

## Current state

### Send response

```swift
// swift/Sources/iMessageMax/Tools/Send.swift:20-49 (fields)
struct SendResponse: Codable {
    let status: String
    let timestamp: String
    let chat: ...
    let deliveredTo: ...
    let chatId: ...
    let message: String?
    let error: String?
    let candidates: ...
    let verifiedMessageGuid: String?
    let verifiedAt: String?
    let intendedChat: ...
    let actualChatId: ...
    // snake_case CodingKeys
}
```

`static func confirmed(guid:deliveredTo:chat:)` at `:71-86` populates `verifiedMessageGuid`. The verify switch at `:464-485` maps `VerificationResult` to the response.

### Verifier timing

`SendVerifier.swift:30-40` init: polls 5 times at 200 ms, with a 2 s clock-skew allowance and a 60 s search window. The whole verification finishes within about one second of the send. That is far too early for `is_delivered` to have settled for a recipient on a slow network, which is why the verifier correctly ignores it. The question is what a re-check at 1 minute, 10 minutes, 1 hour, or 1 day would show.

### Proof vocabulary that must not change

`confirmed`, `uncertain`, `mismatch`, `failed_delivery`, `partial_failure`, `sent`. The manual validation doc pins their meaning (`swift/Tests/iMessageMaxTests/SendManualValidation.md:119-220`) and `ResponseContractTests` pins the response struct. This spike may propose additive nullable fields. It may not propose redefining `confirmed`.

### Prior art for a measurement doc

`docs/plans/2026-06-11-send-verification-design.md` section 3 (lines 330-457) contains a latency measurement with an experiment script and a results table. Follow that format.

### Columns available

```
16|date_read|INTEGER
17|date_delivered|INTEGER
18|is_delivered|INTEGER default 0
```

plus `error`, `is_sent`, `date`. Apple keeps a partial index `message_idx_undelivered_one_to_one_imessage`, which suggests Messages.app itself tracks undelivered one-to-one iMessages as a distinct state. Note this in the doc as evidence the column is meaningful to Apple.

## Commands

| Purpose | Command | Expect |
|---------|---------|--------|
| Build | `cd swift && swift build` | `Build complete!` |
| Suite | `cd swift && swift test` | 370 tests, 0 failures (unchanged; this plan merges no code) |
| Column presence | `sqlite3 -readonly ~/Library/Messages/chat.db "PRAGMA table_info(message)" \| grep -i 'delivered\|date_read'` | three rows |
| Base delivered split | see Why section | 1,530 / 2,678 at planning time |

## Scope

### In

- `docs/plans/2026-09-01-send-delivery-semantics.md` with exact SQL for every number.
- Delivery settle rate by age bucket: rows aged under 1 min, 1-10 min, 10-60 min, 1-24 h, over 24 h at the time the query runs, split by `is_delivered`. Because a single snapshot conflates "sent recently" with "not delivered", run the snapshot twice, at least one hour apart, and report both, so the doc can show whether the young buckets migrate.
- Split by chat type: `chat.style` (45 group, 43 one-to-one) and `chat.service_name` (`iMessage` vs `SMS`). SMS rows are expected never to flip; confirm and exclude from the headline.
- `date_delivered` versus `date` latency distribution for rows with `is_delivered = 1`: median, p90, p99 in seconds.
- Read-receipt rate (`date_read != 0`) as a secondary signal, one-to-one iMessage only, with a note that read receipts are opt-in per contact.
- One controlled probe: send one message to yourself or to a consenting test contact via the MCP `send` tool, capture `verified_message_guid`, then query that guid's `is_delivered` and `date_delivered` at roughly 5 s, 60 s, and 10 min. Record the three observations. This is one message; do not loop or automate sends.
- Recommendation, one of: (A) additive nullable `delivered: Bool?` and `read: Bool?` on `SendResponse`, populated only if settled within the existing verifier window (expected: almost never, so likely rejected); (B) a re-check path that accepts `verified_message_guid` and returns the current delivery columns, either as a new small tool or as a `send` mode; (C) do nothing, with the number that justifies it.

### Out

- Any code merge. A scratch script under the scratchpad directory is fine; do not add it to the repo.
- Redefining `confirmed` or any other proof word.
- Changing `SendVerifier` polling.
- Bulk or repeated sends for measurement. One probe message, by hand.

## Git workflow

```bash
git checkout main && git pull --ff-only
git checkout -b advisor/078-spike-send-delivery-semantics
```

Single commit: `docs: send delivery semantics spike findings`. Executor does not push or merge.

Standing rules: never add `Task.sleep` under `swift/Sources` (moot here, no source changes; `LaunchdSafetyTests` enforces regardless); never touch `.mcp.json`; never commit secrets (the doc must contain no phone numbers, emails, message text, or guids tied to a real contact; the probe guid may appear only if the probe went to yourself); leave `advisor/018-imcore-helper-bridge` and `advisor/019-imcore-helper-dylib` alone.

## Steps

### Step 1: Age-bucket snapshot, run twice

Save this as `scratchpad/078-buckets.sql` (outside the repo) and run it with `sqlite3 -readonly`:

```sql
WITH outbound AS (
  SELECT m.ROWID, m.date, m.is_delivered, m.date_delivered, m.date_read,
         c.style, c.service_name,
         (strftime('%s','now') - 978307200) * 1000000000 - m.date AS age_ns
  FROM message m
  JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
  JOIN chat c ON c.ROWID = cmj.chat_id
  WHERE m.is_from_me = 1
    AND m.error = 0
    AND m.associated_message_type = 0
    AND m.date > (strftime('%s','now') - 180*86400 - 978307200) * 1000000000
)
SELECT
  CASE
    WHEN age_ns < 60e9        THEN '0_under_1m'
    WHEN age_ns < 600e9       THEN '1_1m_to_10m'
    WHEN age_ns < 3600e9      THEN '2_10m_to_1h'
    WHEN age_ns < 86400e9     THEN '3_1h_to_1d'
    ELSE                           '4_over_1d'
  END AS bucket,
  service_name,
  CASE style WHEN 43 THEN 'dm' WHEN 45 THEN 'group' ELSE 'other' END AS kind,
  SUM(is_delivered = 1) AS delivered,
  SUM(is_delivered = 0) AS not_delivered,
  SUM(date_read <> 0)   AS read_receipt
FROM outbound
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;
```

Record the timestamp of each run in the doc. Run once, wait at least one hour (by wall clock, not by any code), run again.

Verify: the two `4_over_1d` rows for iMessage should be nearly identical between runs. If they differ by more than a handful, something other than settling is moving the column; note it.

### Step 2: Delivery latency for settled rows

```sql
SELECT
  service_name,
  CASE style WHEN 43 THEN 'dm' WHEN 45 THEN 'group' ELSE 'other' END AS kind,
  COUNT(*) AS n,
  -- seconds between send and delivery
  MIN((date_delivered - date) / 1e9)  AS min_s,
  AVG((date_delivered - date) / 1e9)  AS mean_s,
  MAX((date_delivered - date) / 1e9)  AS max_s
FROM message m
JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
JOIN chat c ON c.ROWID = cmj.chat_id
WHERE m.is_from_me = 1 AND m.error = 0 AND m.associated_message_type = 0
  AND m.is_delivered = 1 AND m.date_delivered > 0
  AND m.date > (strftime('%s','now') - 180*86400 - 978307200) * 1000000000
GROUP BY 1, 2;
```

For median and p90, export `(date_delivered - date) / 1e9` for iMessage dm rows to a scratch CSV and compute with `sort -n` and `awk`, or with `NTILE` if the bundled sqlite3 supports window functions (`sqlite3 --version` at 3.25 or later does). Show the command used.

Verify: `min_s` is not negative. If it is, `date_delivered` uses a different epoch or unit on some rows; investigate before trusting the distribution.

### Step 3: The one controlled probe

Send one message with the MCP `send` tool to yourself. Note `verified_message_guid` from the response. Then:

```sql
SELECT is_delivered, date_delivered, date_read, error,
       (strftime('%s','now') - 978307200) * 1000000000 - date AS age_ns
FROM message WHERE guid = '<verified_message_guid>';
```

Run at about 5 s, 60 s, and 10 min after the send, by hand. Record all three rows.

Verify: `error` stays 0 throughout. If `is_delivered` is still 0 at 10 minutes for a self-send on an online Mac, the column is not a reliable delivery signal for this account and the recommendation must be (C).

### Step 4: Write the doc

Sections: Question, Method (with both snapshot timestamps), Results (bucket table from both runs, latency table, probe table), Interpretation (does the not-delivered share shrink with age or is it flat), Chat-type notes (SMS excluded and why; group vs dm), Recommendation with the number that decided it, Proposed shape if (A) or (B), Files that would need to change if implemented (`Send.swift` struct and CodingKeys, `README.md:350-355` send result semantics, `ResponseContractTests` for the struct, `SendManualValidation.md` for a new manual check, and `ToolRegistryTests.swift:28` plus `docs/conformance-baseline.yml` if (B) is a new tool), Open questions.

Commit: `docs: send delivery semantics spike findings`.

## Test plan

- No test changes. The suite must still report 370 tests, 0 failures on the branch, which it will because no source changed.
- The spike's own verification is the two-snapshot comparison and the probe.

## Done criteria

- `docs/plans/2026-09-01-send-delivery-semantics.md` exists with every number backed by SQL shown in the doc.
- Both snapshots recorded with timestamps at least one hour apart.
- Probe recorded at three ages.
- One recommendation (A, B, or C), with the deciding number.
- No personal data in the doc.
- One commit on `advisor/078-spike-send-delivery-semantics`, not pushed.

## STOP conditions

- `is_delivered`, `date_delivered`, and `date_read` are all null or zero for every outbound row in the last day. The columns are not populated on this build; write the doc with recommendation (C) and the evidence, and stop.
- Step 2 shows negative latencies on more than a stray row. Epoch mismatch; stop and report rather than guessing a correction.
- You are tempted to send more than one probe message. Don't. Ask the advisor.
- Any step would require writing to chat.db or changing verifier polling on `main`.

## Maintenance notes

- If the recommendation is (B), the implementation plan must keep `confirmed` untouched and add the re-check as a separate proof word or a separate tool; the vocabulary in `Send.swift:250-262` and `README.md:350-355` is a contract.
- Numbers are one account's 180 days on one macOS build. The follow-up plan re-measures on its planning date and records the macOS version alongside.
- The partial index `message_idx_undelivered_one_to_one_imessage` is Apple's; if it disappears in a future macOS, that is a signal the semantics changed and this doc should be re-run.
