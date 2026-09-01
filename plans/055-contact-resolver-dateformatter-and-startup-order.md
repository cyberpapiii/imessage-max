# Plan 055: Tighten contact name search, fix the unlocalized date formatter, and start the transport before slow initialization

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 61e75d9..HEAD -- swift/Sources/iMessageMax/Contacts/ContactResolver.swift swift/Sources/iMessageMax/Utilities/TimeUtils.swift swift/Sources/iMessageMax/main.swift swift/Sources/iMessageMax/iMessageMaxCommand.swift swift/Sources/iMessageMax/Tools/SendResolution.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: 048 (renames `main.swift`; this plan edits the same file under its new name), 051 (`send` by-name batching interacts with `searchByName`)
- **Category**: correctness / startup latency
- **Planned at**: commit `61e75d9`, 2026-09-01

## Why this matters

Three small things a careful user notices:

1. `ContactResolver.searchByName` is a lowercase substring match over every cached contact, and an empty query matches everyone. `send` with `to: ""` or `to: " "` reaches the ambiguity path with the entire address book as candidates; `to: "a"` matches most of it. Word-boundary matching with a minimum query length gives the send path the precision the verified-send contract implies.
2. `TimeUtils` formats dates older than a week with `DateFormatter()` and `dateFormat = "MMM d"` with no locale or time zone set, so the output depends on the process locale (launchd services run with `C`/`POSIX` unless configured) and can render month names in a locale the user did not choose, and dates can be off by one near midnight because the zone is whatever the process has.
3. `main.swift` requests Contacts access and awaits `resolver.initialize()` (a full `CNContactStore` enumeration, seconds on a large address book) *before* `transport.connect()`. In HTTP mode the port is not listening until contacts finish loading, so a client that starts the server and immediately connects gets connection refused, and the Makefile `verify` loop's first iterations fail. The resolver already tolerates lazy initialization (`getStats().initialized` exists for this reason), so the transport can come up first.

## Current state

`swift/Sources/iMessageMax/Contacts/ContactResolver.swift:95-100`:

```swift
func searchByName(_ query: String) -> [(handle: String, name: String)] {
    let q = query.lowercased()
    return cache.compactMap { handle, name in
        name.lowercased().contains(q) ? (handle, name) : nil
    }
}
```

Caller: `Tools/SendResolution.swift` (the name-resolution branch around `:190-215`, which after plan 051 caps matches at 50 and batches the last-contact query). Read the ambiguity handling right after the candidate sort to see what the user gets with many matches.

`swift/Sources/iMessageMax/Utilities/TimeUtils.swift:24-27`:

```swift
} else {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    return formatter.string(from: date)
}
```

This is `formatRelative` (or similar; the function that returns "5m ago"/"3d ago"). Allocating a `DateFormatter` per call is also slow; it should be a static.

`swift/Sources/iMessageMax/main.swift:44-64` (after plan 048: `iMessageMaxCommand.swift`):

```swift
let (contactsOk, contactsStatus) = ContactResolver.authorizationStatus()
if !contactsOk && contactsStatus == "not_determined" {
    _ = try? await resolver.requestAccess()
}
try? await resolver.initialize()

// Warn if binding to a non-loopback address ...
let transport = HTTPTransport(host: host, port: port, database: database, resolver: resolver)
try await transport.connect()
try await transport.waitForTermination()
```

The stdio branch (`:65-69`) constructs `MCPServerWrapper` and `StdioTransport` after the same initialization; the same reordering applies there (an MCP client waits for `initialize` on stdin, and the server should answer promptly).

