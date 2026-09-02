# 077: SPIKE: one-call catch-up sweep

Planned at commit `639529e` on 2026-09-01. Baseline: `cd swift && swift build && swift test` passes with 370 tests, 0 failures.

## Executor instructions

This is a spike. The deliverable is a design document plus measurements, not merged code. A throwaway prototype branch is allowed and expected; it is not merged and is not reviewed for quality. Read this whole file, then run the drift check.

### Drift check

```bash
cd /Users/robdezendorf/Documents/GitHub/imessage-max
git rev-parse --short HEAD                                           # expect 639529e or a descendant
sed -n 11,25p using-imessage-max/references/workflows.md             # expect the four-call catch-up prescription
grep -n 'static func' swift/Sources/iMessageMax/Utilities/ChatSummaryQueries.swift   # expect :28 :84 :94 :123 :175
grep -n 'func hasReplyWithinWindow' swift/Sources/iMessageMax/Utilities/UnansweredHeuristics.swift   # expect one hit
sed -n 40,57p swift/Sources/iMessageMax/Server/ToolRegistry.swift    # expect 12 registrations
ls docs/plans/ | tail -3                                             # confirm YYYY-MM-DD-slug.md naming
```

## Status

- Priority: P2
- Size: M
- Kind: SPIKE (design + measurement, no merge)
- Depends on: nothing
- Blocks: a future implementation plan, if the spike says yes

## Why

The skill tells a model that "catching up" is four tool calls:

```
# using-imessage-max/references/workflows.md:11-25 (paraphrased structure)
1. get_unread            what needs a reply
2. get_active_conversations   what is busy
3. search unanswered=true     what I asked and got no answer
4. get_messages per chat      read the ones that matter
```

`SKILL.md:26-35` and `:94-97` repeat the same prescription. Each of the first three is a separate scan over `message`, each returns its own list of chats, and the model has to merge them by `chat_id` in its head before it can decide what to read. On the live database on 2026-09-01, over a 7-day window:

| Signal | Distinct chats |
|--------|---------------:|
| Any non-reaction message in 7 days | 33 |
| Unread inbound in 7 days | 17 |

That is enough overlap that a single ranked list is plausibly smaller than the union of three lists. Whether it is *actually* smaller, and whether it can be built from the batched helpers that already exist in one pass per signal, is what this spike measures.

## Current state

### Helpers that already batch by chat

```swift
// swift/Sources/iMessageMax/Utilities/ChatSummaryQueries.swift
static func participantsByChat(...)        // :28
static func participants(...)              // :84
static func participantCountsByChat(...)   // :94
static func lastMessageDatesByChat(...)    // :123
static func lastMessagesByChat(...)        // :175
```

All five take a list of chat ids and return dictionaries. They are the building blocks any merged sweep should compose.

### The one helper that does not batch

```swift
// swift/Sources/iMessageMax/Utilities/UnansweredHeuristics.swift
static func looksLikeQuestion(_ text: String) -> Bool
static func hasReplyWithinWindow(...)   // one query per candidate row
static func filterUnanswered(...)
```

`hasReplyWithinWindow` issues one query per candidate. That is fine for `search unanswered=true` on a small result page. It is the first thing that would blow up a sweep across 33 chats if each chat contributes several candidate questions. The design must either batch it (one query with `GROUP BY chat_id` finding the latest inbound date per chat, compared against the latest outbound question date) or exclude the "awaiting reply" signal from the merged call.

### Existing response shapes to build on

```swift
// swift/Sources/iMessageMax/Tools/GetUnread.swift:53-64
struct UnreadChatSummary: Codable {
    let chat: ChatSummary
    let unreadCount: Int
    let oldestUnread: String?
    let lastMessage: ...
}
```

```swift
// swift/Sources/iMessageMax/Tools/GetActiveConversations.swift:21-45
struct ActiveConversation: Codable { ... }
struct ConversationActivity: Codable { ... }
```

`get_active_conversations` schema (`:69-98`): `hours` default 24 max 168, `min_exchanges` default 2, `is_group`, `limit` default 10 max 50. `get_unread` schema (`GetUnread.swift:80-102`): `chat_id`, `since` default `"7d"`, `format`, `limit` default 50 max 100.

### Registration

`ToolRegistry.swift:40-57` registers 12 tools. A new tool would be the 13th and must be added to `ToolRegistryTests.swift:28` and to `docs/conformance-baseline.yml`; an extension of `get_active_conversations` would instead change that tool's schema and response, which `ResponseContractTests` may pin. The spike decides which; the follow-up implementation plan does the work.

## Commands

| Purpose | Command | Expect |
|---------|---------|--------|
| Build | `cd swift && swift build` | `Build complete!` |
| Suite (must still pass on the prototype branch, even though it is throwaway) | `cd swift && swift test` | 370 tests, 0 failures |
| Live 7d recent chats | `sqlite3 -readonly ~/Library/Messages/chat.db "SELECT COUNT(DISTINCT cmj.chat_id) FROM message m JOIN chat_message_join cmj ON cmj.message_id=m.ROWID WHERE m.date > (strftime('%s','now')-7*86400-978307200)*1000000000 AND m.associated_message_type=0"` | 33 at planning time |
| Live 7d unread chats | same with `AND m.is_read=0 AND m.is_from_me=0` | 17 at planning time |

## Scope

### In

