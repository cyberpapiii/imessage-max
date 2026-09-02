# 079 — Typed delivery disposition for `send`

> **Executor instructions.** Read this whole file before touching code. Work
> on branch `advisor/079-send-delivery-disposition` from `main`. Commit after
> every step with a conventional-commit message. Write the failing test first,
> then the code. Never add `Task.sleep` under `swift/Sources`
> (`LaunchdSafetyTests` fails the build if you do). Never edit `.mcp.json`.
> If a step's **Verify** block does not match, stop and report; do not improvise.
>
> **Drift check.** This plan was written against commit `42deb1f`. Before
> starting, run:
>
> ```bash
> cd /Users/robdezendorf/Documents/GitHub/imessage-max
> git diff --stat 42deb1f..HEAD -- \
>   swift/Sources/iMessageMax/Tools/Send.swift \
>   swift/Sources/iMessageMax/Tools/SendVerifier.swift \
>   swift/Sources/iMessageMax/Utilities/AppleScript.swift \
>   swift/Sources/iMessageMax/Utilities/ClientErrorMessages.swift \
>   swift/Tests/iMessageMaxTests/SendToolExecuteTests.swift \
>   swift/Tests/iMessageMaxTests/SendContractTests.swift \
>   swift/Tests/iMessageMaxTests/SendResponseTests.swift \
>   swift/Tests/iMessageMaxTests/AppleScriptRunnerValidationTests.swift \
>   swift/Tests/iMessageMaxTests/SendManualValidation.md \
>   README.md using-imessage-max/SKILL.md CONCEPTS.md CHANGELOG.md
> ```
>
> If any of those files changed, re-read the changed regions and re-check the
> line numbers quoted below before editing. If `Send.swift` or
> `AppleScript.swift` changed in the regions quoted under *Current state*, stop
> and report instead of guessing.

## Status

- **Status:** TODO
- **Priority:** P2
- **Effort:** M (about 6 commits; the AppleScript change needs one manual live send)
- **Risk:** MEDIUM — touches the AppleScript every send goes through; the new
  structured result must not regress the typed `SendError` classification
- **Depends on:** nothing. Spike 078 (`docs/plans/2026-09-01-send-delivery-semantics.md`)
  is the input; its recommendation (C) "do not redefine `confirmed`" is honoured
  here — `confirmed` keeps its meaning and only its wording is tightened.
- **Category:** feature / contract clarification
- **Planned at:** commit `42deb1f`, 2026-09-02. Baseline: `cd swift && swift build && swift test`
  passes with 433 tests, 0 failures.

## Why this matters

The `send` tool tells a caller *whether the row landed in chat.db* (`confirmed`,
`uncertain`, `mismatch`, `failed_delivery`, `sent`). It never tells the caller
the one thing that decides what to do next after a **failure**: did the
`send` Apple event reach Messages.app or not? Today every transport failure is
a flat `status: "failed"` with a prose `error`, so an agent that sees

```json
{"status":"failed","error":"Send failed: osascript error -1712"}
```

cannot tell "Messages never received the request, retry freely" from "Messages
may already have sent it, do NOT retry". Both look identical. That ambiguity
is exactly where duplicate sends come from.

The reference implementation (openclaw/imsg, HEAD `674f7c6`) solves this by
tracking a `dispatchPhase` inside the AppleScript and returning a structured
tab-separated result. Its `DeliveryFailure` carries a `disposition`
(`not_started` / `may_have_completed`) and `retrySafe` is simply
`disposition == .notStarted`. This plan ports that idea and surfaces it as two
additive response fields:

| Field | Type | Values |
|---|---|---|
| `disposition` | string | `completed`, `not_started`, `may_have_completed` |
| `retry_safe` | bool | `true` only when a retry cannot produce a duplicate |

Spike 078 established that `is_delivered` is unusable as a delivery signal
(0 of 1,530 outbound iMessage DMs in 180 d set it; all 2,678 groups do), so
this plan deliberately does **not** add delivery receipts. It also keeps the
proof vocabulary as a contract; the only wording change is to say precisely
what `confirmed` proves: *the outbound row was found in chat.db within the
verification window (5 polls × 200 ms) with `error = 0`*. That is a chat.db
fact, not a delivery receipt.

## Current state

### The four send scripts have no phase tracking

`swift/Sources/iMessageMax/Utilities/AppleScript.swift:133-154`:

```swift
    private static let sendTextToParticipantScript = """
    on run argv
        set recipientId to item 1 of argv
        set messageText to item 2 of argv
        tell application "Messages"
            set targetService to 1st account whose service type = iMessage
            set targetBuddy to participant recipientId of targetService
            send messageText to targetBuddy
        end tell
    end run
    """

    private static let sendTextToChatScript = """
    on run argv
        set chatGuid to item 1 of argv
        set messageText to item 2 of argv
        tell application "Messages"
            set targetChat to chat id chatGuid
            send messageText to targetChat
        end tell
    end run
    """
```

The two file variants (`:156-179`) are identical apart from
`set attachmentFile to POSIX file filePath` and `send attachmentFile to ...`.

### Failures are classified from stderr only, with no notion of "how far did it get"

`AppleScript.swift:544-564`:

