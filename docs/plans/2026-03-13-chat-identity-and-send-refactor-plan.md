# Chat Identity And Send Refactor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Refactor iMessage Max so conversation identity is canonical across discovery, retrieval, and sending, while adding reliable group-chat sends and outbound file/image sends through the existing public Messages scripting path.

**Architecture:** Keep the current public/local architecture: `chat.db` for reads, `CNContactStore` for names, and Messages AppleScript for writes. Replace the current handle-centric send approximation with a small chat-centric send model built around exact `chat` targeting and explicit payload types. Preserve fuzzy discovery, but require exact conversation targeting before sending.

**Tech Stack:** Swift 6.1, MCP Swift SDK, Hummingbird, SQLite3, Contacts.framework, Messages AppleScript via `osascript`, XCTest

---

### Task 1: Write The Target Spec Into Code-Adjacent Tests

**Files:**
- Modify: `swift/Tests/iMessageMaxTests/PlaceholderTests.swift`
- Create: `tests/test_send_identity_model.md` if a lightweight narrative fixture is helpful during review

**Step 1: Add high-level behavior tests for the send identity model**

Add test names that codify the desired behavior:
- `test_chat_id_targets_exact_chat_not_first_participant`
- `test_send_requires_exact_target_on_ambiguity`
- `test_send_file_paths_are_validated_before_automation`
- `test_send_preserves_file_then_text_order`

**Step 2: Run tests to verify they fail or are placeholders**

Run: `cd swift && swift test --filter Send`
Expected: FAIL or no matching coverage for the new behavior

**Step 3: Commit the failing spec scaffolding**

```bash
git add swift/Tests/iMessageMaxTests/PlaceholderTests.swift
git commit -m "test: define send identity behavior expectations"
```

### Task 2: Introduce Canonical Chat Identity Types

**Files:**
- Create: `swift/Sources/iMessageMax/Models/ChatIdentity.swift`
- Modify: `swift/Sources/iMessageMax/Models/Chat.swift`
- Modify: `swift/Sources/iMessageMax/Tools/FindChat.swift`
- Modify: `swift/Sources/iMessageMax/Tools/ListChats.swift`

**Step 1: Add a minimal `ChatIdentity` model**

Define a single struct that can represent any conversation:
- `mcpId`
- `guid`
- `displayName`
- `participantCount`
- `participants`
- `isNamed`
- `aliases`

**Step 2: Add participant display helpers**

Centralize the generation of:
- contact-backed participant labels
- raw-handle fallbacks
- deterministic participant ordering
- deterministic unnamed-group labels

**Step 3: Update discovery tools to expose canonical chat identity**

Ensure `find_chat` and `list_chats` produce the same chat identity fields, even if some remain additive/backward-compatible at first.

**Step 4: Run focused tests**

Run: `cd swift && swift test --filter FindChat`
Expected: PASS for existing tests, with new failures only where response shape changed intentionally

**Step 5: Commit**

```bash
git add swift/Sources/iMessageMax/Models/ChatIdentity.swift swift/Sources/iMessageMax/Models/Chat.swift swift/Sources/iMessageMax/Tools/FindChat.swift swift/Sources/iMessageMax/Tools/ListChats.swift
git commit -m "feat: add canonical chat identity model"
```

### Task 3: Centralize Chat Resolution For Send

**Files:**
- Create: `swift/Sources/iMessageMax/Tools/SendResolution.swift`
- Modify: `swift/Sources/iMessageMax/Tools/Send.swift`
- Modify: `swift/Sources/iMessageMax/Database/QueryBuilder.swift` if helper queries belong there

**Step 1: Extract send target resolution out of `Send.swift`**

Create a small resolver that produces one of:
- `.participant(handle: String, chatId: Int?)`
- `.chat(guid: String, chatId: Int)`
- `.ambiguous(candidates: [...])`
- `.failure(error: ...)`

**Step 2: Make `chat_id` resolution return the actual chat GUID**

Use `SELECT guid, display_name FROM chat WHERE ROWID = ?` and preserve that GUID as the exact write target.

