# Plan 047: Replace the triple-pass JSON encoder and guard two unbounded hot paths

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 61e75d9..HEAD -- swift/Sources/iMessageMax/Utilities/FormatUtils.swift swift/Sources/iMessageMax/Enrichment/ImageProcessor.swift swift/Sources/iMessageMax/Utilities/AppleScript.swift swift/Tests/iMessageMaxTests/FormatUtilsTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MEDIUM
- **Depends on**: 041
- **Category**: performance
- **Planned at**: commit `61e75d9`, 2026-09-01

## Why this matters

Every tool response goes through `FormatUtils.encodeJSON`, which encodes with `JSONEncoder`, decodes the bytes back with `JSONSerialization`, then walks the object graph writing a hand-ordered string, escaping one Unicode scalar at a time and looking up each key's position with `firstIndex(of:)` inside the sort comparator. For a `get_messages` page of 200 messages with participants and attachments this is three full passes and an O(keys²) sort per object. The response is the hot path for every agent turn; the encoder is the single largest self-inflicted cost in it.

Two unrelated unbounded operations share this plan because they are small and in the same "cost per call" category: `ImageProcessor` decodes any-size image into a `CIImage` before checking the size cap, and `AppleScript.run` on timeout returns without waiting for its stderr/stdout drain threads, leaving them to block on the pipe.

## Current state

### encodeJSON

`swift/Sources/iMessageMax/Utilities/FormatUtils.swift:88-165`:

```swift
static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    return orderedJSONString(object)
}
```

`orderedJSONString` (`:100-135`) sorts dictionary keys with a comparator at `:117-122` that calls `orderedKeys.firstIndex(of:)` on each comparison so that a fixed list of "important" keys (`id`, `chat_id`, `text`, `date`, ...) come first and the rest alphabetically. `escapeJSONString` (`:137-165`) appends per scalar into a `String`.

Why it exists: the product wants stable, human-scannable key order (important keys first) for agents reading the response. `JSONEncoder.sortedKeys` alone gives alphabetical order, which was judged worse for readability.

Tests: `swift/Tests/iMessageMaxTests/FormatUtilsTests.swift` asserts exact output strings for several inputs, including the key order. Read it before changing anything; those tests are the contract.

### ImageProcessor

`swift/Sources/iMessageMax/Enrichment/ImageProcessor.swift:91-110`: the `.full` variant does `CIImage(contentsOf: url)` and renders, then checks `maxFullVariantBytes` on the encoded output and falls back to `.vision` if too large. A 200-megapixel PNG allocates its full decoded bitmap before the cap is consulted. `sharedContext` is at `:35-42`.

### AppleScript timeout

`swift/Sources/iMessageMax/Utilities/AppleScript.swift:588-612`:

```swift
let result = semaphore.wait(timeout: .now() + timeout)
if result == .timedOut {
    process.terminate()
    return .failure(.timeout)
}
drainGroup.wait()
```

On timeout the two drain threads (stdout/stderr readers started earlier in the function and tracked by `drainGroup`) are abandoned. `terminate()` sends SIGTERM; if osascript ignores it (it does while blocked in a Messages Apple event) the pipes stay open and the reader threads block forever, one pair per timed-out send.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | `Build complete!` |
| Focused | `cd swift && swift test --filter "FormatUtilsTests|ImageProcessorTests|AppleScriptRunnerValidationTests|StructuredContentValueTests"` | 0 failures |
| Whole suite | `cd swift && swift test` | 0 failures |
| Release build for timing | `cd swift && swift build -c release` | `Build complete!` |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Utilities/FormatUtils.swift`
- `swift/Sources/iMessageMax/Enrichment/ImageProcessor.swift`
- `swift/Sources/iMessageMax/Utilities/AppleScript.swift` (the timeout branch only)
- `swift/Tests/iMessageMaxTests/FormatUtilsTests.swift` (add, do not weaken)
- `swift/Tests/iMessageMaxTests/EncodeJSONPerformanceTests.swift` (create)

**Out of scope** (do NOT touch, even though they look related):
- The `structuredContent` path in `Server/ServerExtensions.swift:242-292` and `Server/ToolCallDispatch.swift` — it consumes the string this function produces; do not change its contract.
- Response key sets or any tool's response shape.
- `classifySendStderr` (`AppleScript.swift:478-525`) — plan 049.
- The staging directory cleanup — plan 050.

## Git workflow

- Branch: `advisor/047-hot-path-costs`
- Commits: `perf: encode tool responses in one pass with stable key order`; `perf: check image dimensions before decoding the full variant`; `fix: wait for osascript pipe drains after a timeout`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Pin the current output with a golden test

Before touching the encoder, add `testGoldenOrderingForNestedResponse` to `FormatUtilsTests.swift`: encode a nested `Encodable` value with at least eight keys, two of which are in the important-keys list, a nested array of objects, a string containing `"`, `\`, `/`, a newline, a tab, an emoji, and U+2028. Capture the output at `61e75d9` and paste it as the expected literal. This is the contract the rewrite must preserve byte for byte.

**Verify**: `cd swift && swift test --filter FormatUtilsTests` → 0 failures.

### Step 2: Single-pass encoder

Replace the three-pass implementation with a single encode using a custom `JSONEncoder.KeyEncodingStrategy`? No: key *ordering* is not something `JSONEncoder` exposes. The correct single-pass approach in Foundation is:

1. Keep `JSONEncoder` with `.sortedKeys` and `.withoutEscapingSlashes` for correctness of escaping and number formatting.
2. Replace `JSONSerialization` + `orderedJSONString` with a **streaming re-order** over the encoded bytes only when the important-key rule changes the order. Practically: after `JSONEncoder` produces sorted-key output, the only transformation needed is moving important keys to the front of each object. That still requires parsing.

