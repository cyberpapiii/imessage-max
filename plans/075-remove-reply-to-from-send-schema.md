# 075: Remove `reply_to` from the `send` schema

Planned at commit `639529e` on 2026-09-01. Baseline: `cd swift && swift build && swift test` passes with 370 tests, 0 failures.

## Executor instructions

Read this whole file before touching anything. Then run the drift check below. If any line of the drift check disagrees with what this plan quotes, stop and report the difference instead of adapting on the fly. The plan was written against a specific tree and the executor is not expected to re-derive intent.

### Drift check

```bash
cd /Users/robdezendorf/Documents/GitHub/imessage-max
git rev-parse --short HEAD                                # expect 639529e or a descendant of it
grep -n '"reply_to"' swift/Sources/iMessageMax/Tools/Send.swift   # expect exactly two hits: :277 and :301
grep -n 'replyTo' swift/Sources/iMessageMax/Tools/Send.swift       # expect :301, :308, :327, :335
grep -n 'reply_to is not yet implemented' swift/Sources/iMessageMax/Tools/Send.swift swift/Tests/iMessageMaxTests/SendToolExecuteTests.swift
# expect Send.swift:336 and SendToolExecuteTests.swift:672
grep -n 'reply_threading' swift/Sources/iMessageMax/Tools/Diagnose.swift   # expect :282 with state "unsupported"
```

If `git rev-parse` shows a commit that is not a descendant of `639529e`, or any grep returns a different set of hits, stop.

## Status

- Priority: P3
- Size: S
- Kind: direction (cleanup, no new behavior)
- Depends on: nothing
- Blocks: nothing

## Why

The `send` tool advertises a `reply_to` parameter that has never worked. Every caller who reads the schema sees an input that the tool immediately rejects. The schema line and the guard are both in `swift/Sources/iMessageMax/Tools/Send.swift`:

```swift
// Send.swift:277
"reply_to": .string(description: "Message ID to reply to (not yet implemented)"),
```

```swift
// Send.swift:334-337
        // reply_to is not yet implemented
        if replyTo != nil {
            return .error("reply_to is not yet implemented")
        }
```

An input that is documented, accepted by the schema, and then rejected at runtime is a trap for model callers. They pay a round trip to learn what the schema could have told them. Removing the key from the schema makes the tool honest: the schema is the contract, and threading is simply absent from it.

The `diagnose` capability `reply_threading: unsupported` stays. That is the correct place to advertise the absence, and three contract tests already pin it:

```swift
// Diagnose.swift:282
"reply_threading": Capability(state: "unsupported"),
```

`CapabilityContractTests.swift:64` and `:134` and `ResponseContractTests.swift:205` all assert the same `unsupported` state. None of them mention the send schema, so this plan does not touch them.

The only realistic implementation path for reply threading is the IMCore helper on branches `advisor/018-imcore-helper-bridge` and `advisor/019-imcore-helper-dylib`. Those branches are frozen and out of scope here. If threading ever lands, it will re-add a parameter with real semantics under a new plan; nothing in this plan forecloses that.

## Current state

### Schema and argument plumbing

`Send.swift:277` declares the key. `Send.swift:301` reads it, `:308` passes it into `execute`, `:327` declares the parameter on the signature, and `:334-337` reject it. There are no other readers of `replyTo` in `swift/Sources`.

### The rejection test

```swift
// swift/Tests/iMessageMaxTests/SendToolExecuteTests.swift:658-675
final class SendToolExecutionTests: XCTestCase {
    func testExecuteRejectsReplyToBeforeAttemptingSend() async throws {
        let tool = SendTool(
            db: Database(path: "/tmp/nonexistent.sqlite"),
            resolver: ContactResolver(seedCache: [:])
        )
        ...
        XCTAssertTrue(payload.contains("reply_to is not yet implemented"))
    }
}
```

The test exists to prove the guard fires before the tool touches the database. Once the guard is gone the test is meaningless. It is converted, not deleted: the replacement asserts that the registered send schema has no `reply_to` property, which is the invariant this plan actually creates.

### Documentation that mentions the parameter

| File | Line | Text |
|------|------|------|
| `README.md` | 347 | `- \`reply_to\` is currently unsupported` |
| `swift/Tests/iMessageMaxTests/SendManualValidation.md` | 102-117 | `### 6. Unsupported reply-to` manual check |
| `docs/validation/2026-04-09-release-checklist.md` | 111 | reply-to rejection line in the release checklist |
| `docs/validation/2026-03-13-send-manual-validation.md` | 151, 158 | historical validation log |
| `docs/plans/2026-06-11-capability-contract-design.md` | 114 | design note tying `reply_threading` to the parameter |
| `docs/plans/2026-03-13-chat-identity-and-send-refactor-plan.md` | 258-289 | original design of the placeholder |

Only the first three are living documents. The `docs/plans` and dated `docs/validation` files are historical records and are left alone; rewriting history to match today's schema would make the record less useful, not more.

`using-imessage-max/SKILL.md` and `using-imessage-max/references/workflows.md` were grepped for `reply_to` and `reply-to` and contain no mention. Nothing to change there.

### What pins the schema shape

`swift/Tests/iMessageMaxTests/ToolRegistryTests.swift:28` lists the tool name `send` and nothing about its properties. `docs/conformance-baseline.yml` has no send-schema entry. No test currently asserts the property list of the send schema in either direction, which is why the converted test below is new coverage rather than an edit.

## Commands

