# Plan 026: Report partial multi-payload send failures truthfully

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report, do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat e3d14da..HEAD -- swift/Sources/iMessageMax/Tools/Send.swift swift/Tests/iMessageMaxTests/SendToolExecuteTests.swift`
> Plans 021, 023, and 025 edit these files first, so expect shifted line
> numbers, match on code shapes. In particular, after plan 025 the
> `payloads.map` blocks become sequential `for` loops with `await`; this plan
> builds on that shape. If the results-handling shape differs from BOTH the
> `e3d14da` excerpt and 025's specified replacement, STOP.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: MED (client-visible status vocabulary change on the send path)
- **Depends on**: 021 (status vocabulary + docs sections this plan extends),
  025 (the loop shape this plan modifies)
- **Category**: bug
- **Planned at**: commit `e3d14da`, 2026-08-07

## Why this matters

`send` accepts multiple payloads per call, a text plus one or more files
(`SendPayload.build(text:filePaths:)`). Payloads are sent sequentially, but
failure handling pretends the call was atomic: on the first hard failure it
returns `status: "failed"` with only that error. If payload 1 (the text)
already went out and payload 2 (a file) failed, the agent is told the send
*failed*, no mention that a message already reached the recipient. The
predictable agent behavior is a retry, which duplicates the text the human
already received. On the only write path in the server, the response must
state exactly what was and wasn't delivered, same "send truth" principle as
plans 017 and 021.

## Current state

`swift/Sources/iMessageMax/Tools/Send.swift`. Payload construction
(`:296-302`; `SendPayload` is `enum SendPayload { case text(String), case file(String) }`
in `swift/Sources/iMessageMax/Models/SendPayload.swift`, order is text
first, then files, as built):

```swift
        let payloads: [SendPayload]
        switch SendPayload.build(text: text, filePaths: filePaths) {
        case .success(let built):
            payloads = built
        case .failure(let message):
            return .error(message)
        }
```

The send loop: at `e3d14da` it is `payloads.map { ... }` (`:330-350`); after
plan 025 it is a sequential `for payload in payloads` loop appending to
`var sendResults: [Result<Void, SendError>]`. **Important existing behavior
this plan changes**: at `e3d14da` the `map` sends ALL payloads even after
one fails; the failure is only detected afterwards. Preserve whichever
send-everything vs stop-at-failure behavior plan 025 left in place, see
Step 1's decision.

The results handling (`:352-370` at `e3d14da`):

```swift
        var pendingMessages: [String] = []
        for result in sendResults {
            if case .failure(let error) = result {
                switch error {
                case .transferPending, .transferStatusUnknown:
                    pendingMessages.append(error.localizedDescription)
                default:
                    return .error(error.localizedDescription)
                }
            }
        }

        if !pendingMessages.isEmpty {
            return .pending(
                pendingMessages.joined(separator: " "),
                deliveredTo: resolved.deliveredTo,
                chat: resolved.chat
            )
        }
```

`SendResponse.error(_:)` (`:149-164`) produces `status: "failed"` with only
an `error` string. The error-throw rule in `execute` (after plan 021):
statuses `"failed"`, `"ambiguous"`, `"failed_delivery"` throw `ToolError`.

Test stub (`swift/Tests/iMessageMaxTests/SendToolExecuteTests.swift:11-48`):
`StubScriptRunner` records `invocations` and returns a single shared
`nextResult` for every call, it cannot express "payload 1 succeeds,
payload 2 fails" yet.

Docs stating the status vocabulary (extended by plan 021; this plan adds one
more entry to each): `CONCEPTS.md` "Send statuses", `README.md:341-348`
status list, `using-imessage-max/SKILL.md:63`,
`using-imessage-max/references/workflows.md:77`, and the proof-vocabulary
block in the `send` tool description (`Send.swift:220-225` at `e3d14da`).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| Send tests | `cd swift && swift test --filter SendToolExecuteTests` | all pass |
| Full suite | `cd swift && swift test` | exit 0, 0 failures |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Tools/Send.swift`
- `swift/Tests/iMessageMaxTests/SendToolExecuteTests.swift`
- `CONCEPTS.md`, `README.md`, `using-imessage-max/SKILL.md`,
  `using-imessage-max/references/workflows.md` (one vocabulary entry each)
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):
- `SendPayload.build` validation or payload ordering.
- `SendVerifier` and the verification mapping (021 owns it), partial
  failures return before verification, by design (see Step 2).
