# Plan 021: Report failed deliveries as `failed_delivery` instead of `uncertain`

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report, do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat e3d14da..HEAD -- swift/Sources/iMessageMax/Tools/SendVerifier.swift swift/Sources/iMessageMax/Tools/Send.swift swift/Tests/iMessageMaxTests/SendVerifierTests.swift swift/Tests/iMessageMaxTests/SendToolExecuteTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED (client-visible status vocabulary change)
- **Depends on**: none (plan 023 touches `Send.swift` error strings, land this first if both are selected)
- **Category**: bug
- **Planned at**: commit `e3d14da`, 2026-08-07

## Why this matters

When an iMessage send fails, Messages writes the row to chat.db
**immediately** with `error = 22` (measured; documented in the verifier's own
comment). But both verifier queries filter `AND m.error = 0`, so the failed
row is invisible, verification exhausts its polling window, and the tool
returns `status: "uncertain"` with the message "The message was probably
sent... Use get_messages to confirm." That is factually wrong for a hard
failure: the agent (and user) is told to follow up on a send the database
already knows failed. This is the highest-stakes path in the server, the
only write operation, and two existing tests currently lock in the wrong
answer. STRATEGY.md names "verified send rate" a key metric; false
`uncertain` results are exactly what this plan removes. The prior audit
recorded this as a known refinement (plans/README.md "Direction findings");
this plan implements it.

## Current state

Files and roles:

- `swift/Sources/iMessageMax/Tools/SendVerifier.swift`, post-send chat.db
  polling verifier. The result enum, the two scans, and the polling loop.
- `swift/Sources/iMessageMax/Tools/Send.swift`, the send tool. Maps
  `VerificationResult` → `SendResponse` statuses; holds the tool description
  ("proof vocabulary") and the response constructors.
- `swift/Tests/iMessageMaxTests/SendVerifierTests.swift`, verifier unit
  tests against a fixture DB; test 2 asserts today's wrong behavior.
- `swift/Tests/iMessageMaxTests/SendToolExecuteTests.swift`, end-to-end tool
  tests with `StubScriptRunner`; `testFailedRowDoesNotConfirm` asserts
  `"uncertain"` for an error=22 row.
- Docs that state the status vocabulary and must move in lockstep:
  `CONCEPTS.md` ("Send statuses"), `README.md:341-348`,
  `using-imessage-max/SKILL.md:63`,
  `using-imessage-max/references/workflows.md:77`.

The result enum (`SendVerifier.swift:7-14`):

```swift
enum VerificationResult: Equatable {
    /// Row found in the intended chat within the polling window, with error = 0.
    case confirmed(guid: String, dateNs: Int64)
    /// Row found in a different chat (routing mismatch). Includes the message guid.
    case mismatch(actualChatId: Int64, guid: String)
    /// Polling window exhausted; no matching row found.
    case notFound
}
```

The polling loop (`SendVerifier.swift:65-97`), scans return
`VerificationResult?`, non-nil short-circuits:

```swift
        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                await AsyncTimeout.sleep(pollInterval)
            }

            // 1. Primary: look in the intended chat (if we have a chatId).
            if let chatId = intendedChatId {
                if let result = try primaryScan(
                    chatId: chatId, lowerBound: lowerBound,
                    upperBound: upperBound, expectedText: normalizedExpected
                ) {
                    return result
                }
            }

            // 2. Fallback: scan by handle (when primary found nothing and handle available).
            if let handle {
                if let result = try fallbackScan(
                    handle: handle, intendedChatId: intendedChatId,
                    lowerBound: lowerBound, upperBound: upperBound,
                    expectedText: normalizedExpected
                ) {
                    return result
                }
            }
        }

        return .notFound
```

The primary query (`SendVerifier.swift:114-127`), note `AND m.error = 0`
and no `LIMIT`; the fallback query (`:160-176`) has the same filter. The
primary match loop (`:137-142`):

```swift
        for row in rows {
            if textMatches(row: row, expected: expectedText) {
                return .confirmed(guid: row.guid, dateNs: row.dateNs)
            }
        }
        return nil
```

The fallback match loop (`:187-200`), mismatch when the matching row's chat
differs from intended:

```swift
        for row in rows {
            guard textMatches(row: MessageRow(
                guid: row.guid, dateNs: row.dateNs,
                text: row.text, attributedBody: row.attributedBody
            ), expected: expectedText) else { continue }

            if let intended = intendedChatId, row.chatId != intended {
                return .mismatch(actualChatId: row.chatId, guid: row.guid)
            }
            return .confirmed(guid: row.guid, dateNs: row.dateNs)
        }
        return nil
```