`ContactResolver.initialize()` is idempotent (read it; it sets an `initialized` flag and the cache). Tool calls that need names call `resolve(handle)` which returns nil for unknown handles when the cache is empty; so a tool call that races initialization returns handles without names rather than failing. That is acceptable for the first second of uptime.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | `Build complete!` |
| Focused | `cd swift && swift test --filter "ContactResolverTests|SendResolverTests|TimeUtilsTests|HTTPTransportIntegrationTests"` | 0 failures |
| Whole suite | `cd swift && swift test` | 0 failures |
| Startup timing | `cd swift && swift build -c release && ( .build/release/imessage-max --http --port 8099 & sleep 0.3; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8099/health; kill %1 )` | `200` (or whatever the health endpoint returns; check `HTTPTransport.swift` for the route) |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Contacts/ContactResolver.swift` (`searchByName` only)
- `swift/Sources/iMessageMax/Utilities/TimeUtils.swift`
- `swift/Sources/iMessageMax/iMessageMaxCommand.swift` (formerly `main.swift`)
- `swift/Sources/iMessageMax/Tools/SendResolution.swift` (only if the empty-query guard belongs at the call site; prefer the resolver)
- Tests: `ContactResolverTests.swift`, `TimeUtilsTests.swift` (create either if absent)

**Out of scope** (do NOT touch, even though they look related):
- `PhoneUtils` (plan 043), `SendVerifier`, the send AppleScript path.
- Contact cache refresh policy (`CNContactStoreDidChange` observation). Deferred.
- `HTTPTransport` internals.

## Git workflow

- Branch: `advisor/055-resolver-dates-startup`
- Commits: `fix: match contact names on word boundaries and reject empty queries`; `fix: pin the relative date formatter to a fixed locale and the current time zone`; `perf: bring the transport up before enumerating contacts`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: `searchByName`

Replace with:

```swift
/// Case-insensitive match on word starts ("jo" matches "John Smith" and "Mary Jo",
/// not "Major"). Queries under two characters match nothing.
func searchByName(_ query: String) -> [(handle: String, name: String)] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard q.count >= 2 else { return [] }
    let queryWords = q.split(separator: " ").map(String.init)
    return cache.compactMap { handle, name in
        let nameWords = name.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        // Every query word must prefix some name word.
        let ok = queryWords.allSatisfy { qw in nameWords.contains { $0.hasPrefix(qw) } }
        return ok ? (handle, name) : nil
    }
}
```

Then read the `SendResolution` name branch and confirm an empty candidate list produces the existing "no contact found" error rather than an ambiguity error.

Add `ContactResolverTests` cases: `testEmptyQueryMatchesNothing`, `testSingleCharacterMatchesNothing`, `testPrefixMatchesWordStart` ("jo" matches "John Smith", "Mary Jo Baker"; not "Major Tom"), `testMultiWordQueryRequiresAllWords` ("jo sm" matches "John Smith" only). Use whatever injection the resolver has for a test cache (there is a `ToolTestSupport` resolver fixture or an initializer taking a cache; read `ContactResolver.swift` and existing tests).

**Verify**: `swift test --filter "ContactResolverTests|SendResolverTests"` → 0 failures. If a `SendResolverTests` case relied on substring matching in the middle of a word, STOP and report the case.

### Step 2: Date formatter

In `TimeUtils.swift` add:

```swift
private static let monthDayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "MMM d"
    return f
}()
```

and use it at `:24-27`. `DateFormatter` is thread-safe for formatting on Apple platforms since iOS 7/macOS 10.9; a static is fine. Check the file for other `DateFormatter()` or `ISO8601DateFormatter()` allocations per call (the "Format date as ISO 8601" function right below) and make them statics too with an explicit `timeZone`.

Add `TimeUtilsTests.testOldDateFormatsAsEnglishMonthDay`: a date 30 days ago formats as `"<Mon> <d>"` matching `^[A-Z][a-z]{2} \d{1,2}$` regardless of `Locale.current`; run the test with `LANG=fr_FR.UTF-8 swift test --filter TimeUtilsTests` as well to prove locale independence.

**Verify**: both invocations → 0 failures.

### Step 3: Startup order

In `iMessageMaxCommand.swift`, move the Contacts authorization + `initialize()` block *after* `transport.connect()` in the HTTP branch, wrapped in a detached task so `waitForTermination()` is reached immediately:

```swift
try await transport.connect()
Task {
    let (contactsOk, contactsStatus) = ContactResolver.authorizationStatus()
    if !contactsOk && contactsStatus == "not_determined" {
        _ = try? await resolver.requestAccess()
    }
    try? await resolver.initialize()
    Log.info("Contacts: \(resolver.getStats())")   // or the stderr write the file already uses, if plan 053 has not landed
}
try await transport.waitForTermination()
```

For the stdio branch, start the same task before `server.start(transport:)`. `requestAccess()` may show a system prompt; that is unchanged, only later by a few milliseconds.

Confirm `ContactResolver.initialize()` and `resolve(_:)` are safe to call concurrently (the class is an actor or uses a lock; `nonisolated(unsafe) let store` at `:10` is the only unsafe marker and it is a `let`). If `initialize()` mutates `cache` without isolation, STOP.

**Verify**: startup timing command in the table → the health endpoint answers within 0.3 s of launch; `swift test --filter HTTPTransportIntegrationTests` → 0 failures; run `swift run imessage-max --http` once interactively and confirm the Contacts status line still appears on stderr.

### Step 4: Full suite

**Verify**: `cd swift && swift test` → 0 failures.

## Test plan

- `ContactResolverTests` +4, `TimeUtilsTests` +1 (run twice, two locales).
- Startup order verified by the timing command; no unit test (it would need a slow fake contact store; not worth it).

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` → 0 failures
- [ ] `LANG=fr_FR.UTF-8 swift test --filter TimeUtilsTests` → 0 failures
- [ ] `grep -n "name.lowercased().contains(q)" swift/Sources/iMessageMax/Contacts/ContactResolver.swift` → no matches
- [ ] `grep -n "DateFormatter()" swift/Sources/iMessageMax/Utilities/TimeUtils.swift` → only inside static initializers
- [ ] In `iMessageMaxCommand.swift`, the line containing `transport.connect()` has a lower line number than the line containing `resolver.initialize()` (`grep -n "transport.connect()\|resolver.initialize()"`)
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- A `SendResolverTests` case depends on mid-word substring matching.
- `ContactResolver` is not safe for concurrent `initialize()`/`resolve()`.
- The health endpoint or the first `initialize` response depends on contact names (it should not; check `HTTPTransport` for any use of `resolver` during `connect()`).

## Maintenance notes

- `searchByName` is the only fuzzy human-name entry point on the send path. Any loosening should come with a `SendResolverTests` case showing the ambiguity error still fires for a common first name.
- Deferred: observe `CNContactStoreDidChange` and refresh the cache; today the cache is process-lifetime.