**Step 3: Keep `to` as a convenience resolver**

Rules:
- if it resolves safely to one exact single-person chat, allow send
- if it matches multiple conversations or multiple contacts, return ambiguity
- do not guess

**Step 4: Add unit tests for mixed-contact and unnamed-group cases**

Add cases for:
- named group
- unnamed two-person chat
- unnamed mixed group with one unknown number
- contact name collision

**Step 5: Run tests**

Run: `cd swift && swift test --filter Send`
Expected: PASS for resolution logic before transport changes

**Step 6: Commit**

```bash
git add swift/Sources/iMessageMax/Tools/SendResolution.swift swift/Sources/iMessageMax/Tools/Send.swift
git commit -m "refactor: centralize send target resolution"
```

### Task 4: Introduce Explicit Send Payload Types

**Files:**
- Create: `swift/Sources/iMessageMax/Models/SendPayload.swift`
- Modify: `swift/Sources/iMessageMax/Tools/Send.swift`
- Modify: `swift/Sources/iMessageMax/Utilities/AppleScript.swift`

**Step 1: Add minimal payload types**

Model:
- `.text(String)`
- `.file(path: String)`

Wrap them in a small ordered collection to preserve execution order.

**Step 2: Extend `send` input schema**

Add:
- `file_paths: [String]`

Validation rules:
- exactly one of `to` or `chat_id`
- at least one of `text` or `file_paths`
- reject empty `file_paths`

**Step 3: Define ordering**

If both are present:
- files first
- text second

Document this in tool description and tests.

**Step 4: Run tests**

Run: `cd swift && swift test --filter Send`
Expected: FAIL on AppleScript transport until Task 5 is complete

**Step 5: Commit**

```bash
git add swift/Sources/iMessageMax/Models/SendPayload.swift swift/Sources/iMessageMax/Tools/Send.swift swift/Sources/iMessageMax/Utilities/AppleScript.swift
git commit -m "feat: add explicit send payload model"
```

### Task 5: Refactor AppleScript Transport To Match The Real Messages Scripting Model

**Files:**
- Modify: `swift/Sources/iMessageMax/Utilities/AppleScript.swift`
- Test: `swift/Tests/iMessageMaxTests/PlaceholderTests.swift`

**Step 1: Replace the single `send(to:message:)` helper with explicit transport helpers**

Create:
- `sendTextToParticipant(handle:text:)`
- `sendTextToChat(guid:text:)`
- `sendFileToParticipant(handle:filePath:)`
- `sendFileToChat(guid:filePath:)`

Keep the AppleScript static and pass data via environment variables only.

**Step 2: Validate file paths before spawning `osascript`**

Reject:
- missing paths
- directories
- unreadable files

**Step 3: Normalize transport error mapping**

Map script failures to stable errors:
- `participant_not_found`
- `chat_not_found`
- `file_not_found`
- `automation_permission_required`
- `messages_app_unavailable`
- `timeout`
- `send_failed`

**Step 4: Add tests for script selection**

Assert that:
- participant targets use participant scripts
- chat targets use chat scripts
- text uses text payload path
- files use file payload path

**Step 5: Run tests**

Run: `cd swift && swift test --filter Send`
Expected: PASS for transport selection and validation

**Step 6: Commit**

```bash
git add swift/Sources/iMessageMax/Utilities/AppleScript.swift swift/Tests/iMessageMaxTests/PlaceholderTests.swift
git commit -m "refactor: align AppleScript transport with Messages chat and file sends"
```

### Task 6: Wire Send End-To-End Through Exact Conversation Identity

**Files:**
- Modify: `swift/Sources/iMessageMax/Tools/Send.swift`
- Modify: `swift/Sources/iMessageMax/Server/ToolRegistry.swift` only if registration metadata changes

**Step 1: Make `SendTool` operate on resolved targets and payload lists**

Execution flow:
1. validate input
2. resolve exact target
3. build ordered payloads
4. dispatch each payload through the explicit AppleScript transport
5. return a stable response