```swift
    private static func run(
        script: String,
        arguments: [String],
        missingTargetError: SendError
    ) -> Result<Void, SendError> {
        let executionResult = execute(
            script: script,
            arguments: arguments,
            timeoutSeconds: 30
        )
        switch executionResult {
        case .failure(let error):
            return .failure(error)
        case .success(let output):
            if output.terminationStatus != 0 {
                return .failure(classifySendStderr(output.stderr, missingTargetError: missingTargetError))
            }
            return .success(())
        }
    }
```

`execute(script:arguments:timeoutSeconds:)` at `:566-640` returns
`.failure(.timeout)` when the 30 s deadline fires (after `terminate()` and a
SIGKILL fallback) and `.failure(.failed(ClientErrorMessages.internalDetail(error, context: "Running AppleScript")))`
when `process.run()` throws (osascript could not launch). Those two are the
only pre-classified transport failures; every other failure comes from
`classifySendStderr` (`:491-542`), which maps substrings of stderr to
`automationPermissionRequired`, `messagesAppUnavailable`, `fileNotFound`,
the caller's `missingTargetError`, or `.failed(firstLine)`.

### `ScriptRunning` and `SendError` carry no disposition

`AppleScript.swift:8-13`:

```swift
protocol ScriptRunning: Sendable {
    func sendTextToParticipant(handle: String, message: String) async -> Result<Void, SendError>
    func sendTextToChat(guid: String, message: String) async -> Result<Void, SendError>
    func sendFileToParticipant(handle: String, filePath: String) async -> Result<Void, SendError>
    func sendFileToChat(guid: String, filePath: String) async -> Result<Void, SendError>
}
```

`SendError` (`:56-100`) has cases `automationPermissionRequired,
messagesAppUnavailable, recipientNotFound(String), chatNotFound(String),
fileNotFound(String), transferPending(String), transferFailed(String),
transferStatusUnknown(String), timeout, failed(String), invalidParams(String)`.

### `SendResponse` has no disposition fields

`swift/Sources/iMessageMax/Tools/Send.swift:20-49`:

```swift
struct SendResponse: Encodable {
    let status: String
    let timestamp: String
    let chat: ChatReference?
    let deliveredTo: [String]?
    let chatId: Int?
    let message: String?
    let error: String?
    let candidates: [RecipientCandidate]?
    let verifiedMessageGuid: String?
    let verifiedAt: String?
    let intendedChat: String?
    let actualChatId: Int?

    enum CodingKeys: String, CodingKey {
        case status, timestamp, chat
        case deliveredTo = "delivered_to"
        case chatId = "chat_id"
        case message, error, candidates
        case verifiedMessageGuid = "verified_message_guid"
        case verifiedAt = "verified_at"
        case intendedChat = "intended_chat"
        case actualChatId = "actual_chat_id"
    }
```

Static constructors at `:53-220`: `.sent`, `.confirmed`, `.uncertain`,
`.mismatch`, `.failedDelivery`, `.pending`, `.partialFailure`, `.error`,
`.ambiguous`. `.error(_:)` at `:188-203` is the only one used for transport
failures of the first payload; `.partialFailure` (`:168-186`) for later ones.

### Where transport failures are turned into responses

`Send.swift:369-420` (inside `send(...)`):

```swift
        var sendResults: [Result<Void, SendError>] = []
        var hardFailure: (index: Int, error: SendError)? = nil
        for (index, payload) in payloads.enumerated() {
            let result = await sendOne(target: resolved.target, payload: payload, runner: runner)
            sendResults.append(result)
            if case .failure(let error) = result {
                switch error {
                case .transferPending, .transferStatusUnknown:
                    continue
                default:
                    hardFailure = (index, error)
                }
                break
            }
        }
        ...
        if let hardFailure {
            let sanitized = ClientErrorMessages.sanitized(hardFailure.error)
            if hardFailure.index == 0 {
                return .error(sanitized)
            }
            ...
            return .partialFailure(
                sentDescriptions: sentDescriptions,
                failedDescription: payloadDescription(payloads[hardFailure.index]),
                error: sanitized,
                deliveredTo: resolved.deliveredTo,
                chat: resolved.chat
            )
        }
```

### Tool description already spells out the proof vocabulary

`Send.swift:252-267` (tool `description`), excerpt:

```
Proof vocabulary for text sends (status field):
- confirmed: row found in chat.db with error=0. Include verified_message_guid as evidence.
- uncertain: Messages accepted the send but no row was found in the polling window. ...
- sent: verification unavailable (DB unreadable). Transport accepted only.
```

### Docs that define `confirmed`

- `README.md:379`: "`status: \"confirmed\"` means the message row was found in
  chat.db with no error; `verified_message_guid` is the evidence".
- `using-imessage-max/SKILL.md:57-75` "Sending safely": "`confirmed`: verified
  delivery."  (this is the phrase spike 078 flagged as over-claiming).
- `CONCEPTS.md:15`: `confirmed` definition; `:17` uncertain; `:20`
  failed_delivery; `:23` sent; `:27` ambiguous; `:29` failed.
- `swift/Tests/iMessageMaxTests/SendManualValidation.md:113-190` manual checks
  7–11.

### Test scaffolding to reuse

`swift/Tests/iMessageMaxTests/SendToolExecuteTests.swift:11-55`:

```swift
final class StubScriptRunner: ScriptRunning, @unchecked Sendable {
    enum Call: Equatable { ... }
    var invocations: [Call] = []
    var nextResult: Result<Void, SendError> = .success(())
    var queuedResults: [Result<Void, SendError>] = []
    var onSend: (() -> Void)?
    ...
}
```

