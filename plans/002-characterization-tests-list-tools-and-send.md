# Plan 002: Characterization tests for list tools and a test seam for the send path

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 57a2ff3..HEAD -- swift/Sources/iMessageMax/Tools/ swift/Sources/iMessageMax/Utilities/AppleScript.swift swift/Tests/iMessageMaxTests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW (Part A adds tests only; Part B is a mechanical seam refactor)
- **Depends on**: none (001 recommended first but not required)
- **Category**: tests
- **Planned at**: commit `57a2ff3`, 2026-06-11

## Why this matters

Plan 003 will refactor the per-chat query logic inside `list_chats` and `get_active_conversations` into a shared batched layer. Today those tools have response-*shape* tests (`ResponseContractTests.swift`, `OverviewResponseTests.swift`) but no behavior characterization of the data they compute — participant lists, last-message selection, awaiting-reply logic. Without characterization tests, the refactor in plan 003 can silently change behavior. Separately, `send` is the only write path in the product and its execute flow has exactly one test (`PlaceholderTests.swift:385-402`, which only checks that `reply_to` is rejected) — because `AppleScriptRunner` is a static enum called directly, there is no way to test the flow without automating Messages.app. This plan locks in current list-tool behavior (Part A) and introduces an injection seam for the script runner plus execute-path tests (Part B).

## Current state

- Test infrastructure: `swift/Tests/iMessageMaxTests/ToolTestSupport.swift` defines `ToolTestDatabase` — a temp-file SQLite fixture with the chat.db schema (`chat`, `handle`, `message`, `attachment` + join tables) and insert helpers (`insertHandle`, `insertChat`, `joinChatHandle`, `insertMessage`, `joinChatMessage`...). `fixture.database()` returns a real `Database` pointed at the fixture file. `makeSeededResolver()` returns a `ContactResolver` with a seeded cache (`+15550000001` → "Alice Smith", `+15550000002` → "Bob Brown", `+15550000003` → "Chris Green") so no Contacts permission is needed. Helpers `decodeJSONDictionary(from:)`/`decodeJSONArray` parse tool output.
- Exemplar test to model after: `swift/Tests/iMessageMaxTests/GetMessagesToolTests.swift` (uses the fixture + seeded resolver and asserts on decoded JSON).
- `swift/Sources/iMessageMax/Tools/ListChats.swift` — per-chat loop at lines 245-292 calls `getParticipants` (line 360), `getLastMessage` (line 390, which sets `awaitingReply: !last.isFromMe`), and `ChatSummaryBuilder.participantsPreview`.
- `swift/Sources/iMessageMax/Tools/GetActiveConversations.swift` — per-chat loop at lines 224-291; computes `exchanges = min(row.myCount, row.theirCount)` and `awaitingReply` from last-from-them vs last-from-me timestamps (lines 250-257).
- `swift/Sources/iMessageMax/Tools/Send.swift` — `actor SendTool` (line 110); calls the static `AppleScriptRunner` directly at lines 251-262:

```swift
                    return AppleScriptRunner.sendTextToParticipant(handle: handle, message: body)
                    // ...
                    return AppleScriptRunner.sendFileToParticipant(handle: handle, filePath: path)
                    // ...
                    return AppleScriptRunner.sendTextToChat(guid: guid, message: body)
                    // ...
                    return AppleScriptRunner.sendFileToChat(guid: guid, filePath: path)
```

- `swift/Sources/iMessageMax/Utilities/AppleScript.swift` — `enum AppleScriptRunner` (line 50), static functions that shell out to `osascript`/JXA. Its result type and validation behavior (missing-file rejection, overlong-message rejection) already have tests in `PlaceholderTests.swift` (`AppleScriptRunnerValidationTests`, line 117).
- `swift/Sources/iMessageMax/Tools/SendResolution.swift` — `SendResolver` resolves recipients/chats; already tested (`SendResolverTests`, `PlaceholderTests.swift:405`).
- Message dates in the fixture are Apple-epoch nanoseconds (nanoseconds since 2001-01-01). In tests, derive them as `Int64(date.timeIntervalSinceReferenceDate * 1_000_000_000)`.

