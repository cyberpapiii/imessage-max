# Plan 031: Typedstream extractor — characterization tests, 0x83 handling, slice-safe indexing

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat e3d14da..HEAD -- swift/Sources/iMessageMax/Utilities/MessageTextExtractor.swift`
> If the file changed since this plan was written, compare the "Current
> state" excerpt against the live code before proceeding; on a mismatch,
> treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW (additive guards + tests; parsing behavior for valid inputs unchanged)
- **Depends on**: none. **Ordering note**: plan 021 depends on this
  extractor's behavior (verified-send text matching) but not on this plan;
  land in any order.
- **Category**: tests + bug
- **Planned at**: commit `e3d14da`, 2026-08-07

## Why this matters

`MessageTextExtractor` parses Apple's undocumented typedstream binary format
by hand. It is load-bearing far beyond display: `SendVerifier.textMatches`
uses it to decide whether a send is `confirmed` — a misparse can produce a
false `uncertain`/`mismatch` on the write path. Yet it has **zero tests**,
and two latent defects:

1. **Unknown length markers are misread as literal lengths.** The parser
   handles `0x81` (2-byte length) and `0x82` (3-byte length); any other
   byte — including `0x83`, and any high byte an OS update might introduce —
   is treated as a literal single-byte length, silently extracting garbage
   (e.g. marker `0x83` reads "length 131" of whatever follows). Garbage
   extraction is worse than a nil return: nil degrades gracefully
   (`uncertain`, empty preview); garbage can *wrongly match or mismatch*
   verification text.
2. **Slice-hostile indexing.** The function mixes absolute indices
   (`nsStringRange.upperBound + 5`, from `range(of:)`) with relative bounds
   (`data.count`). Passed a plain `Data` (today's callers) that's fine;
   passed a `Data` *slice* (where `startIndex != 0` and `count` is
   relative), the `idx < data.count` guards compare absolute against
   relative and can trap on subscript. Nothing stops a future caller from
   passing `blob[someRange]`.

The fix is small and conservative: characterize current behavior in tests
first, normalize indexing, and make unknown markers a nil return.

## Current state

`swift/Sources/iMessageMax/Utilities/MessageTextExtractor.swift` (61 lines,
entire parsing function):

```swift
    static func extractFromTypedstream(_ data: Data) -> String? {
        // Look for NSString or NSMutableString marker in the typedstream
        guard let nsStringRange = data.range(of: Data("NSString".utf8)) ??
              data.range(of: Data("NSMutableString".utf8)) else {
            return nil
        }

        // Skip past the class name marker to the length field
        // The format is: marker + some bytes + length + data
        let idx = nsStringRange.upperBound + 5

        guard idx < data.count else { return nil }

        let lengthByte = data[idx]
        let length: Int
        let dataStart: Int

        // Parse length based on prefix byte
        if lengthByte == 0x81 {
            // 2-byte length (little endian)
            guard idx + 3 <= data.count else { return nil }
            length = Int(data[idx + 1]) | (Int(data[idx + 2]) << 8)
            dataStart = idx + 3
        } else if lengthByte == 0x82 {
            // 3-byte length (little endian)
            guard idx + 4 <= data.count else { return nil }
            length = Int(data[idx + 1]) | (Int(data[idx + 2]) << 8) | (Int(data[idx + 3]) << 16)
            dataStart = idx + 4
        } else {
            // Single byte length
            length = Int(lengthByte)
            dataStart = idx + 1
        }

        guard length > 0 && dataStart + length <= data.count else { return nil }

        let textData = data[dataStart..<(dataStart + length)]
        return String(data: textData, encoding: .utf8)
    }