`makeSendFixture()` at `:59-75` (handles `+15550000001` Alice /
`+15550000002` Bob; chat 1 DM guid `iMessage;-;alice-send-guid`; chat 2 group
`iMessage;+;group-send-guid`), `fastVerifier(fixture:)` at `:81-83`
(`SendVerifier(db:, maxAttempts: 1, pollInterval: .milliseconds(0))`),
`decodeJSONDictionary(from:)` at `:640-654`. Row ids already used by this file:
100–103, 110, 111, 120, 121. `SendContractTests.swift:32` also sets
`stub.nextResult = .success(())`. `AppleScriptRunnerValidationTests.swift:31-33`
pattern-matches `case .failure(let error)` on `AppleScriptRunner.sendFileToParticipant`.

### Reference implementation (openclaw/imsg `674f7c6`, inlined; the executor cannot see the clone)

`Sources/IMsgCore/MessageSender.swift:195-265`, the AppleScript:

```applescript
on run argv
    set dispatchPhase to "pre_dispatch"
    try
        ...
        tell application "Messages"
            ...
            if theMessage is not "" then
                set dispatchPhase to "dispatch_started"
                send theMessage to targetChat
            end if
            ...
        end tell
        return "IMSG_RESULT" & tab & "ok" & tab & "completed" & tab & "0"
    on error errorMessage number errorNumber
        if dispatchPhase is "pre_dispatch" then
            return "IMSG_RESULT" & tab & "failure" & tab & "not_started" & tab & errorNumber
        end if
        return "IMSG_RESULT" & tab & "failure" & tab & "may_have_completed" & tab & errorNumber
    end try
end run
```

`Sources/IMsgCore/AppleScriptSendTransport.swift:8-106` (transport-level classification):

- `process.run()` throws → `failure(.notStarted, "osascript could not be launched.")`
- stdin write fails after launch → `failure(.mayHaveCompleted, "The osascript input channel failed after process launch.")`
- timeout → `failure(.mayHaveCompleted, "osascript timed out after N seconds.")`
- uncaught signal or nonzero exit → `failure(.mayHaveCompleted, "osascript exited without an authoritative delivery phase.")`

```swift
    static func interpret(_ output: String) -> AppleScriptTransportResult {
        let fields = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
            .map(String.init)
        guard fields.count == 4, fields[0] == "IMSG_RESULT" else {
            return .failure(.mayHaveCompleted, "osascript exited without the structured delivery result.")
        }
        if fields[1] == "ok", fields[2] == "completed" { return .success }
        let detail = "Messages automation failed with AppleScript error \(fields[3])."
        switch fields[2] {
        case "not_started": return .failure(.notStarted, detail)
        case "may_have_completed": return .failure(.mayHaveCompleted, detail)
        default: return .failure(.mayHaveCompleted, "osascript returned an unknown delivery phase.")
        }
    }
```

`Sources/IMsgCore/DeliveryFailure.swift`:

```swift
public enum DeliveryDisposition: String, Sendable, Codable {
    case notStarted = "not_started"
    case mayHaveCompleted = "may_have_completed"
    case stillInFlight = "still_in_flight"
}
public struct DeliveryFailure: Error {
    ... var retrySafe: Bool { disposition == .notStarted }
}
```

Differences in this port: imessage-max passes arguments via `osascript -e … -- args`
(no stdin), so there is no stdin-write case; the marker is
`IMESSAGE_MAX_RESULT`; a fifth field carries `errorMessage` so the existing
`classifySendStderr` substring rules keep producing the typed `SendError`
cases; `still_in_flight` is not needed (file transfers already have
`transferPending` / `pending_confirmation`).

## Commands

| Purpose | Command |
|---|---|
| Build | `cd /Users/robdezendorf/Documents/GitHub/imessage-max/swift && swift build` |
| Full suite | `cd /Users/robdezendorf/Documents/GitHub/imessage-max/swift && swift test` |
| Send tests only | `cd /Users/robdezendorf/Documents/GitHub/imessage-max/swift && swift test --filter 'SendToolExecuteTests\|SendContractTests\|SendResponseTests\|AppleScriptSendResultTests\|AppleScriptRunnerValidationTests\|ResponseContractTests\|LaunchdSafetyTests'` |
| Install for manual check | `cd /Users/robdezendorf/Documents/GitHub/imessage-max/swift && make install` |
| Task.sleep guard | `grep -rn "Task.sleep" /Users/robdezendorf/Documents/GitHub/imessage-max/swift/Sources` (must print nothing) |

## Scope

### In

- New `DeliveryDisposition` enum (`completed`, `not_started`, `may_have_completed`)
  and `SendFailure` struct (`error: SendError`, `disposition`), with
  `retrySafe`.
- `ScriptRunning` returns `Result<Void, SendFailure>`; `LiveScriptRunner`,
  `AppleScriptRunner` statics, `StubScriptRunner` updated.
- The four send scripts wrap the `tell` block in `try … on error` with a
  `dispatchPhase` marker and return a tab-separated `IMESSAGE_MAX_RESULT` line.
- A pure, testable `AppleScriptRunner.interpretSendResult(...)` that turns
  `(stdout, stderr, terminationStatus)` into `Result<Void, SendFailure>`.
- Transport failure classification: launch failure → `not_started`; timeout,
  nonzero exit without a marker, missing marker → `may_have_completed`.
