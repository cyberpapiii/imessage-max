# Plan 054: Consolidate the copied chat-id parsers, participant queries, error mappers, cursors, and unanswered heuristics

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 61e75d9..HEAD -- swift/Sources/iMessageMax/Tools swift/Sources/iMessageMax/Utilities/ChatSummaryQueries.swift swift/Sources/iMessageMax/Utilities/TimelineCursor.swift swift/Sources/iMessageMax/Utilities/ClientErrorMessages.swift swift/Sources/iMessageMax/Models`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: L
- **Risk**: MEDIUM
- **Depends on**: 041 (characterization tests), 042, 045, 046, 049, 051 (all touch the same files; this plan must be the last of the tool-internals series so the consolidation carries their fixes forward)
- **Category**: tech debt
- **Planned at**: commit `61e75d9`, 2026-09-01

## Why this matters

The twelve tools grew by copy-and-adjust. At `61e75d9` there are seven chat-id parsers, eleven participant queries, nine `DatabaseError` → tool-error mappers, three cursor codecs, two `looksLikeQuestion`/`hasReplyWithinWindow`/`filterUnanswered` triples with different argument orders and one with a wrong evaluation order, and five participant structs. Plans 042, 045, 046, 049 and 051 each fixed one copy of something because fixing all copies was out of their scope. This plan is where the copies become one, so the next fix lands once.

The consolidation is mechanical and fully covered by the existing tool tests plus plan 041's characterization tests. It is large only in the number of edits, not in judgement.

## Current state

All line numbers at `61e75d9`; plans that land before this one shift them, so use `grep` to relocate.

### Chat-id parsing (7 sites)

`GetChatDetails.swift:165`, `GetMessagesInternals.swift:130-145` (with the GUID `LIKE` fallback, escaped by plan 049), `GetContext.swift:477`, `SendResolution.swift:49` (`chatId.replacingOccurrences(of: "chat", with: "")`, which also mangles `"chat"` appearing inside a GUID), `GetUnread.swift:208`, `ListAttachments.swift:163`, `SearchInternals.swift:98`. Accepted forms across the copies: `"123"`, `"chat123"`, and (GetMessages only) a GUID substring.

### Participant queries (11 sites)

`FindChat.swift:342,480`; `GetChatDetails.swift:203`; `GetContext.swift:499`; `GetUnread.swift:504`; `SendResolution.swift:266`; `ListAttachments.swift:550`; `SearchInternals.swift:571,663`; `GetMessagesInternals.swift:172,210`. Each is a `chat_handle_join JOIN handle` query for one or more chat ids, followed by contact resolution. `Utilities/ChatSummaryQueries.swift:28-60` (`participantsByChat(db:chatIds:resolver:)`) is the batched, de-duplicated (after plan 046) version and is the target.

Participant structs: `ChatSummaryQueries.swift:9-13 Participant {handle, name, service}`; `Models/ChatIdentity.swift:25-35 Participant: Codable {handle, displayName, contactName}`; `GetUnread.swift:544 ParticipantInfo`; `SendResolution.swift:4 ParticipantInfo`; `Models/ResponsePrimitives.swift:31 ChatParticipant`. The response-facing one that clients see is whichever each tool encodes; check each tool's output schema in `Server/ServerExtensions.swift` before merging so the JSON keys do not change.

### Error mappers (9 sites)

`ListChats.swift:473-495` is the exemplar:

```swift
} catch let error as DatabaseError {
    switch error {
    case .notFound: return ListChatsError(error: "database_not_found", message: ClientErrorMessages.databaseNotFound)
    case .permissionDenied: return ListChatsError(error: "permission_denied", message: ClientErrorMessages.permissionDenied)
    case .queryFailed(let detail): return ListChatsError(error: "internal_error", message: ClientErrorMessages.internalDetail(detail, context: "list_chats"))
    ...
```

Copies at `FindChat.swift:212`, `GetContext.swift:437`, `GetUnread.swift:134`, `GetChatDetails.swift:135`, `GetActiveConversations.swift:122`, `ListAttachments.swift:194`, `Search.swift:420`, `GetAttachment.swift:248` (whose `:256 default:` collapses `permissionDenied` into `internal_error`, a behaviour difference clients can observe). `ClientErrorMessages.swift` has `databaseNotFound`, `permissionDenied`, `internalError`, `sanitized(_:)`, `internalDetail(_:context:)`.

### Cursors (3 codecs)

`SearchInternals.swift:3-6 SearchCursor {date: Int64; messageId: Int64}` with encode/decode at `:706-724`; `GetMessagesInternals.swift:3-6 GetMessagesCursor {date: Int64; messageId: Int}` with `:568-586`; `Utilities/TimelineCursor.swift` `TimelineCursor {date, messageId: Int64}` with `encode/decode/olderThanSQL/newerThanSQL`, plus `ChatListCursor` (2/3-part with `n:name:chatId`). The three message cursors encode the same pair; `GetMessagesCursor` uses `Int` for the id. Plan 041's `CursorCodecTests` pins the wire format of each, so consolidation must keep the encoded strings byte-identical (clients hold cursors across calls).

### Unanswered heuristics (2 triples)

`SearchInternals.swift:169 looksLikeQuestion(_ text: String?)`, `:195 hasReplyWithinWindow(db:chatId:messageDate:hours:)`, `:219 filterUnanswered` whose loop at `:227-243` calls `hasReplyWithinWindow` (a query) *before* checking `isQuestion`, so it queries for every row. `GetMessagesInternals.swift:366 looksLikeQuestion(_ text: String)`, `:389 hasReplyWithinWindow(chatId: Int, ...)`, `:342 filterUnanswered` with the correct order at `:350-355` (`looksLikeQuestion` guard first). `GetMessagesInternals.swift:506-520` also has `Array(reversedIndices)[i - 1]`, an O(n) array materialization per iteration inside a loop.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | `Build complete!` |
| Whole suite | `cd swift && swift test` | 0 failures |
| Site counts | see Done criteria greps | |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Utilities/ChatIdentifier.swift` (create), `Utilities/ToolErrorMapping.swift` (create), `Utilities/UnansweredHeuristics.swift` (create), `Utilities/TimelineCursor.swift`, `Utilities/ChatSummaryQueries.swift`
- Every file under `swift/Sources/iMessageMax/Tools/` listed above (call-site replacement only)
- `swift/Sources/iMessageMax/Models/ChatIdentity.swift`, `Models/ResponsePrimitives.swift` (struct unification)
- Tests: `swift/Tests/iMessageMaxTests/ChatIdentifierTests.swift` (create), `ToolErrorMappingTests.swift` (create); existing tool tests unchanged

**Out of scope** (do NOT touch, even though they look related):
- Any response key or value. This is a pure refactor; the tool tests are the oracle.
- `ChatListCursor` (different shape, one user).
- The `QueryBuilder`.
- Tool descriptions and output schemas (except to confirm you did not change a key).

## Git workflow

- Branch: `advisor/054-consolidate-internals`
- One commit per consolidation, type `refactor:`: chat-id, participants, errors, cursors, unanswered. Run the full suite before each commit so a bisect lands on one concern.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: `ChatIdentifier.parse`

Create `Utilities/ChatIdentifier.swift`:

```swift
enum ChatIdentifier {
    /// Accepts "123" and "chat123". Returns nil for anything else.
    static func parseRowId(_ raw: String) -> Int64? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let id = Int64(trimmed) { return id }
        if trimmed.hasPrefix("chat"), let id = Int64(trimmed.dropFirst(4)) { return id }
        return nil
    }

    /// parseRowId, then the GUID-substring fallback that get_messages historically allowed.
    static func resolve(_ raw: String, db: Database) throws -> Int64? {
        if let id = parseRowId(raw) { return id }
        // (move the escaped LIKE query from GetMessagesInternals.parseChatId here)
    }
}
```

Replace the seven sites. `SendResolution.swift:49` currently strips every `"chat"` occurrence; replacing it with `parseRowId` is a behaviour fix for GUIDs containing "chat", and `SendResolverTests` must stay green. Only `GetMessages` used the GUID fallback; give the other six `parseRowId` and keep `resolve` for `GetMessages` so no tool gains a fallback it did not have.

Add `ChatIdentifierTests` (4 cases: numeric, `chat` prefix, whitespace, garbage → nil).

**Verify**: `grep -rn "replacingOccurrences(of: \"chat\"" swift/Sources` → none; `grep -rn "hasPrefix(\"chat\")" swift/Sources/iMessageMax/Tools` → none; `swift test` → 0 failures.

### Step 2: Participants

Replace each of the 11 query sites with a call to `ChatSummaryQueries.participantsByChat` (batched) or a new single-chat convenience `participants(db:chatId:resolver:)` that wraps it. Where the site needs a different struct for its response, map from `ChatSummaryQueries.Participant` at the call site; then delete the now-unused local query code.

Struct unification: keep `ChatSummaryQueries.Participant` as the *query* result and `Models/ChatIdentity.Participant` as the *response* type; delete `GetUnread.ParticipantInfo`, `SendResolution.ParticipantInfo`, and `ResponsePrimitives.ChatParticipant` if their encoded keys are identical to `ChatIdentity.Participant` (compare `CodingKeys` or property names against each tool's output schema in `ServerExtensions.swift`). If any differs in keys, keep that one and note it in the report.

**Verify**: `grep -rn "FROM chat_handle_join" swift/Sources/iMessageMax/Tools` → none (all participant SQL lives in `ChatSummaryQueries.swift`); `swift test` → 0 failures.

### Step 3: Error mapping

Create `Utilities/ToolErrorMapping.swift` with one function:

```swift
enum ToolErrorMapping {
    struct Mapped { let code: String; let message: String }
    static func map(_ error: DatabaseError, context: String) -> Mapped
}
```

carrying the `ListChats` switch verbatim (all four cases; no `default`). Replace the nine sites: each keeps its own `XxxError(error:message:)` construction but feeds it from `map`. `GetAttachment`'s `default:` collapse goes away, so `permission_denied` is now reported by that tool too; add `ToolErrorMappingTests` (one test per `DatabaseError` case) and one `GetAttachmentToolTests` case asserting `permission_denied` maps correctly if the fixture can simulate it (if not, the mapping test covers it).

**Verify**: `grep -rn "case .permissionDenied" swift/Sources/iMessageMax/Tools` → none; `swift test` → 0 failures.

### Step 4: Cursors

Make `SearchInternals` and `GetMessagesInternals` use `TimelineCursor` for their message cursors. Before deleting `SearchCursor`/`GetMessagesCursor`, run `CursorCodecTests` (plan 041) and confirm `TimelineCursor.encode` produces the identical string for the same `(date, messageId)`; if the formats differ (separator, base64 vs plain), add a `TimelineCursor` encoding option that reproduces each legacy format exactly and keep the tests unchanged. `GetMessagesCursor.messageId: Int` → `Int64` at the boundary.

**Verify**: `swift test --filter CursorCodecTests` → 0 failures with no test edits; `grep -rn "struct SearchCursor\|struct GetMessagesCursor" swift/Sources` → none.

### Step 5: Unanswered heuristics

Create `Utilities/UnansweredHeuristics.swift` with `looksLikeQuestion(_ text: String?) -> Bool`, `hasReplyWithinWindow(db:chatId: Int64, messageDate: Int64, hours: Int) throws -> Bool` (carrying plan 042's bounded-hours line), and `filterUnanswered` in the *correct* order (`looksLikeQuestion` guard before the reply query, as `GetMessagesInternals.swift:350-355` does). Point both tools at it. Fix `GetMessagesInternals.swift:506-520` to index `reversedIndices` directly (it is a `ReversedCollection`; use `reversedIndices[reversedIndices.index(reversedIndices.startIndex, offsetBy: i - 1)]` or convert once outside the loop).

Add a test in `SearchToolTests` (or plan 041's `ProductOpenItemsTests` if it exists) asserting that a search with `unanswered: true` over 50 non-question messages issues no reply-window queries (use plan 051's query counter: count ≤ the base search count).

**Verify**: `grep -rn "func looksLikeQuestion\|func hasReplyWithinWindow\|func filterUnanswered" swift/Sources` → three matches, all in `UnansweredHeuristics.swift`; `swift test` → 0 failures.

### Step 6: Full suite and line count

**Verify**: `cd swift && swift test` → 0 failures; `git diff --stat 61e75d9..HEAD -- swift/Sources | tail -1` shows net deletions (this plan must remove more lines than it adds).

## Test plan

- New: `ChatIdentifierTests` (4), `ToolErrorMappingTests` (4), unanswered query-count test (1).
- The oracle is the existing suite: every tool test and every plan 041 characterization test must pass without modification. If a test needs editing, the refactor changed behaviour; stop and report.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` → 0 failures, with no edits to pre-existing test files (`git diff --stat 61e75d9..HEAD -- swift/Tests | grep -v "Tests.swift |.*+"` shows only additions)
- [ ] `grep -rn "FROM chat_handle_join" swift/Sources/iMessageMax/Tools` → none
- [ ] `grep -rn "case .permissionDenied" swift/Sources/iMessageMax/Tools` → none
- [ ] `grep -rn "struct SearchCursor\|struct GetMessagesCursor\|struct ParticipantInfo\|struct ChatParticipant" swift/Sources` → none (or the documented exception from Step 2)
- [ ] `grep -rn "func looksLikeQuestion" swift/Sources | wc -l` → `1`
- [ ] `git diff --stat 61e75d9..HEAD -- swift/Sources | tail -1` → deletions exceed insertions
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any pre-existing test must change to pass. Report which and why.
- Two participant structs encode different JSON keys for the same concept and both are in output schemas. Report the pair; renaming a response key is a client-facing change the operator must approve.
- `TimelineCursor` cannot reproduce a legacy cursor format byte-for-byte. Report the formats.
- Plans 042/045/046/049/051 have not all landed. This plan rebases on all of them.

## Maintenance notes

- After this plan, a new tool should need: `ChatIdentifier.parseRowId`, `ChatSummaryQueries.participantsByChat`, `ToolErrorMapping.map`, `TimelineCursor`. A reviewer seeing a new `chat_handle_join` query or a new `switch error` in a tool file should ask why.
- Deferred: a `Tool` protocol with a default `execute` wrapper doing the error mapping. Worth it if a thirteenth tool is added.