Repo conventions: tests are XCTest classes, `@testable import iMessageMax`, async test methods where tools are async. Tool `execute`-style entry points are static or actor methods that return either a `Result` or throw — read each tool's signature before writing the test.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| All tests | `cd swift && swift test` | exit 0, all pass |
| Part A only | `cd swift && swift test --filter ListToolCharacterizationTests` | all pass |
| Part B only | `cd swift && swift test --filter SendToolExecuteTests` | all pass |

## Scope

**In scope**:
- `swift/Tests/iMessageMaxTests/ListToolCharacterizationTests.swift` (create)
- `swift/Tests/iMessageMaxTests/SendToolExecuteTests.swift` (create)
- `swift/Sources/iMessageMax/Utilities/AppleScript.swift` (Part B: add a protocol, keep `AppleScriptRunner` as the production implementation)
- `swift/Sources/iMessageMax/Tools/Send.swift` (Part B: route static calls through an injectable runner)
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- `ListChats.swift`, `GetActiveConversations.swift`, `GetUnread.swift`, `FindChat.swift` — Part A characterizes them AS IS. Changing tool behavior here defeats the purpose.
- `SendResolution.swift` — already tested; the seam is for script execution only.
- The JXA/AppleScript script bodies inside `AppleScript.swift` — do not reword scripts.

## Git workflow

- Branch: `advisor/002-characterization-tests`
- Commit per part (Part A, Part B); message style: lowercase conventional prefix, e.g. `test: characterize list tool behavior before batching refactor`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Part A — characterization tests for list tools

### Step A1: Read the two tools' entry points

Open `ListChats.swift` and `GetActiveConversations.swift`; find their execute functions (the function the registered tool handler calls — search for `static func register` and follow the call). Note the exact signature, parameters, and return type. The tests call these functions directly with `fixture.database()` and `makeSeededResolver()` — NOT through the MCP server.

**Verify**: you can state both signatures; existing tests in `OverviewResponseTests.swift` show how at least one of them is currently invoked — follow that pattern.

### Step A2: Write `ListToolCharacterizationTests.swift`

Build one fixture scenario reused across tests: 2 chats —
- Chat 1 (DM): handle Alice (`+15550000001`), two messages: one from Alice (newer), one from me (older).
- Chat 2 (group, named "Trip Crew"): handles Alice, Bob, Chris; last message from me.

Tests for `list_chats`:
1. `testListChatsResolvesParticipantNamesFromContacts` — Chat 2's participants preview contains "Alice" (resolved name, not the raw handle).
2. `testListChatsLastMessagePicksNewestNonReaction` — Chat 1's `last_message.from` is Alice's display name and the text matches the newer message. Add a reaction row (`associatedMessageType: 2000`) newer than both and assert it is NOT selected as the last message.
3. `testListChatsAwaitingReplyTrueWhenLastMessageFromThem` — Chat 1 `awaiting_reply == true`; Chat 2 `awaiting_reply` false/absent.
4. `testListChatsGroupFlagAndParticipantCount` — Chat 2 reports group truthy and participant count 3; Chat 1 omits or falsifies group.

Tests for `get_active_conversations` (same fixture, messages within the activity window — use recent dates):
5. `testActiveConversationsExchangeCountIsMinOfDirections` — chat with 3 my-messages and 2 their-messages reports `exchanges == 2`.
6. `testActiveConversationsAwaitingReplyComputedFromTimestamps` — last-from-them newer than last-from-me → awaiting reply true.

Assert on the decoded JSON keys actually produced (run once, inspect the failure output, then pin the real key names — that is what characterization means; the JSON uses short keys like `ts`).

**Verify**: `cd swift && swift test --filter ListToolCharacterizationTests` → 6 tests pass.

### Part B — seam + execute tests for send

### Step B1: Introduce a `ScriptRunning` protocol

In `AppleScript.swift`, define a protocol mirroring the four send functions used by `Send.swift` (match the real signatures and return type exactly — read them first):