- `SendResponse` gains `disposition` and `retry_safe` (always populated).
- Docs: tool description, `README.md`, `using-imessage-max/SKILL.md`,
  `CONCEPTS.md`, `SendManualValidation.md`, `CHANGELOG.md`.
- Tests: new `AppleScriptSendResultTests.swift`; new cases in
  `SendToolExecuteTests.swift`; adjustments in `SendResponseTests.swift` and
  `AppleScriptRunnerValidationTests.swift`.

### Out

- Any change to `SendVerifier` polling, window, or the meaning of
  `confirmed` / `uncertain` / `mismatch` / `failed_delivery` (spike 078 (C)).
- Delivery receipts, `is_delivered`, `date_delivered` (spike 078 showed they
  are style correlates).
- Retrying automatically inside the server. `retry_safe` is information for
  the caller, not a loop.
- SMS fallback (imsg retries on SMS when `retrySafe`; imessage-max has no SMS path).
- `.mcp.json`, launchd plist, Formula.

## Git workflow

```bash
cd /Users/robdezendorf/Documents/GitHub/imessage-max
git checkout main && git pull --ff-only
git checkout -b advisor/079-send-delivery-disposition
```

Commit after each step. Suggested messages are given per step. Do not squash.
When all steps pass, leave the branch for review; do not merge.

## Steps

### Step 1 — `DeliveryDisposition` + `SendFailure` types, `ScriptRunning` carries them

Create `swift/Sources/iMessageMax/Utilities/DeliveryDisposition.swift`:

```swift
import Foundation

/// How far a transport attempt got before it stopped. Mirrors the
/// dispatchPhase tracked inside the send AppleScript.
enum DeliveryDisposition: String, Sendable, Encodable, Equatable {
    /// Messages.app returned from `send` without raising an error.
    case completed
    /// The failure happened before the `send` Apple event was issued.
    /// Retrying cannot produce a duplicate.
    case notStarted = "not_started"
    /// The failure happened after the `send` Apple event was issued, or we
    /// cannot tell (timeout, osascript killed, no structured result).
    case mayHaveCompleted = "may_have_completed"

    /// True only when a retry provably cannot duplicate a message.
    var retrySafe: Bool { self == .notStarted }
}

/// A transport failure plus how far it got.
struct SendFailure: Error, LocalizedError, Sendable {
    let error: SendError
    let disposition: DeliveryDisposition

    init(_ error: SendError, disposition: DeliveryDisposition) {
        self.error = error
        self.disposition = disposition
    }

    var errorDescription: String? { error.errorDescription }
}
```

Change the protocol in `AppleScript.swift:8-13` so all four functions return
`Result<Void, SendFailure>`. Update `LiveScriptRunner` (`:20-54`) — it only
forwards, so the four `Result<Void, SendError>` type annotations become
`Result<Void, SendFailure>`. Update the four `AppleScriptRunner` statics
(`sendTextToParticipant`, `sendTextToChat`, `sendFileToParticipant`,
`sendFileToChat`, `:181-259`) to return `Result<Void, SendFailure>`:

- Every validation guard that currently returns `.failure(.invalidParams(...))`
  or `.failure(.fileNotFound(...))` becomes
  `.failure(SendFailure(.invalidParams(...), disposition: .notStarted))` (nothing was sent).
- The file variants' post-send `waitForTransferCompletion` results
  (`transferPending`, `transferFailed`, `transferStatusUnknown`) are wrapped
  with `disposition: .mayHaveCompleted` (the file was handed to Messages).
- `run(script:arguments:missingTargetError:)` returns `Result<Void, SendFailure>`
  — for now wrap the existing `.failure(error)` paths as
  `.mayHaveCompleted` except the launch-failure branch; Step 3 replaces this
  body with `interpretSendResult`.

In `execute(...)` (`:566-640`) nothing changes in this step.

Update `Send.swift:369-420`: `sendResults: [Result<Void, SendFailure>]`,
`hardFailure: (index: Int, failure: SendFailure)?`, the `switch error` becomes
`switch failure.error`, and `ClientErrorMessages.sanitized(hardFailure.failure.error)`.
The `sendOne` helper (`:485-506`) signature becomes `-> Result<Void, SendFailure>`.

Update tests to compile:

- `SendToolExecuteTests.swift:11-55` `StubScriptRunner`: `nextResult: Result<Void, SendFailure>`,
  `queuedResults: [Result<Void, SendFailure>]`. Replace each existing
  `.failure(.X)` with `.failure(SendFailure(.X, disposition: .notStarted))`
  except `.failure(.transferPending("..."))` / `.transferStatusUnknown` which get
  `.mayHaveCompleted`. (`grep -n "\.failure(\." swift/Tests/iMessageMaxTests/SendToolExecuteTests.swift`
  lists the 3–4 call sites.)
- `AppleScriptRunnerValidationTests.swift:31-35` and `:144-148`: the pattern
  `case .failure(let error)` now binds a `SendFailure`; change assertions to
  `error.error.localizedDescription` (or `error.localizedDescription`, which
  forwards) and add `XCTAssertEqual(error.disposition, .notStarted)` to both.

**Verify**

```bash
cd /Users/robdezendorf/Documents/GitHub/imessage-max/swift && swift build 2>&1 | tail -3 && swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1
```

Expected: build succeeds; `Executed 433 tests, with 0 failures`.

Commit: `refactor(send): carry a DeliveryDisposition on transport failures`

### Step 2 — Pure result parser, test-first