So the honest single-pass option is to write the ordered string directly from the `Encodable` value with a small custom `Encoder`. That is more code than this plan wants. Take the pragmatic middle:

- Keep `JSONEncoder` → `JSONSerialization` (two passes; both are C-backed and fast).
- Fix `orderedJSONString` so the third pass is linear: precompute `static let orderedKeyRank: [String: Int]` once (dictionary from key to index), and sort with `(rank[a] ?? Int.max, a) < (rank[b] ?? Int.max, b)`.
- Rewrite `escapeJSONString` to scan `utf8` bytes, appending unmodified runs in bulk and only escaping `"`, `\`, control characters below 0x20, and (to match today's behaviour, check the golden test) U+2028/U+2029. Use `String(unsafeUninitializedCapacity:)` or a reserved `[UInt8]` buffer; do not append scalar-by-scalar.
- Reserve capacity on the output string: `result.reserveCapacity(data.count + data.count / 8)`.

**Verify**: `cd swift && swift test --filter FormatUtilsTests` → 0 failures, including the golden test. `grep -n "firstIndex(of:" swift/Sources/iMessageMax/Utilities/FormatUtils.swift` → no matches.

### Step 3: Measure

Create `swift/Tests/iMessageMaxTests/EncodeJSONPerformanceTests.swift` with one `measure {}` test that encodes a synthetic 200-message response (build an `Encodable` struct mirroring `get_messages` output: 200 messages each with 6 string fields, a 3-element participant array, and a nested attachment object). Run it once at `61e75d9` (stash your changes) and once after; record both numbers in the commit message. Expect at least 3× improvement on the encode. If it is under 1.5×, the encoder was not the cost and you should say so in the report rather than keep optimizing.

**Verify**: the test runs and prints `Time:` lines; no failures.

### Step 4: Image dimension guard

In `ImageProcessor.swift` before `CIImage(contentsOf:)` in the `.full` path, read the pixel dimensions cheaply via `CGImageSourceCreateWithURL` + `CGImageSourceCopyPropertiesAtIndex` (`kCGImagePropertyPixelWidth`/`Height`). If `width * height > 50_000_000` (50 MP) or either dimension is 0, skip the full variant and go straight to the `.vision` fallback that already exists at `:105-110`. Add the constant `static let maxFullVariantPixels = 50_000_000` next to `maxFullVariantBytes`.

**Verify**: `cd swift && swift test --filter ImageProcessorTests` → 0 failures. Manually: build a 12000×12000 PNG in the scratch directory (`python3 -c` with Pillow if available, else `sips -z 12000 12000 some.png --out big.png`), and call the processor via an existing test helper or a throwaway XCTest; confirm it returns the vision variant and does not allocate more than ~200 MB (watch `top` or use `xcrun leaks`-free judgement). Do not commit the fixture.

### Step 5: Drain after timeout

In `AppleScript.swift:588-612`, change the timeout branch to:

```swift
if result == .timedOut {
    process.terminate()
    // Give SIGTERM a moment, then SIGKILL so the pipes close and the drain
    // threads can exit. Without this the readers block on an open pipe forever.
    if drainGroup.wait(timeout: .now() + .seconds(2)) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        _ = drainGroup.wait(timeout: .now() + .seconds(2))
    }
    return .failure(.timeout)
}
```

`kill` and `SIGKILL` come from `Darwin`; `import Foundation` already re-exports them. This function is synchronous Dispatch code, not Swift Concurrency, so `DispatchGroup.wait(timeout:)` does not violate the launchd sleep rule; confirm `LaunchdSafetyTests` still passes.

**Verify**: `cd swift && swift test --filter "AppleScriptRunnerValidationTests|LaunchdSafetyTests"` → 0 failures.

### Step 6: Full suite

**Verify**: `cd swift && swift test` → 0 failures.

## Test plan

- `FormatUtilsTests` +1 golden test written before the rewrite.
- `EncodeJSONPerformanceTests` (1 `measure` test) with before/after numbers in the commit message.
- Existing `ImageProcessorTests` and `AppleScriptRunnerValidationTests` unchanged.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` → 0 failures
- [ ] `grep -n "firstIndex(of:" swift/Sources/iMessageMax/Utilities/FormatUtils.swift` → no matches
- [ ] `grep -n "maxFullVariantPixels" swift/Sources/iMessageMax/Enrichment/ImageProcessor.swift` → ≥ 2 matches (declaration and use)
- [ ] `grep -n "SIGKILL" swift/Sources/iMessageMax/Utilities/AppleScript.swift` → one match
- [ ] Golden test output identical before and after (the test passes at both commits)
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The golden test reveals that today's output depends on `JSONSerialization` number formatting in a way `JSONEncoder` alone would change (e.g. `1.0` vs `1`). Keep both passes; do not switch to a custom encoder.
- Step 3 shows under 1.5× improvement. Report the numbers; do not add complexity chasing it.
- `CGImageSource` properties are missing for HEIC on the CI runner and the fallback triggers for every HEIC. Treat missing dimensions as "unknown, proceed" rather than "skip".

## Maintenance notes

- The important-keys list in `FormatUtils` is the response readability contract; adding a key there changes every response's key order. Reviewers should require the golden test to be updated deliberately.
- The 50 MP guard is a memory bound, not a quality decision. If Apple's `CIImage` ever gains lazy tiling that makes full decode cheap, the guard can go.
- Deferred: a true single-pass `Encoder`. Only worth it if profiling shows the two Foundation passes dominate after this plan.
