# Send delivery semantics (spike 078)

> **Type:** Design spike. No tool code. No prototype branch.
> **Plan:** `plans/078-spike-send-delivery-semantics.md`
> **Branch:** `advisor/078-spike-send-delivery-semantics` (from `main` at `ac0229d`)
> **Measurement date:** 2026-09-02 (filename keeps the plan's 2026-09-01 date)
> **Database:** one operator's `~/Library/Messages/chat.db`, read-only. macOS 26.6.2 (25G83). sqlite3 3.51.0. Re-measure before any implementation plan.

`confirmed` means the verifier found the outbound row in chat.db with `error = 0`. It does not mean the recipient's device got the message. This spike asked whether `is_delivered` / `date_delivered` / `date_read` settle over time in a way that would justify exposing them.

## Question

Does the not-delivered share of successful outbound iMessages shrink as rows age, or is it a flat property of the row? If it shrinks, a later re-check could be worth building. If it is flat, `confirmed` should stay as it is.

## Method

Outbound rows: `is_from_me = 1`, `error = 0`, `associated_message_type = 0`, `date` within 180 days. Chat type is `chat.style` (43 = dm, 45 = group) and `chat.service_name`. Age is Apple-epoch nanoseconds: `(strftime('%s','now') - 978307200) * 1e9 - m.date`.

Two snapshots of the same bucket query, more than one hour apart. Same SQL as the plan (`scratchpad/078-buckets.sql` lived under `/tmp/scratchpad-078/`, not in the repo):

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

Latency for settled rows (`is_delivered = 1` and `date_delivered > 0`), same 180-day outbound filter:

```sql
SELECT
  service_name,
  CASE style WHEN 43 THEN 'dm' WHEN 45 THEN 'group' ELSE 'other' END AS kind,
  COUNT(*) AS n,
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

Percentiles: export `(date_delivered - date) / 1e9` for iMessage group rows, `sort -n`, then `awk` `p50 = a[int((n-1)*0.50)+1]` (same for p90 / p99). sqlite3 3.51 can do `NTILE`; this run used sort/awk.

Probe: one `send` via the MCP tool (local HTTP server on port 18081, same binary as this tree; the live plug-routed service returned `database.status=permission_denied` and could not verify). Destination was the operator's own handle. Response `status=confirmed`. Then:

```sql
SELECT is_delivered, date_delivered, date_read, error,
       (strftime('%s','now') - 978307200) * 1000000000 - date AS age_ns
FROM message WHERE guid = '<verified_message_guid>';
```

No further sends. Style-43 threads that contain the same own handle exist in chat.db but Messages.app rejects them (`Could not find chat 'any;+;…'`), so the probe landed on the live thread Messages actually opens: `chat.style = 45`, one handle.

## Results

### Snapshot 1 — 2026-09-02T13:26:28Z

No rows in `0_under_1m`, `1_1m_to_10m`, or `2_10m_to_1h`.

| bucket | service | kind | delivered | not_delivered | read_receipt |
|--------|---------|------|----------:|--------------:|-------------:|
| 3_1h_to_1d | SMS | dm | 0 | 10 | 0 |
| 3_1h_to_1d | iMessage | dm | 0 | 1 | 0 |
| 3_1h_to_1d | iMessage | group | 19 | 0 | 5 |
| 4_over_1d | RCS | dm | 3 | 27 | 0 |
| 4_over_1d | SMS | dm | 0 | 893 | 1 |
| 4_over_1d | SMS | group | 16 | 7 | 6 |
| 4_over_1d | iMessage | dm | 0 | 1529 | 0 |
| 4_over_1d | iMessage | group | 2659 | 0 | 223 |

iMessage 180-day totals from this snapshot: **0 / 1530** DMs delivered, **2678 / 2678** groups delivered. Matches the plan's Why table (1,530 / 2,678) split by style, not by age.

### Snapshot 2 — 2026-09-02T14:28:45Z

62 minutes after snapshot 1.

| bucket | service | kind | delivered | not_delivered | read_receipt |
|--------|---------|------|----------:|--------------:|-------------:|
| 2_10m_to_1h | iMessage | group | 1 | 0 | 1 |
| 3_1h_to_1d | SMS | dm | 0 | 6 | 0 |
| 3_1h_to_1d | iMessage | dm | 0 | 1 | 0 |
| 3_1h_to_1d | iMessage | group | 16 | 0 | 5 |
| 4_over_1d | RCS | dm | 3 | 27 | 0 |
| 4_over_1d | SMS | dm | 0 | 897 | 1 |
| 4_over_1d | SMS | group | 16 | 7 | 6 |
| 4_over_1d | iMessage | dm | 0 | 1529 | 0 |
| 4_over_1d | iMessage | group | 2662 | 0 | 223 |

`4_over_1d` iMessage: DMs **0 / 1529**, identical to snapshot 1. Groups **2662 / 0** versus 2659 / 0. The +3 is aging: snapshot 1's `3_1h_to_1d` iMessage group was 19; snapshot 2 has 16 there plus the probe in `2_10m_to_1h`. No evidence `is_delivered` flipped on an existing row. 180-day iMessage totals at this timestamp: still **0 / 1530** DMs delivered, **2679 / 0** groups delivered (the extra group row is the probe).

### Latency — 2026-09-02T13:35:56Z

Negative `(date_delivered - date)` counts: **0**. No epoch mismatch.

| service | kind | n | min_s | mean_s | max_s |
|---------|------|--:|------:|-------:|------:|
| RCS | dm | 3 | 0.20 | 1.31 | 2.29 |
| SMS | group | 11 | 0.25 | 1.87 | 5.53 |
| iMessage | dm | **0** | — | — | — |
| iMessage | group | 1593 | 0.00013 | 70.1 | 26180 |

iMessage group percentiles (sort/awk on the same filter): n=1593, **p50=0.44s**, **p90=2.67s**, **p99=588.5s**. There is no iMessage DM delivered distribution. A later re-count at 13:38Z (after the probe) was iMessage group n=1594 / 1599 depending on `service` vs `service_name`; p50 stayed 0.44s.

Apple partial index `message_idx_undelivered_one_to_one_imessage` exists. Messages.app treats undelivered one-to-one iMessages as a distinct state. On this account that state is the steady state for every iMessage DM in 180 days.

### Read receipts

Planning-time (2026-09-01): 235 of 5,172 outbound type-0 rows in 180 days had `date_read != 0`. At 13:38Z: 236 of 5,173 (the self-probe set `date_read`). iMessage DMs in snapshot 1: **0** read receipts across 1,530 rows. iMessage groups: 5 + 223 = 228. Read receipts are opt-in and, here, also a group-correlated signal. Not a DM delivery oracle.

### Probe

Send at **2026-09-02T13:37:54Z**. `verified_message_guid=04007E64-8C94-442B-92B1-38B42E5B9605`. Thread: style 45, one handle, iMessage. `error` stayed 0.

| when | clock (UTC) | age_ns | is_delivered | date_delivered | date_read | error |
|------|-------------|-------:|-------------:|---------------:|----------:|------:|
| ~0 s (first poll after `confirmed`) | 13:37:54 | ~0 | 1 | 810049076256772992 | 810049076247939072 | 0 |
| ~80 s | 13:39:14 | 79892999936 | 1 | 810049076256772992 | 810049076247939072 | 0 |
| ~11 min | 13:49:16 | 681892999936 | 1 | 810049076256772992 | 810049076247939072 | 0 |

No column moved after the first poll. A style-45 self thread is delivered at write time, the same as every other iMessage group row.

The plan's "if still `is_delivered=0` at 10 min for a self-send, recommend (C)" gate did not fire for this thread. The 1,530 iMessage DMs already at `is_delivered=0` for more than a day are the gate that matters.

## Interpretation

The not-delivered share does not shrink with age. Young buckets were empty at snapshot 1. Every iMessage DM in the 1h–1d and over-1d buckets is not delivered. Every iMessage group in those buckets is delivered. That is a **style split**, not a settle-over-time curve.

SMS is excluded from the headline: SMS DMs are almost all `is_delivered=0` (903 in snapshot 1), SMS groups are mixed, and RCS DMs are mostly not delivered. Those columns are not an iMessage receipt.

`SendVerifier.primaryScan` (`SendVerifier.swift:133`) selects `guid, date, text, attributedBody, error` only. `confirmed` at `Send.swift:462` is `error == 0` (`SendVerifier.swift:158-159`). The verifier window is five 200 ms polls, about one second. That is the correct window for "row exists without error." It is the wrong window for delivery, and a longer window would not help DMs that stay 0 for 180 days.

## Recommendation

**(C) do nothing.**

Deciding number: **0 of 1,530** outbound iMessage DMs in 180 days have `is_delivered = 1`, and the over-1d bucket is the same shape. A `delivered` field on `SendResponse` would be a restatement of `chat.style == 45` for iMessage, not a receipt. A re-check tool would return the same bits.

(A) is rejected: the existing verifier window almost never sees a later flip, and when `is_delivered` is 1 it is already 1 at insert for groups.

(B) is rejected: `verified_message_guid` already lets a caller look again; a server-side re-check would not add information this database does not already show as a style correlate.

Do not redefine `confirmed`. Keep the wording in `Send.swift:250-262` and `README.md:379`.

## Proposed shape

None. (A) and (B) are not recommended.

If a future plan still wanted (B) after a re-measure that showed DM settle, the files would be: `Send.swift` struct and CodingKeys, `README.md` send result semantics (currently around `:379`), `ResponseContractTests` for the struct, `SendManualValidation.md` for a new manual check, and — only if (B) is a new tool — `ToolRegistryTests.swift:16-29` plus `docs/conformance-baseline.yml`. Proof words stay unchanged.

## Open questions

- Numbers are one account, 180 days, macOS 26.6.2. Another account that actually gets `is_delivered=1` on DMs could look different. Re-measure on the planning date of any follow-up and record `sw_vers`.
- The self-probe could not use a live style-43 thread. Messages.app does not open the style-43 rows that contain the operator's own handle. A consenting two-party DM probe would be a different experiment; this spike did not send one.
- Why Apple's `message_idx_undelivered_one_to_one_imessage` exists while this account's one-to-one iMessages never leave that state is unanswered. The index is evidence the column is meaningful to Apple, not evidence it is useful on this Mac.
- `date_read` on groups (228 of 2,678) is a secondary opt-in signal. Not enough to justify a `read` field on `send`.