Create `swift/Tests/iMessageMaxTests/AppleScriptSendResultTests.swift`:

```swift
import XCTest
@testable import iMessageMax

final class AppleScriptSendResultTests: XCTestCase {
    private let missing = SendError.chatNotFound("iMessage;-;x")

    private func interpret(_ stdout: String, stderr: String = "", status: Int32 = 0) -> Result<Void, SendFailure> {
        AppleScriptRunner.interpretSendResult(
            stdout: stdout, stderr: stderr, terminationStatus: status, missingTargetError: missing
        )
    }

    func testOkCompletedIsSuccess() {
        guard case .success = interpret("IMESSAGE_MAX_RESULT\tok\tcompleted\t0\t\n") else {
            return XCTFail("expected success")
        }
    }

    func testPreDispatchFailureIsNotStartedAndKeepsTypedError() {
        let result = interpret("IMESSAGE_MAX_RESULT\tfailure\tnot_started\t-1728\tCan’t get chat id \"iMessage;-;x\".\n")
        guard case .failure(let failure) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(failure.disposition, .notStarted)
        XCTAssertTrue(failure.disposition.retrySafe)
        XCTAssertEqual(failure.error.localizedDescription, missing.localizedDescription)
    }

    func testPostDispatchFailureIsMayHaveCompleted() {
        let result = interpret("IMESSAGE_MAX_RESULT\tfailure\tmay_have_completed\t-1712\tMessages got an error: AppleEvent timed out.\n")
        guard case .failure(let failure) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(failure.disposition, .mayHaveCompleted)
        XCTAssertFalse(failure.disposition.retrySafe)
        XCTAssertTrue(failure.error.localizedDescription.contains("AppleEvent timed out"))
    }

    func testAutomationDeniedBeforeDispatchIsNotStarted() {
        let result = interpret("IMESSAGE_MAX_RESULT\tfailure\tnot_started\t-1743\tNot authorized to send Apple events to Messages.\n")
        guard case .failure(let failure) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(failure.disposition, .notStarted)
        XCTAssertEqual(failure.error.localizedDescription, SendError.automationPermissionRequired.localizedDescription)
    }

    func testErrorMessageContainingTabsIsPreserved() {
        let result = interpret("IMESSAGE_MAX_RESULT\tfailure\tnot_started\t-2700\tline one\twith tab\n")
        guard case .failure(let failure) = result else { return XCTFail("expected failure") }
        XCTAssertTrue(failure.error.localizedDescription.contains("with tab"), "message after the 4th tab must survive the split")
    }

    func testMarkerIsFoundOnLastLineAfterNoise() {
        let result = interpret("some warning\nIMESSAGE_MAX_RESULT\tok\tcompleted\t0\t\n")
        guard case .success = result else { return XCTFail("expected success") }
    }

    func testNonzeroExitWithoutMarkerIsMayHaveCompletedAndClassifiesStderr() {
        let result = interpret("", stderr: "execution error: Messages got an error: Connection is invalid. (-609)", status: 1)
        guard case .failure(let failure) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(failure.disposition, .mayHaveCompleted)
        XCTAssertEqual(failure.error.localizedDescription, SendError.messagesAppUnavailable.localizedDescription)
    }

    func testZeroExitWithoutMarkerIsMayHaveCompleted() {
        let result = interpret("", stderr: "", status: 0)
        guard case .failure(let failure) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(failure.disposition, .mayHaveCompleted)
        XCTAssertEqual(failure.error.localizedDescription, "Send failed: Messages returned no structured send result")
    }

    func testUnknownPhaseIsMayHaveCompleted() {
        let result = interpret("IMESSAGE_MAX_RESULT\tfailure\tsomething_else\t0\tx\n")
        guard case .failure(let failure) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(failure.disposition, .mayHaveCompleted)
    }
}
```

Then add to `AppleScriptRunner` in `AppleScript.swift` (next to
`classifySendStderr`, keep it `static` and internal so the test can call it):

```swift
    static let sendResultMarker = "IMESSAGE_MAX_RESULT"

    /// Turns the raw osascript output of a send script into a typed result.
    /// The script prints one line:
    ///   IMESSAGE_MAX_RESULT <tab> ok|failure <tab> completed|not_started|may_have_completed <tab> errno <tab> message
    /// The message is last because it may itself contain tabs.
    static func interpretSendResult(
        stdout: String,
        stderr: String,
        terminationStatus: Int32,
        missingTargetError: SendError
    ) -> Result<Void, SendFailure> {
        let markerLine = stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .last { $0.hasPrefix(sendResultMarker + "\t") }

        guard let markerLine else {
            if terminationStatus != 0 {
                return .failure(SendFailure(
                    classifySendStderr(stderr, missingTargetError: missingTargetError),
                    disposition: .mayHaveCompleted
                ))
            }
            return .failure(SendFailure(
                .failed("Messages returned no structured send result"),
                disposition: .mayHaveCompleted
            ))
        }

        let fields = markerLine.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5 else {
            return .failure(SendFailure(.failed("Messages returned a malformed send result"), disposition: .mayHaveCompleted))
        }
        if fields[1] == "ok", fields[2] == "completed" {
            return .success(())
        }
        let disposition: DeliveryDisposition
        switch fields[2] {
        case "not_started": disposition = .notStarted
        case "may_have_completed": disposition = .mayHaveCompleted
        default: disposition = .mayHaveCompleted
        }
        let error = classifySendStderr(fields[4], missingTargetError: missingTargetError)
        return .failure(SendFailure(error, disposition: disposition))
    }
```

