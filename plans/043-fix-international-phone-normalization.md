# Plan 043: Stop rewriting 10-digit international numbers to +1 on the send path

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 61e75d9..HEAD -- swift/Sources/iMessageMax/Contacts/PhoneUtils.swift swift/Tests/iMessageMaxTests/PhoneUtilsTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: 041 (adds `PhoneUtilsTests` with the expected-failure case this plan turns green)
- **Category**: bug
- **Planned at**: commit `61e75d9`, 2026-09-01

## Why this matters

`PhoneUtils.normalizeToE164` checks "exactly 10 digits" before it checks for a leading `+`. A Danish, Norwegian, Singaporean, or any other number that is 10 digits after its country code (`+45 12 34 56 78`, `+65 9123 4567`) is rewritten to `+1451234567…`, a different subscriber in the North American numbering plan. This function sits on the send path (`Tools/SendResolution.swift:109`) and in display formatting and contact matching, so the failure mode is a message delivered to a stranger with a `confirmed` status, which is the worst thing this product can do.

The fix is to honour an explicit `+` before applying the US default, and to accept short codes as phone numbers for matching purposes.

## Current state

`swift/Sources/iMessageMax/Contacts/PhoneUtils.swift` (whole file at `61e75d9`):

```swift
// Sources/iMessageMax/Contacts/PhoneUtils.swift
import Foundation

enum PhoneUtils {
    static func normalizeToE164(_ input: String) -> String? {
        let digits = input.filter { $0.isNumber }
        let hasPlus = input.hasPrefix("+")

        guard !digits.isEmpty else { return nil }

        if digits.count == 10 {
            return "+1\(digits)"
        } else if digits.count == 11 && digits.hasPrefix("1") {
            return "+\(digits)"
        } else if hasPlus {
            return "+\(digits)"
        } else if digits.count > 10 {
            return "+\(digits)"
        }

        return nil
    }

    static func formatDisplay(_ phone: String) -> String {
        guard let normalized = normalizeToE164(phone) else {
            return phone
        }

        if normalized.hasPrefix("+1") && normalized.count == 12 {
            let digits = String(normalized.dropFirst(2))
            let area = digits.prefix(3)
            let exchange = digits.dropFirst(3).prefix(3)
            let subscriber = digits.suffix(4)
            return "+1 (\(area)) \(exchange)-\(subscriber)"
        }

        return normalized
    }

    static func isPhoneNumber(_ input: String) -> Bool {
        let digits = input.filter { $0.isNumber }
        return digits.count >= 10 && digits.count <= 15
    }

    static func isEmail(_ input: String) -> Bool {
        input.contains("@") && input.contains(".")
    }
}
```

Callers (nine sites, found with `grep -rn "PhoneUtils\." swift/Sources`): `SendResolution.swift:109` (send target), `IdentityDisplayFormatter`, `ContactResolver` (cache keys), and preview formatters. All of them expect the same E.164 string for the same person, so the fix must be consistent, not caller-specific.

Test state after plan 041: `swift/Tests/iMessageMaxTests/PhoneUtilsTests.swift` has `testShortInternationalWithPlusIsNotRewrittenToUS` wrapped in `XCTExpectFailure(..., strict: true)`. Once this plan fixes the bug that wrapper makes the test fail, so this plan removes it.