- The `pending_confirmation` accumulation for file transfers, unchanged.
- Retry logic. This plan is about *reporting*, not recovery.

## Git workflow

- Branch: `advisor/026-partial-send-reporting`
- Conventional commits, e.g. `fix: report partial multi-payload send failures instead of a blanket "failed"`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Stop sending after the first hard failure

In the send loop (post-025 `for` loop shape), break out on the first hard
failure, continuing to fire later payloads after one failed produces
out-of-order conversations and compounds the reporting problem:

```swift
        var sendResults: [Result<Void, SendError>] = []
        payloadLoop: for payload in payloads {
            let result: Result<Void, SendError>
            ... (existing per-payload dispatch, unchanged)
            sendResults.append(result)
            if case .failure(let error) = result {
                switch error {
                case .transferPending, .transferStatusUnknown:
                    break  // soft outcome; keep sending
                default:
                    break payloadLoop
                }
            }
        }
```

(If plan 025 landed with the map shape unchanged for some reason, apply the
same early-exit inside a `for` loop conversion here.)

### Step 2: Classify the aggregate outcome

Replace the results-handling block so it distinguishes three cases:

```swift
        var pendingMessages: [String] = []
        var hardFailure: (index: Int, error: SendError)? = nil
        for (index, result) in sendResults.enumerated() {
            if case .failure(let error) = result {
                switch error {
                case .transferPending, .transferStatusUnknown:
                    pendingMessages.append(error.localizedDescription)
                default:
                    hardFailure = (index, error)
                }
            }
        }

        if let failure = hardFailure {
            let sentCount = failure.index  // payloads before the failing one were dispatched
            if sentCount == 0 {
                return .error(failure.error.localizedDescription)  // nothing sent: plain "failed", as today
            }
            return .partialFailure(
                sentDescriptions: payloads.prefix(sentCount).map { describePayload($0) },
                failedDescription: describePayload(payloads[failure.index]),
                error: failure.error.localizedDescription,
                deliveredTo: resolved.deliveredTo,
                chat: resolved.chat
            )
        }
```

with a small local helper:

```swift
        func describePayload(_ payload: SendPayload) -> String {
            switch payload {
            case .text: return "text message"
            case .file(let path): return "file '\((path as NSString).lastPathComponent)'"
            }
        }
```

Partial failures return **without** running text verification: the response
already reports the text as dispatched, and mixing `partial_failure` with
verification statuses would blur both contracts. Note the "dispatched, not
verified" wording in the message (Step 3).

### Step 3: Add the response constructor and status

Next to the other constructors in `SendResponse` (model on
`pending(_:deliveredTo:chat:)` at `:132-147`):

```swift
    /// Some payloads were dispatched to Messages.app before a later payload failed.
    static func partialFailure(
        sentDescriptions: [String], failedDescription: String, error: String,
        deliveredTo: [String], chat: ChatReference?
    ) -> SendResponse {
        SendResponse(
            status: "partial_failure",
            timestamp: TimeUtils.formatISO(Date()),
            chat: chat,
            deliveredTo: deliveredTo,
            chatId: chat?.id,
            message: "PARTIAL SEND: \(sentDescriptions.joined(separator: ", ")) already dispatched to Messages.app (not verified) before \(failedDescription) failed. Do NOT resend the already-dispatched payload(s); retry only the failed one.",
            error: error,
            candidates: nil,
            verifiedMessageGuid: nil,
            verifiedAt: nil,
            intendedChat: nil,
            actualChatId: nil
        )
    }
```

Add `"partial_failure"` to the ToolError throw rule in `execute` (alongside
`"failed"`, `"ambiguous"`, `"failed_delivery"`), and add one line to the
tool-description proof vocabulary:

```
                  partial_failure — some payloads were dispatched before a later one failed; the message lists which. Never blind-retry the whole call.
```

**Verify**: `cd swift && swift build` → exit 0.

### Step 4: Tests

1. Extend `StubScriptRunner` with a per-call queue, backward-compatibly:

```swift
    /// When non-empty, each call pops the next result; nextResult is the fallback.
    var queuedResults: [Result<Void, SendError>] = []

    private func takeResult() -> Result<Void, SendError> {
        queuedResults.isEmpty ? nextResult : queuedResults.removeFirst()
    }
```

   and use `takeResult()` in all four methods (existing tests keep using
   `nextResult` untouched).

2. New tests in `SendToolExecuteTests` (follow the file's existing fixture +
   decode patterns; the partial case throws `ToolError`, use the existing
   do/catch decode idiom):
   - **Text sent, file fails → partial_failure**: payloads text + file via
     `text:` and `file_paths:` args; `queuedResults = [.success(()), .failure(.fileNotFound("x.jpg"))]`.
     Assert thrown payload has `status == "partial_failure"`, message
     contains `"text message"` and `"x.jpg"`, and stub `invocations.count == 2`.
   - **First payload fails → plain failed, nothing else sent**:
     `queuedResults = [.failure(.messagesAppUnavailable)]` with text + file.
     Assert `status == "failed"` and `invocations.count == 1` (early exit,
     the file was never attempted).
   - **Soft pending keeps sending**: file + file with
     `queuedResults = [.failure(.transferPending("a.jpg")), .success(())]`.
     Assert `status == "pending_confirmation"` and `invocations.count == 2`
     (unchanged behavior, now locked by a test).

   (Check how `SendPayload.build` orders text vs files, text first, and
   construct args to match the intended order; if a files-only or
   file-then-text order isn't expressible, use text+file and file+file cases
   as above.)

3. Docs lockstep: add a `partial_failure` entry to the four doc locations
   listed in Current state, phrased like the Step 3 vocabulary line.

**Verify**: `cd swift && swift test --filter SendToolExecuteTests` → all
pass, 3 new tests; `grep -rn "partial_failure" CONCEPTS.md README.md using-imessage-max/` → ≥4 matches.

### Step 5: Full suite

**Verify**: `cd swift && swift test` → exit 0, 0 failures.

## Test plan

Step 4. Exemplars: `SendToolExecuteTests.swift` fixture helpers
(`makeSendFixture`, `fastVerifier`) and its ToolError do/catch decode idiom.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` exits 0; 0 failures; ≥3 net-new tests
- [ ] `grep -c "partial_failure" swift/Sources/iMessageMax/Tools/Send.swift` ≥ 3 (constructor, throw rule, description)
- [ ] `grep -rn "partial_failure" CONCEPTS.md README.md using-imessage-max/` → ≥4 matches
- [ ] The first-payload-failure case still returns plain `"failed"` (test 2 proves it)
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Plans 021/025 haven't landed (their shapes are missing), order matters.
- `SendContractTests` or schema-level tests assert a closed status set in a
  way that adding `partial_failure` doesn't cleanly extend, report.
- You find the send loop already stops-on-failure or already reports
  partials (i.e. someone fixed this since planning), reconcile, don't
  duplicate.
- Changing `SendResponse`'s stored fields seems necessary, it shouldn't be;
  the breakdown lives in `message`/`error`. Report if that proves false.

## Maintenance notes

- The `sentCount == failure.index` arithmetic relies on Step 1's stop-at-
  first-hard-failure loop (every result before the failure is a dispatch
  attempt that didn't hard-fail). If anyone reintroduces send-all semantics,
  the classification must switch to explicit per-result bookkeeping.
- "Dispatched, not verified" is deliberate: text verification (plan 017/021)
  does not run on the partial path. A future refinement could verify the
  already-sent text and upgrade the message with evidence, note it as an
  option, not a commitment.
- Docs: any future status additions must update the same four doc locations
  plus the tool description, this is the third plan (017, 021, 026) to
  touch that list; keep it in lockstep.