Note `classifySendStderr` already normalises `’` to `'`, lowercases, and
clamps to 300 chars — check its signature at `AppleScript.swift:491`
(`classifySendStderr(_ stderr: String, sentFileName: String? = nil, missingTargetError: SendError)`)
and pass `sentFileName` through from the file scripts in Step 3.

**Verify**

```bash
cd /Users/robdezendorf/Documents/GitHub/imessage-max/swift && swift test --filter AppleScriptSendResultTests 2>&1 | grep -E "Executed [0-9]+ tests"
```

Expected: `Executed 9 tests, with 0 failures`.

Commit: `feat(send): parse the structured IMESSAGE_MAX_RESULT send line`

### Step 3 — Phase-tracking AppleScript and transport classification

Replace the four scripts in `AppleScript.swift:133-179`. Text-to-chat becomes:

```applescript
on run argv
    set chatGuid to item 1 of argv
    set messageText to item 2 of argv
    set dispatchPhase to "pre_dispatch"
    try
        tell application "Messages"
            set targetChat to chat id chatGuid
            set dispatchPhase to "dispatch_started"
            send messageText to targetChat
        end tell
        return "IMESSAGE_MAX_RESULT" & tab & "ok" & tab & "completed" & tab & "0" & tab & ""
    on error errorMessage number errorNumber
        if dispatchPhase is "pre_dispatch" then
            return "IMESSAGE_MAX_RESULT" & tab & "failure" & tab & "not_started" & tab & errorNumber & tab & errorMessage
        end if
        return "IMESSAGE_MAX_RESULT" & tab & "failure" & tab & "may_have_completed" & tab & errorNumber & tab & errorMessage
    end try
end run
```

Apply the same shape to the participant variant (phase flips after
`set targetBuddy to participant recipientId of targetService`) and the two file
variants (phase flips after `set attachmentFile to POSIX file filePath` and the
target lookup, immediately before `send attachmentFile to ...`). The
`set dispatchPhase to "dispatch_started"` line must be the statement
immediately before `send`, inside the `tell` block.

Replace the body of `run(script:arguments:missingTargetError:)` (`:544-564`):

```swift
    private static func run(
        script: String,
        arguments: [String],
        sentFileName: String? = nil,
        missingTargetError: SendError
    ) -> Result<Void, SendFailure> {
        switch execute(script: script, arguments: arguments, timeoutSeconds: 30) {
        case .failure(.timeout):
            return .failure(SendFailure(.timeout, disposition: .mayHaveCompleted))
        case .failure(let error):
            // execute() only fails this way when osascript could not be launched.
            return .failure(SendFailure(error, disposition: .notStarted))
        case .success(let output):
            return interpretSendResult(
                stdout: output.stdout,
                stderr: output.stderr,
                terminationStatus: output.terminationStatus,
                missingTargetError: missingTargetError
            )
        }
    }
```

If `interpretSendResult` needs `sentFileName` for `classifySendStderr`, thread
it through as an extra parameter with a default of `nil` (the file-send
statics know the file name; see how they call `classifySendStderr` today).

Read `execute(...)` at `:566-640` once more and confirm the only two
`.failure` returns are `.failure(.timeout)` and the `catch` around
`process.run()`. If there is a third, classify it explicitly rather than
letting it fall into the `.notStarted` branch.

Add a LaunchdSafety-style guard: no new `Thread.sleep` or `Task.sleep`.

**Verify**

```bash
cd /Users/robdezendorf/Documents/GitHub/imessage-max/swift && swift test --filter 'AppleScriptSendResultTests|AppleScriptRunnerValidationTests|LaunchdSafetyTests|SendToolExecuteTests|SendContractTests' 2>&1 | grep -E "Executed [0-9]+ tests|error:" | tail -3
grep -c 'dispatchPhase to "dispatch_started"' /Users/robdezendorf/Documents/GitHub/imessage-max/swift/Sources/iMessageMax/Utilities/AppleScript.swift
```

Expected: `0 failures`; the grep count is `4`.

Manual live check (required, this is the risky commit): `make install`, then
from the MCP client send one short text to your own handle (spike 078 used a
self-send; the probe guid was `04007E64-8C94-442B-92B1-38B42E5B9605`) and
one to a deliberately bogus chat guid (`iMessage;-;does-not-exist`). Expected:
the self-send returns `status: "confirmed"` (or `uncertain`) and the bogus one
returns `status: "failed"` with the error text `Chat not found: iMessage;-;does-not-exist`
(unchanged from today). If the bogus send returns `Send failed: Messages returned no structured send result`,
the marker line is not reaching stdout — STOP (see STOP conditions).

Commit: `feat(send): track the dispatch phase inside the send AppleScript`

### Step 4 — Surface `disposition` and `retry_safe` on `SendResponse`, test-first

Add tests to `SendToolExecuteTests.swift` (use row ids 130–139; the fixture is
`makeSendFixture()`; see `testStubSendWithMatchingRowConfirms` for the
confirmed pattern and `testScriptFailureProducesFailedStatus` for the
failure/ToolError pattern):