```swift
protocol ScriptRunning: Sendable {
    func sendTextToParticipant(handle: String, message: String) -> <real return type>
    func sendFileToParticipant(handle: String, filePath: String) -> <real return type>
    func sendTextToChat(guid: String, message: String) -> <real return type>
    func sendFileToChat(guid: String, filePath: String) -> <real return type>
}
```

Add `struct LiveScriptRunner: ScriptRunning` whose methods forward to the existing `AppleScriptRunner` statics. Do not modify `AppleScriptRunner` itself. If the four functions are not all the call sites in `Send.swift` (check lines 240-280 for others, e.g. transfer observation), include exactly the set `SendTool` calls — no more.

**Verify**: `cd swift && swift build` → exit 0.

### Step B2: Inject the runner into `SendTool`

`SendTool` is an actor with `init(db: Database = Database(), resolver: ContactResolver)` (line 115). Add a `runner: any ScriptRunning = LiveScriptRunner()` init parameter stored as a property, and replace the four `AppleScriptRunner.` call sites with `runner.`. Registration code (`SendTool.register`) keeps the default — production behavior unchanged.

**Verify**: `cd swift && swift build` → exit 0; `cd swift && swift test` → existing tests (incl. `SendToolExecutionTests`, `AppleScriptRunnerValidationTests`) still pass.

### Step B3: Write `SendToolExecuteTests.swift`

Create a `StubScriptRunner: ScriptRunning` that records invocations (which method, handle/guid, message) and returns a configurable result. Fixture: `ToolTestDatabase` with one DM chat (Alice) and one group chat with a guid.

1. `testSendTextToKnownHandleInvokesParticipantSend` — execute send with Alice's phone number and text; assert stub was called once via `sendTextToParticipant` with the normalized handle and exact message text, and the response status is `"sent"` (see `SendResponse.success`, `Send.swift:41-52`).
2. `testSendToChatIdTargetsChatGuidNotParticipant` — send with the group chat's `chat_id`; assert `sendTextToChat` was called with the chat's guid, never the participant variant (guards the "never silently convert a group target into a DM" invariant).
3. `testScriptFailureProducesFailedStatus` — stub returns a failure; assert response status `"failed"` and the stub error surfaced in `error`.
4. `testAmbiguousRecipientReturnsCandidatesWithoutInvokingRunner` — two contacts whose names both match the recipient query (insert two handles, seed resolver so both resolve to names matching the query — read `SendResolver` ambiguity behavior in `SendResolution.swift` first); assert status `"ambiguous"` and the stub recorded zero invocations.

**Verify**: `cd swift && swift test --filter SendToolExecuteTests` → 4 tests pass.

## Test plan

This plan IS the test plan. Final regression: `cd swift && swift test` → all pass; total test count strictly greater than before by 10.

## Done criteria

- [ ] `cd swift && swift build` exits 0
- [ ] `cd swift && swift test` exits 0; 10 new tests pass
- [ ] `grep -n "AppleScriptRunner\." swift/Sources/iMessageMax/Tools/Send.swift` returns no matches (all routed through the injected runner)
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The tool execute functions cannot be called directly from tests without an MCP `Server` instance (i.e. `OverviewResponseTests.swift` uses some other mechanism you can't replicate).
- A characterization test reveals behavior that looks like a real bug (e.g. reactions selected as last message). Do not fix it — pin the current behavior with a `// NOTE: characterizes current behavior, possibly buggy` comment and list it in your report.
- `SendTool`'s runner calls don't match the four functions listed (the seam needs a different shape).
- Existing `SendToolExecutionTests` fail after Step B2.

## Maintenance notes

- Plan 003 (batched chat-summary queries) relies on Part A's tests as its regression gate — land this first.
- Plan 009 (send verification spike) will likely extend the `ScriptRunning` seam; keep the protocol minimal until then.
- Reviewer should scrutinize: that Part A tests assert on real current output (characterization), not on idealized output; and that `LiveScriptRunner` forwards without behavior change.
