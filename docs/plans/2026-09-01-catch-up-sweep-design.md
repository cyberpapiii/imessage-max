# Catch-up sweep design (spike 077)

> **Type:** Design spike. Prototype is throwaway and must not be merged.
> **Plan:** `plans/077-spike-one-call-catch-up-sweep.md`
> **Branch:** `advisor/077-spike-catch-up-sweep` (from `main` at `bec239e`)
> **Measurement date:** 2026-09-02 (filename keeps the plan's 2026-09-01 date)
> **Database:** one operator's `~/Library/Messages/chat.db`, 7-day window, read-only. Re-measure before any implementation plan.

## Motivation

The plan was written against an older four-call catch-up: `get_unread`, then `get_active_conversations`, then `search unanswered=true`, then `get_messages`. Live skill text has already moved. Quote from `using-imessage-max/references/workflows.md:11-25`:

```
Preferred sequence:
1. `list_chats(since="2d", sort="recent")`
2. `get_unread(since="2d")`
3. `get_active_conversations(hours=48)`
4. `get_messages(chat_id="...", since="2d")` for the chats that matter

Reasoning:
- `list_chats` is the broadest recent preview
- `get_unread` defaults to unread thread summaries and catches still-unread items
- `get_active_conversations` helps prioritize
- `get_messages` is the deep read step
```

`SKILL.md:26-35` repeats the same order. The model still merges two or three chat lists by `chat_id` before it decides what to read. This spike asked whether one ranked list, built from the existing batched helpers, is actually smaller than that union, and whether it can be produced in one pass per signal.

Drift that is not a STOP: `ChatSummaryQueries` still has the five named helpers (`participantsByChat`, `participants`, `participantCountsByChat`, `lastMessageDatesByChat`, `lastMessagesByChat`) plus `recentSendersByChat` from plan 068. Twelve tools were registered on `main`; the spike branch registers a thirteenth throwaway tool. `docs/plans/` still uses `YYYY-MM-DD-slug.md`.

## Measurement

Window: type-0 messages with `m.date > (strftime('%s','now')-7*86400-978307200)*1000000000`. No `is_filtered` predicate (matches the plan's sqlite commands). Unread = `is_read=0 AND is_from_me=0`. Awaiting-my-reply = latest inbound type-0 date newer than latest outbound type-0 date, and the chat has at least one inbound type-0 in the window.

Unread is a subset of recent (0 unread chats outside recent). Step 1's all-time inbound/outbound comparison and Step 2's in-window `max(inbound)` / `max(outbound)` produced the same awaiting set (difference 0).

| Signal | Distinct chats |
|--------|---------------:|
| Recent (any type-0 in 7d) | 33 |
| Unread inbound in 7d | 17 |
| Awaiting my reply | 31 |
| Union of the three | 33 |

Seven exclusive combinations (counts only):

| Combination | Count |
|-------------|------:|
| Recent only | 1 |
| Unread only | 0 |
| Awaiting only | 0 |
| Recent + unread | 1 |
| Recent + awaiting | 15 |
| Unread + awaiting | 0 |
| Recent + unread + awaiting | 16 |

1+0+0+1+15+0+16 = 33. Unread 1+16 = 17. Awaiting 15+16 = 31.

The union equals recent. Awaiting is 31 of 33 recent chats. The only distinctive subset is unread (17).

Same window with `is_filtered = 0` (live `get_unread` / prototype default): recent 29, unread 14, awaiting 27, union 29. Same shape: union equals recent; awaiting ≈ recent.

`get_active_conversations` is a different signal from awaiting-my-reply. Bidirectional `min_exchanges >= 2` in the same 7d window is 7 chats (3 in 24h). Unread ∩ active-7d is 2. That small set is already what `get_active_conversations` returns; it is not the 31-chat awaiting set.

## Proposed shape

Throwaway `get_catch_up` on the spike branch. Example is synthetic (no live identifiers, names, or message text):

```json
{
  "chats": [
    {
      "chat_id": "chat1",
      "rank": "unread",
      "unread_count": 3,
      "awaiting_reply": true,
      "last_ts": "2026-09-02T12:00:00Z",
      "name": "Example",
      "last_message": {
        "from": "Example",
        "text": "one-line preview",
        "ago": "2h",
        "ts": "2026-09-02T12:00:00Z"
      }
    },
    {
      "chat_id": "chat2",
      "rank": "awaiting_reply",
      "unread_count": 0,
      "awaiting_reply": true,
      "last_ts": "2026-09-02T11:00:00Z",
      "name": "Example 2",
      "last_message": null
    },
    {
      "chat_id": "chat3",
      "rank": "recent",
      "unread_count": 0,
      "awaiting_reply": false,
      "last_ts": "2026-09-02T10:00:00Z",
      "name": "Example 3",
      "last_message": null
    }
  ],
  "total": 29,
  "more": true
}
```

`rank` is `unread`, `awaiting_reply`, or `recent`. Live default-params run (filtered, through the spike MCP server on port 18080): total 29, returned 20, more true, ranks unread 14 / awaiting_reply 6. Query count 4.

## Parameters

| Name | Default | Notes |
|------|---------|--------|
| `since` | `"7d"` | Same parser as `get_unread`. `"all"` drops the time bound. |
| `limit` | 20 | Max 50. |
| `is_group` | omitted | `true` groups only, `false` DMs only. Group means `chat_handle_join` count > 1. |
| `include_preview` | `true` | One-line `last_message` via `lastMessagesByChat`. |

No `include_filtered`. Prototype hides `is_filtered != 0`, matching `get_unread`. The measurement table above does not.

## Ranking rule

1. Unread (`unread_count > 0`) first.
2. Then awaiting-my-reply (`max inbound > max outbound` in the window, or inbound present and no outbound).
3. Then other recent activity.
4. Ties broken by last type-0 message date descending.

## Query plan

The plan's five named operations were: (1) batched awaiting, (2) unread counts from `get_unread`, (3) `lastMessageDatesByChat`, (4) `participantsByChat`, (5) `lastMessagesByChat`.

`lastMessagesByChat` itself issues two `Database.query` calls (the preview seek plus `attachmentTypesByMessage`). Following the five helpers literally is six queries, which trips the spike's ≤5 STOP. Reconsideration: fold the three signals and last-message date into one `GROUP BY chat_id` scan, the same shape `get_active_conversations` already uses for `max(inbound)` / `max(outbound)`.

Named queries for default params (`include_preview=true`):

1. Signal scan — recent chat ids, unread counts, max inbound, max outbound, last date, display name, participant count.
2. `ChatSummaryQueries.participantsByChat`
3. `ChatSummaryQueries.lastMessagesByChat` (preview seek, pinned by the scan's last dates)
4. `MessagePreviewResolver.attachmentTypesByMessage` (inside `lastMessagesByChat`)

Measured 4 queries on the live database and on the fixture. `include_preview=false` drops 3 and 4. No per-chat queries. `UnansweredHeuristics` was not modified; awaiting is the batched max-in vs max-out comparison, not `hasReplyWithinWindow`.

`recentSendersByChat` is not used. Large named-group participant previews therefore skip the recent-sender ordering that `list_chats` / `get_unread` apply. Acceptable for a throwaway; an implementation would add it as a fifth query and stay at the cap.

## Replace-or-wrap decision

Do not replace `get_unread` or `get_active_conversations`. They answer different questions (still-unread only; bidirectional activity with `min_exchanges`). A catch-up tool would wrap the same batched helpers, not call those tools. Because the recommendation is no-go, nothing is wrapped or replaced.

Extending `get_active_conversations` would fight its contract: default 24h, `min_exchanges=2`, max 168 hours, and a response shape pinned by `ResponseContractTests`. The awaiting definition here is almost the complement of "I sent last," not "we both talked twice."

## Skill text proposal

Keep the live four-call prescription. Do not change `workflows.md:11-25` or `SKILL.md:26-35`. The replacement that a yes decision would have landed:

```
Preferred sequence:
1. `get_catch_up(since="2d")`
2. `get_messages(chat_id="...", since="2d")` for the chats that matter
```

That text should not ship. `list_chats` already is the union. `get_unread` already is the only distinctive subset. `get_active_conversations` already is the small bidirectional set.

## Open questions

- Overlap numbers are one user's seven days. A quieter week, or a week of group storms, could move awaiting away from recent. Re-measure on the planning date of any follow-up.
- Whether "awaiting my reply" should require a question (the `search unanswered=true` heuristic) instead of inbound > outbound. The inbound>outbound definition is what made awaiting collapse into recent.
- Whether `list_chats` should grow an optional `sort="unread_first"` instead of a thirteenth tool. That is a list-chats plan, not this one.
- Filtered vs unfiltered: measurement followed the plan's SQL; the prototype followed `get_unread`. An implementation must pick one and say so in the skill.

## Recommendation

do not implement; the overlap does not justify it

The number: union = recent = 33, and 31 of those 33 recent chats are also awaiting. The merged set is not smaller than `list_chats`. Awaiting-my-reply is not an independent third signal under the definition this spike measured. Unread (17, or 14 filtered) is already `get_unread`. Bidirectional activity (7 at 7d, 3 at 24h) is already `get_active_conversations`.