| Test | Arrange | Assert on decoded JSON |
|---|---|---|
| `testConfirmedSendReportsCompletedNotRetrySafe` | stub success, matching row inserted | `disposition == "completed"`, `retry_safe == false` |
| `testUncertainSendReportsCompletedNotRetrySafe` | stub success, no row | `disposition == "completed"`, `retry_safe == false` |
| `testNotStartedFailureIsRetrySafe` | `nextResult = .failure(SendFailure(.chatNotFound("x"), disposition: .notStarted))` | `status == "failed"`, `disposition == "not_started"`, `retry_safe == true` |
| `testMayHaveCompletedFailureIsNotRetrySafe` | `.failure(SendFailure(.timeout, disposition: .mayHaveCompleted))` | `status == "failed"`, `disposition == "may_have_completed"`, `retry_safe == false` |
| `testPartialFailureIsNeverRetrySafe` | `queuedResults = [.success(()), .failure(SendFailure(.messagesAppUnavailable, disposition: .notStarted))]` with two payloads | `status == "partial_failure"`, `disposition == "not_started"`, `retry_safe == false` |
| `testFailedDeliveryRowIsRetrySafe` | stub success, row with `error: 22` | `status == "failed_delivery"`, `disposition == "completed"`, `retry_safe == true` |
| `testValidationErrorIsNotStartedRetrySafe` | e.g. empty `to` (see `testEmptyRecipient...` if one exists, else send with `message: ""`) | `status == "failed"`, `disposition == "not_started"`, `retry_safe == true` |
| `testAmbiguousIsNotStartedRetrySafe` | two handles matching one name (see existing ambiguous test in this file or `SendResolverTests`) | `status == "ambiguous"`, `disposition == "not_started"`, `retry_safe == true` |

Decision table to implement (put it in a doc comment on `SendResponse`):

| status | disposition | retry_safe |
|---|---|---|
| confirmed, uncertain, mismatch, sent | `completed` | `false` |
| failed_delivery | `completed` | `true` (chat.db proves it did not go out) |
| pending_confirmation | `may_have_completed` | `false` |
| failed (transport) | from `SendFailure` | `disposition.retrySafe` |
| failed (validation / resolution, no transport attempted) | `not_started` | `true` |
| partial_failure | failing payload's disposition | `false` (earlier payloads went out) |
| ambiguous | `not_started` | `true` |

Implementation in `Send.swift`:

1. Add to `SendResponse`: `let disposition: String` and `let retrySafe: Bool`,
   CodingKeys `case disposition`, `case retrySafe = "retry_safe"`.
2. Every static constructor sets them per the table. `.error(_:)` gains a
   parameter `disposition: DeliveryDisposition = .notStarted` (validation and
   resolution callers keep the default; the transport caller passes
   `hardFailure.failure.disposition`). `.partialFailure(...)` gains
   `disposition: DeliveryDisposition`. Compute
   `retrySafe: disposition.retrySafe` for `.error`, hard-code the others.
3. In `send(...)` `:405-420` pass `hardFailure.failure.disposition` to both
   `.error` and `.partialFailure`.

Update `SendResponseTests.swift` if any test constructs a response through a
changed signature (only `.error` and `.partialFailure` change, both with
defaults or one new arg). Update `ResponseContractTests.swift:206-216`
`testSendResponseUsesNestedChat` to additionally assert
`json["disposition"] as? String == "completed"` and `json["retry_safe"] as? Bool == false`.

**Verify**

```bash
cd /Users/robdezendorf/Documents/GitHub/imessage-max/swift && swift test --filter 'SendToolExecuteTests|SendResponseTests|ResponseContractTests|SendContractTests' 2>&1 | grep -E "Executed [0-9]+ tests|failed" | tail -3
```

Expected: `0 failures`, test count in this filter up by 8 from Step 3.

Commit: `feat(send): report disposition and retry_safe on every send response`

### Step 5 — Tool description and docs

1. `Send.swift:252-267` tool description: change the `confirmed` line to
   `confirmed: outbound row found in chat.db within the verification window (about 1 s) with error=0. Not a delivery receipt.`
   and append after the vocabulary list:

   ```
   Every response also carries disposition (completed | not_started | may_have_completed) and retry_safe.
   retry_safe=true means a retry cannot duplicate the message (nothing reached Messages, or chat.db shows the row failed).
   retry_safe=false means do not resend blindly; check with get_messages first.
   ```

2. `README.md:375-397`: reword `:379` to "`status: \"confirmed\"` means the
   outbound row was found in chat.db within the verification window with no
   error; `verified_message_guid` is the evidence. It is not a delivery
   receipt." Add a short subsection `#### Disposition and retry_safe` with the
   decision table from Step 4 and one JSON example each for `not_started`
   and `may_have_completed`.

3. `using-imessage-max/SKILL.md:57-75`: replace "`confirmed`: verified
   delivery." with "`confirmed`: row found in chat.db within the verification
   window." Add two bullets: "`retry_safe: true` — safe to resend." and
   "`retry_safe: false` — do not resend; read the chat with `get_messages`
   first."

4. `CONCEPTS.md:7-29`: tighten `:15` the same way; add entries for
   `disposition` and `retry_safe` after `failed` (`:29`).

5. `swift/Tests/iMessageMaxTests/SendManualValidation.md:113-190`: add
   expected `disposition` / `retry_safe` values to checks 7–11 and a new check
   12 "bogus chat guid → `failed`, `not_started`, `retry_safe: true`".