The tool-side mapping (`Send.swift:403-414`):

```swift
            switch verification {
            case .confirmed(let guid, _):
                return .confirmed(guid: guid, deliveredTo: resolved.deliveredTo, chat: resolved.chat)
            case .mismatch(let actualChatId, _):
                return .mismatch(
                    intendedChat: resolved.chat,
                    actualChatId: actualChatId,
                    deliveredTo: resolved.deliveredTo
                )
            case .notFound:
                return .uncertain(deliveredTo: resolved.deliveredTo, chat: resolved.chat)
            }
```

The error-throw rule (`Send.swift:270-272`):

```swift
        if response.status == "failed" || response.status == "ambiguous" {
            throw ToolError(content: content)
        }
```

The proof vocabulary in the tool description (`Send.swift:220-225`) lists
`confirmed / uncertain / mismatch / sent`.

Response constructors live in `Send.swift:70-181`, model the new one on
`static func mismatch(...)` (`:113-128`), which sets a `message`, and on
`confirmed` (`:73-88`), which carries `verifiedMessageGuid`/`verifiedAt`.

Tests asserting today's behavior:

- `SendVerifierTests.swift:62-82` `testErrorRowDoesNotConfirm`, inserts an
  error=22 row, asserts `result == .notFound`.
- `SendToolExecuteTests.swift:274-301` `testFailedRowDoesNotConfirm`,
  end-to-end, asserts `json["status"] == "uncertain"`.

Fixture API (already supports error rows): `fixture.insertMessage(rowId:guid:text:date:isFromMe:error:isSent:)`, see `SendVerifierTests.swift:66-69`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| Verifier tests | `cd swift && swift test --filter SendVerifierTests` | all pass |
| Tool tests | `cd swift && swift test --filter SendToolExecuteTests` | all pass |
| Full suite | `cd swift && swift test` | exit 0, 0 failures |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Tools/SendVerifier.swift`
- `swift/Sources/iMessageMax/Tools/Send.swift`
- `swift/Tests/iMessageMaxTests/SendVerifierTests.swift`
- `swift/Tests/iMessageMaxTests/SendToolExecuteTests.swift`
- `CONCEPTS.md`, `README.md`, `using-imessage-max/SKILL.md`,
  `using-imessage-max/references/workflows.md` (vocabulary lockstep, one
  entry/line each)
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):
- `swift/Sources/iMessageMax/Tools/SendResolution.swift`, resolution is
  upstream of verification; plan 033 owns its changes.
- `swift/Sources/iMessageMax/Utilities/AppleScript.swift`, transport layer;
  plans 024/025 own it.
- The `pending_confirmation` file-transfer states, unchanged by design.
- `swift/Sources/iMessageMax/Utilities/MessageTextExtractor.swift`, plan 031.

## Git workflow

- Branch: `advisor/021-failed-delivery-send-status`
- Conventional commits, e.g. `feat: classify error rows as failed_delivery in send verification`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Extend `VerificationResult`

Add a case to the enum (`SendVerifier.swift:7-14`):

```swift
    /// Row found in the intended chat, but with error ≠ 0 — the delivery failed.
    case failedDelivery(guid: String, errorCode: Int)
```

Update the doc comment block at `:18-26` to describe the new classification
(replace the sentence "rows with error ≠ 0 must not confirm" with "rows with
error ≠ 0 must not confirm, they classify as `.failedDelivery` when they
match in the intended chat").

**Verify**: `cd swift && swift build` → compiler errors only at the
non-exhaustive `switch` in `Send.swift` (expected; fixed in step 4).

### Step 2: Select the error column and classify in both scans

In **both** queries (`:114-127` primary, `:160-176` fallback):

- Add `m.error` to the SELECT list (after `m.attributedBody`).
- Remove the line `AND m.error = 0`.
- Add `LIMIT 200` after `ORDER BY m.date ASC` (safety bound; the window is
  62 seconds of one sender's messages, so this changes nothing in practice).

Add `let error: Int64` to both `MessageRow` and `FallbackRow`, bound from
`row.int(4)` (primary) / `row.int(5)` (fallback).

Rewrite the primary match loop (`:137-142`) with **confirmed-first**
precedence, a clean matching row anywhere in the window wins over a failed
one (covers Messages' own immediate-retry behavior):

```swift
        var failedMatch: MessageRow? = nil
        for row in rows {
            guard textMatches(row: row, expected: expectedText) else { continue }
            if row.error == 0 {
                return .confirmed(guid: row.guid, dateNs: row.dateNs)
            }
            if failedMatch == nil { failedMatch = row }
        }
        if let failed = failedMatch {
            return .failedDelivery(guid: failed.guid, errorCode: Int(failed.error))
        }
        return nil