```

`extract(text:attributedBody:)` (`:8-15`) prefers non-empty `text`, falls
back to the parser, and replaces `\u{FFFC}` with `[Photo]` on both paths.

Callers (behavior consumers — do not modify):
`SendVerifier.textMatches` (`swift/Sources/iMessageMax/Tools/SendVerifier.swift:205-221`)
and message-preview paths. Verify the full caller list with
`grep -rn "MessageTextExtractor" swift/Sources --include="*.swift"`.

There is no `MessageTextExtractorTests.swift` — coverage is zero.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| New tests | `cd swift && swift test --filter MessageTextExtractorTests` | all pass |
| Verifier tests | `cd swift && swift test --filter SendVerifierTests` | all pass (consumer unaffected) |
| Full suite | `cd swift && swift test` | exit 0, 0 failures |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Utilities/MessageTextExtractor.swift`
- `swift/Tests/iMessageMaxTests/MessageTextExtractorTests.swift` (create)
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):
- A full typedstream parser rewrite (attributes, multiple strings,
  archiver versions) — the marker-scan heuristic works on real data; this
  plan hardens it, nothing more.
- Callers (`SendVerifier`, preview formatters).
- The `[Photo]` replacement or `extract`'s text-preference logic — lock
  them in tests, don't change them.

## Git workflow

- Branch: `advisor/031-typedstream-extractor-hardening`
- Conventional commits, e.g. `test: characterize typedstream extractor; fix: reject unknown length markers, slice-safe indexing`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Characterization tests FIRST (against current behavior)

Create `swift/Tests/iMessageMaxTests/MessageTextExtractorTests.swift`
(plain XCTest, `@testable import iMessageMax`, no fixtures needed). Build
synthetic typedstream blobs with a helper:

```swift
    /// Builds: <prefix junk> + "NSString" + 5 filler bytes + length field + payload
    private func typedstreamBlob(lengthField: [UInt8], payload: [UInt8]) -> Data {
        var bytes: [UInt8] = [0x04, 0x0B]                 // arbitrary prefix junk
        bytes += Array("NSString".utf8)
        bytes += [0x01, 0x94, 0x84, 0x01, 0x2B]           // 5 filler bytes (skipped)
        bytes += lengthField
        bytes += payload
        return Data(bytes)
    }
```

Tests (all should pass against the UNMODIFIED extractor — run them before
Step 2 to prove they characterize, not aspire):

1. `testSingleByteLength` — `lengthField: [5]`, payload `"hello"` → `"hello"`.
2. `testTwoByteLength0x81` — a 300-char ASCII string:
   `lengthField: [0x81, 0x2C, 0x01]` (300 little-endian) → the string.
3. `testThreeByteLength0x82` — a 70,000-char string:
   `lengthField: [0x82, 0x70, 0x11, 0x01]` (0x011170 = 70000) → the string.
4. `testNoMarkerReturnsNil` — random bytes without "NSString" → nil.
5. `testTruncatedAfterMarkerReturnsNil` — marker + 2 bytes only → nil.
6. `testLengthOverrunReturnsNil` — `lengthField: [50]`, payload only 10
   bytes → nil.
7. `testInvalidUTF8ReturnsNil` — `lengthField: [2]`, payload `[0xFF, 0xFE]`
   → nil.
8. `testExtractPrefersPlainText` — `extract(text: "hi", attributedBody: <valid blob>)`
   → `"hi"`.
9. `testExtractReplacesObjectReplacementChar` —
   `extract(text: "a\u{FFFC}b", attributedBody: nil)` → `"a[Photo]b"`.
10. `testMutableStringMarkerAlsoParses` — same as test 1 with
    `"NSMutableString"`. **Caveat**: `"NSMutableString"` *contains*
    `"NSString"`? It does not (`NSMutableString` has "NSMutableString";
    `range(of: "NSString")` won't match inside it — "NSString" is not a
    substring of "NSMutableString" because of the "Mutable" infix... check:
    N-S-M-u-t-a-b-l-e-S-t-r-i-n-g — the substring "NSString" does NOT occur.
    Good — the `??` fallback is what finds it). If this test surprises you
    either way, record actual behavior; don't force it.