| Purpose | Command | Expect |
|---------|---------|--------|
| Build | `cd swift && swift build` | `Build complete!` |
| Full suite | `cd swift && swift test` | `Executed 370 tests, with 0 failures` before; 370 after (one test replaced one-for-one) |
| Only send execution tests | `cd swift && swift test --filter SendToolExecutionTests` | 1 test, 0 failures |
| No leftover mentions in source | `grep -rn 'reply_to\|replyTo' swift/Sources` | no output |
| Contract tests untouched | `cd swift && swift test --filter 'CapabilityContractTests\|ResponseContractTests'` | 0 failures |

## Scope

### In

- Remove the `reply_to` schema property from `Send.swift:277`.
- Remove the `replyTo` read at `:301`, the call-site argument at `:308`, the signature parameter at `:327`, and the guard at `:334-337`.
- Replace `testExecuteRejectsReplyToBeforeAttemptingSend` with `testSendSchemaDoesNotAdvertiseReplyTo`.
- Delete the `README.md:347` bullet.
- Delete `### 6. Unsupported reply-to` from `SendManualValidation.md` and renumber nothing (section numbers there are labels, gaps are acceptable; note the gap in a one-line comment).
- Drop the reply-to line from `docs/validation/2026-04-09-release-checklist.md:111`.

### Out

- `reply_threading` in `Diagnose.swift` and the three contract tests that pin it. They stay as-is.
- Historical docs under `docs/plans/` and `docs/validation/2026-03-13-*`.
- Any implementation of threading. The IMCore branches are the only viable path and are frozen.
- `docs/conformance-baseline.yml` and the response contract tests: the send response shape does not change.

## Git workflow

```bash
git checkout main && git pull --ff-only
git checkout -b advisor/075-remove-reply-to-from-send-schema
```

Conventional commits, one per logical step:

1. `test: pin send schema without reply_to`
2. `refactor: remove unimplemented reply_to from send`
3. `docs: drop reply_to from send docs and manual validation`

The executor does not push and does not merge. Leave the branch for the advisor to review.

Standing rules: never add `Task.sleep` under `swift/Sources` (enforced by `LaunchdSafetyTests`); never touch `.mcp.json`; never commit secrets; leave `advisor/018-imcore-helper-bridge` and `advisor/019-imcore-helper-dylib` alone.

## Steps

### Step 1: Write the replacement test first

Edit `swift/Tests/iMessageMaxTests/SendToolExecuteTests.swift`. Replace the body of `SendToolExecutionTests` (lines 658-675) with a test that registers the tool on a throwaway `Server`, lists tools, finds `send`, and asserts its `inputSchema.properties` has no `reply_to` key. Use whatever helper `ToolRegistryTests.swift` already uses to enumerate registered tools; do not invent a new registration path. Keep `decodeToolErrorText(_:)` only if another test in the file uses it; otherwise remove it in the same edit.

Verify (expect a failure, because the schema still advertises the key):

```bash
cd swift && swift test --filter SendToolExecutionTests
# expect: 1 test, 1 failure, message names reply_to
```

Commit: `test: pin send schema without reply_to`.

### Step 2: Remove the schema key and the plumbing

In `Send.swift`:

- Delete line 277.
- Delete the `let replyTo = ...` at line 301.
- Delete `replyTo: replyTo` from the call at line 308.
- Delete `replyTo: String?` from the signature at line 327.
- Delete the comment and guard at lines 334-337.

Verify:

```bash
grep -rn 'reply_to\|replyTo' swift/Sources     # expect no output
cd swift && swift build                         # expect Build complete!
cd swift && swift test --filter SendToolExecutionTests   # expect 1 test, 0 failures
cd swift && swift test                          # expect Executed 370 tests, with 0 failures
```

Commit: `refactor: remove unimplemented reply_to from send`.

### Step 3: Documentation

- `README.md:347`: delete the bullet. Re-read lines 340-356 afterward to make sure the surrounding "send result semantics" list still reads as a complete list.
- `SendManualValidation.md:102-117`: delete the section. Add one line where it was: `<!-- Section 6 removed with plan 075; reply_to is no longer a send parameter. -->`
- `docs/validation/2026-04-09-release-checklist.md:111`: delete the line.

Verify:

```bash
grep -rn 'reply_to\|reply-to' README.md swift/Tests/iMessageMaxTests/SendManualValidation.md docs/validation/2026-04-09-release-checklist.md using-imessage-max
# expect no output
```

Commit: `docs: drop reply_to from send docs and manual validation`.

## Test plan

- New: `testSendSchemaDoesNotAdvertiseReplyTo` fails before Step 2 and passes after.
- Unchanged: `CapabilityContractTests`, `ResponseContractTests`, `ToolRegistryTests`, `LaunchdSafetyTests` all still pass.
- Total test count stays at 370 (one removed, one added).

## Done criteria

- `grep -rn 'reply_to\|replyTo' swift/Sources` prints nothing.
- Full suite: 370 tests, 0 failures.
- `diagnose` still reports `reply_threading: unsupported` (covered by the untouched contract tests).
- The three living docs no longer mention the parameter.
- Three commits on `advisor/075-remove-reply-to-from-send-schema`, not pushed.

## STOP conditions

- Drift check fails.
- `grep -rn replyTo swift/Sources` shows a reader outside `Send.swift`. Stop and report; the plan assumed one file.
- Any contract test fails after Step 2. That would mean a test pinned the send schema property list somewhere this plan did not find; report which one.
- The test count after Step 2 is anything other than 370.
- You find yourself wanting to touch `Diagnose.swift`. Don't.

## Maintenance notes

- If reply threading is ever implemented, it must come back as a new parameter with a new plan, tests that exercise a real thread, and a flip of `reply_threading` to `supported` in `Diagnose.swift` plus the three contract tests that pin it.
- The converted schema test is cheap insurance against someone re-adding a placeholder key. Keep it.