`isPhoneNumber` rejects anything under 10 digits, so a 5- or 6-digit short code (carrier alerts, 2FA senders) can never be treated as a phone handle. Chat handles for short codes exist in chat.db as bare digit strings.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | `Build complete!` |
| Focused | `cd swift && swift test --filter "PhoneUtilsTests|SendResolverTests|IdentityNormalizationTests|SendToolExecuteTests"` | 0 failures |
| Whole suite | `cd swift && swift test` | 0 failures |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Contacts/PhoneUtils.swift`
- `swift/Tests/iMessageMaxTests/PhoneUtilsTests.swift` (remove the expected-failure wrapper, add short-code cases)

**Out of scope** (do NOT touch, even though they look related):
- `ContactResolver` cache-key logic, `SendResolution`, `IdentityDisplayFormatter` — they call `normalizeToE164` and inherit the fix. If any of their tests fail after this change, that is a STOP condition, not a reason to edit them.
- Adding a full libphonenumber-style validator. The product only needs "do not corrupt an explicit international number".

## Git workflow

- Branch: `advisor/043-phone-normalization`
- One commit, type `fix:`. Example: `fix: honour an explicit + before applying the US default in normalizeToE164`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Reorder `normalizeToE164`

Replace the function body with:

```swift
static func normalizeToE164(_ input: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespaces)
    let digits = trimmed.filter { $0.isNumber }
    let hasPlus = trimmed.hasPrefix("+")

    guard !digits.isEmpty, digits.count <= 15 else { return nil }

    // An explicit country code wins. "+45 12 34 56 78" is Danish, not a
    // US number missing its +1, even though it has 10 digits.
    if hasPlus {
        return "+\(digits)"
    }

    // No "+": assume the North American numbering plan for 10 digits, or
    // 11 digits starting with 1.
    if digits.count == 10 {
        return "+1\(digits)"
    }
    if digits.count == 11 && digits.hasPrefix("1") {
        return "+\(digits)"
    }
    if digits.count > 11 {
        // Long bare digit strings are international numbers typed without "+".
        return "+\(digits)"
    }

    return nil
}
```

Behaviour preserved: bare 10-digit → `+1…`; bare 11-digit starting with 1 → `+1…`; `+44…` unchanged. Behaviour changed: `+45xxxxxxxx` → `+45xxxxxxxx`; inputs over 15 digits → nil (E.164 maximum); leading/trailing whitespace ignored. Behaviour for bare 11-digit strings not starting with 1 stays nil, as today.

**Verify**: `cd swift && swift build` → `Build complete!`.

### Step 2: Accept short codes in `isPhoneNumber`

Replace:

```swift
static func isPhoneNumber(_ input: String) -> Bool {
    let digits = input.filter { $0.isNumber }
    return digits.count >= 10 && digits.count <= 15
}
```

with:

```swift
/// True for anything that could be a messaging handle made of digits:
/// full numbers (10–15 digits) and carrier short codes (5–8 digits, no "+").
static func isPhoneNumber(_ input: String) -> Bool {
    let trimmed = input.trimmingCharacters(in: .whitespaces)
    let digits = trimmed.filter { $0.isNumber }
    let nonDigitsAllowed = trimmed.allSatisfy { $0.isNumber || " -()+.".contains($0) }
    guard nonDigitsAllowed else { return false }
    if digits.count >= 10 && digits.count <= 15 { return true }
    return !trimmed.hasPrefix("+") && digits.count >= 5 && digits.count <= 8
}
```

Before applying this, run `grep -rn "isPhoneNumber" swift/Sources` and read each caller. If any caller uses `isPhoneNumber` as the sole gate before calling `normalizeToE164` and then treats a nil result as an error the user sees (a short code will normalize to nil), report that in your final summary; the send path already returns `"Invalid phone number format"` for nil, which is acceptable for a short code the user tried to send to.

**Verify**: `cd swift && swift build` → `Build complete!`.

### Step 3: Update `PhoneUtilsTests`

1. Remove the `XCTExpectFailure(...)` line from `testShortInternationalWithPlusIsNotRewrittenToUS`. The assertions inside it stay.
2. Add `testOverlongInputReturnsNil` — 16 digits with `+` → nil.
3. Add `testWhitespaceIsIgnored` — `"  +4512345678 "` → `"+4512345678"`.
4. Add `testShortCodesArePhoneNumbersButDoNotNormalize` — `isPhoneNumber("55555")` true, `isPhoneNumber("+5555")` false, `isPhoneNumber("5555")` false, `normalizeToE164("55555")` nil.
5. Add `testLettersAreNotPhoneNumbers` — `isPhoneNumber("call 5551234567 now")` false (letters present), `isPhoneNumber("(555) 123-4567")` true.

**Verify**: `cd swift && swift test --filter PhoneUtilsTests` → `Executed 12 tests, with 0 failures`, and `grep -c "XCTExpectFailure" swift/Tests/iMessageMaxTests/PhoneUtilsTests.swift` → `0`.

### Step 4: Full suite

**Verify**: `cd swift && swift test` → 0 failures.

## Test plan

- `PhoneUtilsTests`: the Danish/Singapore case flips from expected-failure to passing; four new cases above.
- Existing `SendResolverTests`, `IdentityNormalizationTests`, `SendToolExecuteTests` must stay green unchanged; they cover the US paths that this plan preserves.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` → 0 failures
- [ ] `grep -c "XCTExpectFailure" swift/Tests/iMessageMaxTests/PhoneUtilsTests.swift` → `0`
- [ ] In `PhoneUtils.swift`, the `if hasPlus` branch appears before the `digits.count == 10` branch (`grep -n "hasPlus\|count == 10" swift/Sources/iMessageMax/Contacts/PhoneUtils.swift` shows the `if hasPlus` line number lower)
- [ ] `git status` shows only the two in-scope files modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Plan 041 has not landed (no `PhoneUtilsTests.swift`).
- Any test outside `PhoneUtilsTests` fails after Step 1. In particular, if `IdentityNormalizationTests` or `SendResolverTests` encoded the old `+45 → +1` behaviour, report the test and the assertion; do not change it.
- A caller of `isPhoneNumber` treats "true" as "will normalize" and crashes or misroutes on a short code (Step 2 note).

## Maintenance notes

- Reviewer should re-derive the branch order by hand against three inputs: `5551234567`, `+15551234567`, `+4512345678`. The first two must be unchanged from before, the third must be preserved verbatim.
- If a real phone-number library is ever adopted, `normalizeToE164` is the single seam; keep all nine callers on it.
- Deferred: region-aware defaults (assume the operator's country instead of `+1`). Not needed until a non-US operator appears; the `+1` default is documented behaviour.