6. `CHANGELOG.md`: under a new `## Unreleased` → `### Added` line:
   "`send` responses carry `disposition` (`completed` / `not_started` /
   `may_have_completed`) and `retry_safe`; `confirmed` is documented as a
   chat.db row match within the verification window, not a delivery receipt."

**Verify**

```bash
cd /Users/robdezendorf/Documents/GitHub/imessage-max
grep -c "retry_safe" README.md using-imessage-max/SKILL.md CONCEPTS.md CHANGELOG.md swift/Tests/iMessageMaxTests/SendManualValidation.md swift/Sources/iMessageMax/Tools/Send.swift
grep -n "verified delivery" using-imessage-max/SKILL.md
```

Expected: every file in the first grep reports ≥ 1; the second grep prints nothing.

Commit: `docs(send): define confirmed as a chat.db row match and document retry_safe`

### Step 6 — Full suite, final drift check, index row

```bash
cd /Users/robdezendorf/Documents/GitHub/imessage-max/swift && swift build 2>&1 | tail -1 && swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1
grep -rn "Task.sleep" /Users/robdezendorf/Documents/GitHub/imessage-max/swift/Sources
```

Expected: `Executed 450 tests, with 0 failures` (433 + 9 parser + 8 response;
report the exact number), and the `Task.sleep` grep prints nothing.

Add a row to `plans/README.md` current-round table:
`| [079](079-send-delivery-disposition.md) | Typed delivery disposition for send | P2 | M | — | DONE |`
(use whatever Status column wording the table uses at that time).

Commit: `docs(plans): record 079 send delivery disposition`

## Test plan

- Unit (no osascript): `AppleScriptSendResultTests` — 9 cases covering ok,
  not_started, may_have_completed, automation-denied mapping, tab-in-message,
  marker after noise, nonzero exit without marker, zero exit without marker,
  unknown phase.
- Tool-level (stub runner + fixture DB): 8 cases in `SendToolExecuteTests`
  for the decision table.
- Contract: `ResponseContractTests.testSendResponseUsesNestedChat` asserts the
  two new keys exist on `.sent`.
- Existing: all `SendContractTests`, `SendVerifierTests`, `SendResponseTests`
  continue to pass unchanged in meaning.
- Manual (Step 3): one self-send and one bogus-guid send through the installed
  binary; record results in the PR description.

## Done criteria

- [ ] `grep -n "case notStarted = \"not_started\"" swift/Sources/iMessageMax/Utilities/DeliveryDisposition.swift` matches.
- [ ] `grep -c "Result<Void, SendFailure>" swift/Sources/iMessageMax/Utilities/AppleScript.swift` ≥ 9 (protocol 4 + LiveScriptRunner 4 + run 1).
- [ ] `grep -c 'dispatchPhase to "dispatch_started"' swift/Sources/iMessageMax/Utilities/AppleScript.swift` prints `4`.
- [ ] `grep -n "static func interpretSendResult" swift/Sources/iMessageMax/Utilities/AppleScript.swift` matches.
- [ ] `grep -n 'case retrySafe = "retry_safe"' swift/Sources/iMessageMax/Tools/Send.swift` matches.
- [ ] `swift test` passes with 0 failures and at least 450 tests.
- [ ] `grep -rn "Task.sleep" swift/Sources` prints nothing.
- [ ] `grep -n "verified delivery" using-imessage-max/SKILL.md` prints nothing.
- [ ] Manual self-send returns `disposition: "completed"`; bogus guid returns
      `disposition: "not_started"`, `retry_safe: true`, error `Chat not found: …`.
- [ ] `git diff main --stat` touches no file outside the drift-check list plus
      the two new files and `plans/README.md`.

## STOP conditions

- The drift check shows `Send.swift:369-481` or `AppleScript.swift:544-640`
  changed since `42deb1f`.
- In Step 3 the bogus-guid manual send returns
  `Send failed: Messages returned no structured send result` — the marker
  line is not on stdout (osascript may print the returned string differently
  on this macOS). Report the raw stdout/stderr; do not loosen the parser.
- In Step 3 the self-send stops reaching `confirmed`/`uncertain` (i.e. the
  `try` wrapper changed AppleScript behaviour). Revert the commit and report.
- Any existing `SendContractTests` or `SendVerifierTests` assertion needs
  changing to pass — that means the proof vocabulary moved, which is out of scope.
- `LaunchdSafetyTests` fails.
- A test needs a real Messages.app to pass.

## Maintenance notes

- `DeliveryDisposition` is about the **transport** (did the Apple event go
  out), `status` is about **chat.db**. Keep them orthogonal; never derive one
  from the other except through the decision table in `SendResponse`.
- If a future macOS changes osascript's stdout formatting, the parser fails
  closed to `may_have_completed` with the text "no structured send result".
  That is the intended safe default (never claim `not_started` without proof).
- `classifySendStderr` now sees two inputs: raw AppleScript `errorMessage`
  (via the marker) and osascript stderr (no marker). Its substring rules were
  written for stderr, which contains the same message text with an
  `execution error:` prefix, so both paths match; if you add a rule, test it
  against both shapes.
- imsg also carries `still_in_flight`; imessage-max expresses that through
  `status: "pending_confirmation"` for file transfers and did not need a
  third disposition. Add it only if a caller needs to distinguish
  "timed out while polling the transfer" from "unknown".
- Spike 078 (`docs/plans/2026-09-01-send-delivery-semantics.md`) is the
  record for why `confirmed` is not a delivery receipt; link it from any
  future change to the wording.