```

Rewrite the fallback match loop (`:187-200`) with the same precedence, and
keep failed rows in *other* chats invisible (mismatch fires only on clean
rows, exactly as today):

```swift
        var failedMatch: FallbackRow? = nil
        for row in rows {
            guard textMatches(row: MessageRow(
                guid: row.guid, dateNs: row.dateNs,
                text: row.text, attributedBody: row.attributedBody, error: row.error
            ), expected: expectedText) else { continue }

            if let intended = intendedChatId, row.chatId != intended {
                if row.error == 0 {
                    return .mismatch(actualChatId: row.chatId, guid: row.guid)
                }
                continue  // failed row in a different chat: invisible, as before
            }
            if row.error == 0 {
                return .confirmed(guid: row.guid, dateNs: row.dateNs)
            }
            if failedMatch == nil { failedMatch = row }
        }
        if let failed = failedMatch {
            return .failedDelivery(guid: failed.guid, errorCode: Int(failed.error))
        }
        return nil
```

(Adjust the `MessageRow` construction for the new `error` field.)

### Step 3: Keep polling before settling on `failedDelivery`

A failed row is written immediately, but a clean row from the same send may
still appear on a later poll. In `verify()` (`:65-97`), remember a
`failedDelivery` result instead of returning it, and only surface it after
the polling window closes:

```swift
        var pendingFailure: VerificationResult? = nil

        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                await AsyncTimeout.sleep(pollInterval)
            }

            if let chatId = intendedChatId {
                if let result = try primaryScan(
                    chatId: chatId, lowerBound: lowerBound,
                    upperBound: upperBound, expectedText: normalizedExpected
                ) {
                    if case .failedDelivery = result {
                        pendingFailure = result
                    } else {
                        return result
                    }
                }
            }

            if let handle {
                if let result = try fallbackScan(
                    handle: handle, intendedChatId: intendedChatId,
                    lowerBound: lowerBound, upperBound: upperBound,
                    expectedText: normalizedExpected
                ) {
                    if case .failedDelivery = result {
                        if pendingFailure == nil { pendingFailure = result }
                    } else {
                        return result
                    }
                }
            }
        }

        return pendingFailure ?? .notFound
```

**Verify**: `cd swift && swift build` → only the `Send.swift` switch error remains.

### Step 4: Map the new result in the tool

1. Add a response constructor in `Send.swift` next to `mismatch` (`:113-128`),
   following its exact field pattern:

```swift
    /// Row found in the intended chat with error ≠ 0 — delivery failed (verified).
    static func failedDelivery(guid: String, errorCode: Int, deliveredTo: [String], chat: ChatReference?) -> SendResponse {
        SendResponse(
            status: "failed_delivery",
            timestamp: TimeUtils.formatISO(Date()),
            chat: chat,
            deliveredTo: deliveredTo,
            chatId: chat?.id,
            message: "Messages.app accepted the send but chat.db recorded a delivery failure (error \(errorCode)). The message was NOT delivered. Do not tell the user it was sent; check the destination can receive iMessages and consider resending.",
            error: nil,
            candidates: nil,
            verifiedMessageGuid: guid,
            verifiedAt: TimeUtils.formatISO(Date()),
            intendedChat: nil,
            actualChatId: nil
        )
    }
```

2. Add the switch case in the verification mapping (`:403-414`):

```swift
            case .failedDelivery(let guid, let errorCode):
                return .failedDelivery(
                    guid: guid, errorCode: errorCode,
                    deliveredTo: resolved.deliveredTo, chat: resolved.chat
                )
```

3. Make the tool surface it as an error result, extend `:270-272`:

```swift
        if response.status == "failed" || response.status == "ambiguous"
            || response.status == "failed_delivery" {
            throw ToolError(content: content)
        }
```

4. Add one line to the proof vocabulary in the tool description (`:220-225`):

```
                  failed_delivery — row found with a delivery error recorded; the message was NOT delivered.