**Step 2: Update response shape conservatively**

Keep existing keys where possible:
- `success`
- `chat_id`
- `delivered_to`
- `timestamp`

Add only if needed:
- `sent_payload_count`
- `sent_file_count`

**Step 3: Remove misleading behavior**

Do not:
- silently send group messages to first participant
- accept `reply_to` as a future promise without warning

Either:
- remove `reply_to` from schema now, or
- keep it and return explicit `unsupported_feature`

**Step 4: Run tests**

Run: `cd swift && swift test --filter Send`
Expected: PASS

**Step 5: Commit**

```bash
git add swift/Sources/iMessageMax/Tools/Send.swift
git commit -m "feat: send through exact chat identity and ordered payloads"
```

### Task 7: Add Capability Reporting For LLM Ergonomics

**Files:**
- Modify: `swift/Sources/iMessageMax/Tools/Diagnose.swift`
- Modify: `README.md`

**Step 1: Add a capability block to diagnose output**

Report at least:
- `send_text_to_participant`
- `send_text_to_chat`
- `send_file_to_participant`
- `send_file_to_chat`
- `reply_to_supported`
- `tapback_supported`
- `edit_unsend_supported`

Set unsupported advanced features explicitly to `false`.

**Step 2: Update README to match reality**

Document:
- exact group send support
- file/image send support
- unsupported advanced actions
- deterministic ordering when files and text are both provided

**Step 3: Run tests**

Run: `cd swift && swift test`
Expected: PASS

**Step 4: Commit**

```bash
git add swift/Sources/iMessageMax/Tools/Diagnose.swift README.md
git commit -m "docs: report supported send capabilities explicitly"
```

### Task 8: Add Real-World Integration Coverage For Safe Manual Validation

**Files:**
- Create: `swift/Tests/iMessageMaxTests/SendManualValidation.md`
- Modify: `tests/integration/test_real_database.py` only if Python-side notes or fixtures are still useful

**Step 1: Write a manual validation checklist**

Cover:
- send text to one-person chat
- send text to named group chat
- send text to unnamed mixed group
- send one image to one-person chat
- send one image to named group chat
- send image plus text in one call
- missing file behavior
- permissions missing behavior

**Step 2: Add optional integration harness if practical**

Keep it opt-in and never enabled in CI by default.

**Step 3: Run unit test suite**

Run: `cd swift && swift test`
Expected: PASS

**Step 4: Commit**

```bash
git add swift/Tests/iMessageMaxTests/SendManualValidation.md tests/integration/test_real_database.py
git commit -m "test: add manual validation plan for send scenarios"
```

### Task 9: Final Verification And Cleanup

**Files:**
- Review all touched files

**Step 1: Run formatting and test verification**

Run:
```bash
cd swift && swift test
```

Expected: PASS

**Step 2: Smoke-check the binary help output**

Run:
```bash
cd swift && swift run imessage-max --help
```

Expected: CLI help prints successfully

**Step 3: Review docs for truthfulness**

Ensure README and tool descriptions do not claim support beyond the implemented public scripting path.

**Step 4: Final commit**

```bash
git add README.md swift/
git commit -m "feat: refactor chat identity and send core for reliable group and file delivery"
```

## Notes For Implementation

- Prefer additive response changes unless an existing field is actively misleading.
- Keep `chat_id` as the MCP-facing stable identifier and `chat.guid` as the Messages-facing transport identifier.
- Never introduce UI scripting into the primary path for this feature set.
- Never silently degrade a failed group-chat resolution into a participant send.
- Keep AppleScript templates static and feed values via environment variables.
- Preserve the project’s intent-aligned UX: fuzzy discovery, exact send.

## Suggested Execution Order

1. Task 2
2. Task 3
3. Task 4
4. Task 5
5. Task 6
6. Task 7
7. Task 8
8. Task 9

Task 1 can be done first or folded into Task 3 if the current Swift test layout makes earlier scaffolding awkward.

Plan complete and saved to `docs/plans/2026-03-13-chat-identity-and-send-refactor-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

**Which approach?**