- A design doc at `docs/plans/2026-09-01-catch-up-sweep-design.md` (keep the planned-at date even if written later; it records when the measurement was taken).
- A proposed response shape for `get_catch_up`, or an extension of `get_active_conversations`, with a written decision and the reasons.
- Ranking rule: unread first, then awaiting-my-reply, then recent-activity; ties broken by last message date descending.
- Parameters: `since` (default `"7d"`, same parser as `get_unread`), `limit` (default 20, max 50), `is_group` filter, `include_preview: Bool`.
- Measured 7-day overlap on the live db: for each chat in the union of the three signal sets, which signals fire. A table in the doc.
- A throwaway prototype on `advisor/077-spike-catch-up-sweep` that produces the merged list for the live db, so the measurement is of real output and not of SQL alone.
- A "replaces or wraps" decision: does the new call make `get_unread` and `get_active_conversations` redundant, or does it call their internals?

### Out

- Merging the prototype.
- Changing the skill files. The doc proposes the new workflow text; a later plan lands it.
- Any change to `UnansweredHeuristics` on `main`.
- Message bodies in the response beyond a one-line `last_message` preview.

## Git workflow

```bash
git checkout main && git pull --ff-only
git checkout -b advisor/077-spike-catch-up-sweep
```

Commits on the prototype branch can be rough (`wip:` prefix is acceptable here and only here). The design doc is committed on the same branch as `docs: catch-up sweep spike findings` so it can be cherry-picked to `main` by the advisor without the prototype. Executor does not push or merge.

Standing rules: never add `Task.sleep` under `swift/Sources` (`LaunchdSafetyTests` enforces, and the suite must pass even on the spike branch); never touch `.mcp.json`; never commit secrets (the measurement table must not contain phone numbers, emails, or message text; use `chat_id` and counts only); leave `advisor/018-imcore-helper-bridge` and `advisor/019-imcore-helper-dylib` alone.

## Steps

### Step 1: Measure overlap with SQL only

Write three read-only queries that each return the set of `chat_id` for the 7-day window: recent (any type-0 message), unread (`is_read=0 AND is_from_me=0`), awaiting-my-reply (latest inbound message in the chat is newer than my latest outbound, and the chat has at least one inbound message in the window). Save the raw output under the scratchpad, not the repo. Compute union size, and for each of the seven signal combinations, the count.

Verify: three numbers sum sensibly; unread is a subset of recent (it must be, by construction of the queries). If it is not, the queries disagree on the window or the type filter; fix before proceeding.

### Step 2: Batch the awaiting-reply signal

Write one SQL statement that yields, per chat, `max(inbound date)` and `max(outbound date)` in the window. `awaiting = inbound > outbound`. This replaces the per-row `hasReplyWithinWindow` for sweep purposes. Compare its chat set to Step 1's; they should match exactly. If Step 1 used a different definition, reconcile and record which one the doc adopts.

### Step 3: Prototype

On the spike branch, add a `GetCatchUpTool` that runs: (1) the batched awaiting query, (2) the existing unread counts logic from `GetUnread`, (3) `lastMessageDatesByChat`, then merges by `chat_id`, ranks, truncates to `limit`, and decorates with `participantsByChat` and `lastMessagesByChat`. Register it as a 13th tool on the branch only. Run it against the live db through the MCP server and capture the JSON (redact before saving to the doc).

Count queries issued: target is one per signal plus the two decoration helpers, so five per call regardless of chat count. If the prototype issues more than five queries for the default parameters, stop and reconsider before writing the doc.

Verify:

```bash
cd swift && swift build && swift test   # 370 tests, 0 failures, plus whatever throwaway tests you added
```

### Step 4: Decide replace-vs-wrap and write the doc

The doc has these sections, in order: Motivation (quote the four-call prescription), Measurement (the overlap table), Proposed shape (JSON example with the ranking field visible), Parameters, Ranking rule, Query plan (five queries, named), Replace-or-wrap decision, Skill text proposal (the replacement for `workflows.md:11-25`), Open questions, Recommendation (go / no-go for an implementation plan).

The recommendation must be one of: "implement as `get_catch_up`", "implement as `get_active_conversations` extension", or "do not implement; the overlap does not justify it". Give the number that drove the decision.

Commit: `docs: catch-up sweep spike findings`.

## Test plan

- Prototype tests are throwaway and live only on the spike branch.
- The baseline suite must pass on the spike branch at every commit, because `LaunchdSafetyTests` and the contract tests are the guard rails even for experiments.
- No test changes land on `main` from this plan.

## Done criteria

- `docs/plans/2026-09-01-catch-up-sweep-design.md` exists with all ten sections and a single recommendation.
- The overlap table has real numbers from the live db and contains no personal data.
- The prototype branch exists, builds, passes the suite, and is clearly marked throwaway in its last commit message.
- Query count per call is stated and is five or fewer for default parameters.

## STOP conditions

- The merged result cannot be produced with the existing batched helpers in one pass per signal. That means the sweep would need per-chat queries, and the whole premise fails. Write the doc with a "do not implement" recommendation and the reason.
- The prototype requires modifying `UnansweredHeuristics` in a way that changes `search unanswered=true` results. Keep the batched version separate; do not touch the per-row one.
- Any measurement step would require writing to `chat.db`. Never.
- The suite fails on the spike branch for any reason other than a throwaway test you wrote.

## Maintenance notes

- Overlap numbers are a snapshot of one user's 7 days. The doc should say so, and the follow-up plan should re-measure on its own planning date.
- If the recommendation is "extension", the follow-up plan must list `ResponseContractTests` and `docs/conformance-baseline.yml` as files that pin the extended shape.
- If the recommendation is "new tool", the follow-up plan must add the 13th registration to `ToolRegistryTests.swift:28`, add a README section, and add the tool to `docs/conformance-baseline.yml`.