```

**Verify**: `cd swift && swift build` → exit 0.

### Step 5: Re-point the two locked-in tests, add new ones

1. `SendVerifierTests.swift` `testErrorRowDoesNotConfirm` (`:62-82`): rename
   to `testErrorRowClassifiesAsFailedDelivery`; assert
   `result == .failedDelivery(guid: "msg-guid-error", errorCode: 22)`.
2. `SendToolExecuteTests.swift` `testFailedRowDoesNotConfirm` (`:274-301`):
   rename to `testFailedRowReturnsFailedDeliveryStatus`. The call now throws
   `ToolError`; follow the do/catch pattern already used at `:317-…` in the
   same file, decode the thrown error's content, and assert
   `json["status"] == "failed_delivery"` and
   `json["verified_message_guid"] as? String == "msg-guid-error-row"`
   (check the actual JSON key casing against a `confirmed` response, the
   encoder converts to snake_case; mirror whatever
   `testConfirmedSend...` in this file asserts for `verifiedMessageGuid`).
3. New `SendVerifierTests` cases (model on the existing fixture setup at `:40-58`):
   - **Failed then clean row → confirmed**: insert error=22 row and error=0
     row, both matching, both in window, in the intended chat; expect
     `.confirmed` with the clean row's guid.
   - **Failed row in a different chat, intended chat set → notFound**:
     insert only an error=22 matching row joined to chat 2 while intending
     chat 1 (handle-joined to both); expect `.notFound` (failed cross-chat
     rows stay invisible).
   - **Fallback failed row, no intended chat → failedDelivery**: intendedChatId
     nil, handle set, one error=22 matching row; expect `.failedDelivery`.

**Verify**: `cd swift && swift test --filter SendVerifierTests` and
`--filter SendToolExecuteTests` → all pass, including 3 new tests.

### Step 6: Vocabulary lockstep

One edit each, add `failed_delivery` alongside the existing statuses:

- `CONCEPTS.md` "Send statuses" section (after **mismatch**):
  `- **failed_delivery**: Verification found the sent message recorded with a delivery error; the message did not deliver. Treated as a failure, with the message id and error code as evidence.`
- `README.md:341-348` status list: add the equivalent bullet.
- `using-imessage-max/SKILL.md:63`: extend the status sentence with
  `` `failed_delivery` means chat.db recorded a delivery error, the message did not send; tell the user and consider the destination unreachable ``.
- `using-imessage-max/references/workflows.md:77`: add `failed_delivery` to
  the parenthesized status list.

**Verify**: `grep -rn "failed_delivery" CONCEPTS.md README.md using-imessage-max/` → 4+ matches.

### Step 7: Full suite

**Verify**: `cd swift && swift test` → exit 0, 0 failures.

## Test plan

Covered in step 5: two re-pointed tests + three new verifier tests. Pattern
exemplars: `SendVerifierTests.swift:40-58` (fixture setup),
`SendToolExecuteTests.swift:274-301` (end-to-end with `StubScriptRunner`).

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` exits 0; 0 failures; ≥3 net-new tests
- [ ] `grep -n "m.error = 0" swift/Sources/iMessageMax/Tools/SendVerifier.swift` → no matches
- [ ] `grep -c "failed_delivery" swift/Sources/iMessageMax/Tools/Send.swift` ≥ 3 (constructor, throw rule, description)
- [ ] `grep -rn "failed_delivery" CONCEPTS.md README.md using-imessage-max/` → ≥4 matches
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The excerpts above don't match the live code (drift).
- The fixture's `insertMessage` does not accept an `error:` parameter, the
  test schema has drifted; report rather than modifying `ToolTestDatabase`.
- Existing `SendContractTests` fail in a way that isn't the deliberate
  vocabulary addition (they may assert the closed set of statuses, if so,
  adding `failed_delivery` to their expected set is in scope; anything more
  is not).
- You find yourself wanting to change `mismatch` precedence or the polling
  window constants, out of scope, report instead.

## Maintenance notes

- **Live validation is an operator action**: a real failed send (e.g. to a
  known non-iMessage number with iMessage-only forced, or in airplane mode)
  should be run once after deploy, per
  `swift/Tests/iMessageMaxTests/SendManualValidation.md`; add a row there.
- Error code 22 is the *measured* failure code; the plan deliberately
  classifies **any** nonzero error as `failed_delivery` and reports the code
  verbatim, so unknown codes degrade gracefully.
- Plan 026 (partial multi-payload sends) builds on this status vocabulary,
  land 021 first.
- Reviewer should scrutinize: precedence rules (clean row beats failed row;
  cross-chat failed rows invisible) and that `uncertain` still results when
  no row matches at all.