**Verify**: `cd swift && swift test --filter MessageTextExtractorTests` →
all 10 pass against unmodified source. Any failure means the plan's model
of the parser is wrong — STOP and report which.

### Step 2: Slice-safe indexing

At the top of `extractFromTypedstream`, normalize once:

```swift
    static func extractFromTypedstream(_ data: Data) -> String? {
        // Re-base: callers may pass a Data slice whose indices don't start
        // at 0; all math below assumes zero-based absolute indexing.
        let data = data.startIndex == 0 ? data : Data(data)
```

(Everything else unchanged — with `startIndex == 0` the existing
absolute/relative mixing is consistent.)

Add test 11: `testSliceInputDoesNotTrap` — build a valid blob, prepend 4
junk bytes, take `fullData[4...]` (a slice with `startIndex == 4`), pass the
slice; assert the text still extracts (or at minimum: no trap and same
result as the rebased copy).

**Verify**: `swift test --filter MessageTextExtractorTests` → 11 pass.

### Step 3: Reject unknown length markers

Change the final `else` branch to accept only plausible literal lengths and
refuse marker-range bytes it doesn't understand:

```swift
        } else if lengthByte >= 0x80 {
            // Unknown typedstream length marker (e.g. 0x83+). Misreading it
            // as a literal length extracts garbage — and garbage is worse
            // than nil here: SendVerifier matches on this text. Refuse.
            return nil
        } else {
            // Single byte literal length (< 0x80)
            length = Int(lengthByte)
            dataStart = idx + 1
        }
```

Add tests 12–13:
- `testUnknownMarker0x83ReturnsNil` — `lengthField: [0x83, 0x05, 0x00, 0x00, 0x00]`,
  payload `"hello"` → nil (NOT `"hello"` and NOT garbage).
- `testHighLiteralByteReturnsNil` — `lengthField: [0x9C]` + 156 bytes of
  payload → nil (documents that ≥0x80 is treated as marker space, never
  literal).

Update the function's doc comment (`:17-20`) to describe the new rule.

**Verify**: `swift test --filter MessageTextExtractorTests` → 13 pass;
`swift test --filter SendVerifierTests` → green (real fixtures use plain
text / small strings, unaffected).

### Step 4: Full suite

**Verify**: `cd swift && swift test` → exit 0, 0 failures.

## Test plan

Steps 1–3 (13 tests). This file becomes the extractor's regression corpus —
if a future macOS version changes typedstream framing, add the real-world
failing blob here as a test case.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` exits 0; 0 failures; 13 net-new tests
- [ ] `grep -n "0x80" swift/Sources/iMessageMax/Utilities/MessageTextExtractor.swift` → the marker-refusal branch exists
- [ ] `grep -n "startIndex" swift/Sources/iMessageMax/Utilities/MessageTextExtractor.swift` → the rebase line exists
- [ ] Step 1 tests passed BEFORE source changes (state this in the commit message of the test-only commit — make Step 1 its own commit)
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any Step 1 characterization test fails against unmodified source — the
  plan's model of the parser is wrong; report the discrepancy with the
  actual output.
- `SendVerifierTests` or preview/contract tests break after Step 3 — a real
  fixture depends on ≥0x80 literal lengths; report before weakening the
  guard.
- You feel the pull to "properly" parse typedstream (class hierarchy,
  shared-string references) — explicitly out of scope; report the impulse
  as a future-work note instead.

## Maintenance notes

- The 0x80+ refusal trades hypothetical valid-but-unknown markers for
  never-garbage. If real messages start returning nil (symptom: previews
  showing empty / verified sends going `uncertain` on long texts), capture
  the blob (`SELECT hex(attributedBody) ...`), add it as a test case, and
  extend the marker table — the test corpus is the mechanism.
- Plan 021's verifier work relies on `textMatches` → this extractor; its
  false-`uncertain` debugging should check extractor output first.
