# Plan 033: Make name-based send resolution testable (consult the cache before the Contacts gate)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report, do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat e3d14da..HEAD -- swift/Sources/iMessageMax/Tools/SendResolution.swift swift/Sources/iMessageMax/Contacts/ContactResolver.swift`
> If either changed since this plan was written, compare the "Current state"
> excerpts against the live code before proceeding; on a mismatch, treat it
> as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW (a reorder inside one private function + tests; live-machine
  behavior is preserved except for one failure-message edge described below)
- **Depends on**: none. **Interaction with plan 032**: at `e3d14da` the
  `SendResolverTests` class and its `makeResolverTestDatabase()` helper live
  in `swift/Tests/iMessageMaxTests/PlaceholderTests.swift:395-477`; after
  plan 032 lands they live in `swift/Tests/iMessageMaxTests/SendResolverTests.swift`.
  Same class and helper either way, add the new tests wherever the class
  currently lives.
- **Category**: tests + testability refactor
- **Planned at**: commit `e3d14da`, 2026-08-07

## Why this matters

Sending by contact name (`send to: "Nick"`) is one of the three resolution
paths (chat_id / phone-or-email / name), and it is the only one with **zero
test coverage**, including the ambiguity path (multiple contacts match,
sorted by recency), which is the trickiest logic in the resolver.

It's untested because it's untestable as written: `resolveContactName` checks
the **live machine's** `CNContactStore` authorization status *before*
consulting the `ContactResolver`, even when the resolver was constructed
with `init(seedCache:)` and needs no Contacts access at all. On CI or any
unauthorized machine, every name-resolution test dies at the gate with
"Cannot search by name without contacts access" no matter what the seeded
cache contains. The seeded-cache initializer exists precisely for tests
(`ContactResolver.swift:14-17` sets the cache and marks the resolver
initialized); the gate just sits in front of it in the wrong order.

The fix is a reorder, not a redesign: search the cache first; only when the
cache has no match does authorization status matter (to pick the right
failure message).

## Current state

`swift/Sources/iMessageMax/Contacts/ContactResolver.swift:14-17`, the
test-seeding initializer (no Contacts framework touched):

```swift
    init(seedCache: [String: String]) {
        self.cache = seedCache
        self.isInitialized = true
    }
```

…and `searchByName` (`:95-100`) is a pure cache scan:

```swift
    func searchByName(_ query: String) -> [(handle: String, name: String)] {
        let q = query.lowercased()
        return cache.compactMap { handle, name in
            name.lowercased().contains(q) ? (handle, name) : nil
        }
    }
```

`swift/Sources/iMessageMax/Tools/SendResolution.swift:174-225`, the gate
runs before the cache is ever consulted:

```swift
    private func resolveContactName(_ name: String) async -> SendResolution.Result {
        let (authorized, _) = ContactResolver.authorizationStatus()
        guard authorized else {
            return .failure("Cannot search by name without contacts access")
        }

        let matches = await resolver.searchByName(name)
        if matches.isEmpty {
            return .failure("No contact found matching '\(name)'")
        }

        if matches.count == 1 {
            // ... resolves handle -> findDirectChatForHandle -> .success
        }

        // multi-match: builds candidates with getLastContactTime, sorts
        // most-recent-first (nil last), returns .ambiguous([RecipientCandidate])
    }
```

Existing test fixture (reuse it): `makeResolverTestDatabase()` (at
`PlaceholderTests.swift:442-477` as of `e3d14da`) creates a temp sqlite db
with handles `+16317087185` (ROWID 1) and `+15104615406` (ROWID 2), a group
chat 10 containing both, a direct chat 11 (`guid 'any;-;+16317087185'`)
containing only handle 1, and one `message` row for handle 1 (`date 1000`).
Handle 2 has no messages. Existing tests
`testResolveChatIdReturnsExactChatTarget` / 
`testResolvePhoneNumberReturnsParticipantTarget` (`:396-438`) show the
construction pattern: `SendResolver(db: Database(path: dbPath), resolver: ContactResolver())`
and a `switch` over `SendResolution.Result`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| Resolver tests | `cd swift && swift test --filter SendResolverTests` | all pass |
| Full suite | `cd swift && swift test` | exit 0, 0 failures |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Tools/SendResolution.swift` (the
  `resolveContactName` function only)
- The test file holding `SendResolverTests` (see the 032 interaction note)
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):
- `ContactResolver.swift`, no changes needed; the seeded initializer
  already does its job once the gate stops preempting it.
- The candidate sort order, `getLastContactTime`, `RecipientCandidate`
  shape, or any failure-message wording, lock behavior, don't change it.
- `findDirectChatForHandle` and its participant-count subquery.
- `Send.swift` / the send execution path, plans 021/025/026 own it.

## Git workflow

- Branch: `advisor/033-name-resolution-testability`
- Conventional commits, e.g. `fix: consult contact cache before Contacts authorization gate; test: cover name resolution`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Reorder the gate

Rewrite the top of `resolveContactName` so the cache search happens first
and the authorization check only decides the empty-result message:

```swift
    private func resolveContactName(_ name: String) async -> SendResolution.Result {
        // Search the resolver first: a seeded/test cache needs no Contacts
        // access, and on live machines the cache is what initialize()
        // populated anyway. Authorization only matters when nothing matched —
        // it distinguishes "you can't search" from "no such contact".
        let matches = await resolver.searchByName(name)
        if matches.isEmpty {
            let (authorized, _) = ContactResolver.authorizationStatus()
            guard authorized else {
                return .failure("Cannot search by name without contacts access")
            }
            return .failure("No contact found matching '\(name)'")
        }
        // ... rest of the function unchanged from `matches.count == 1` on
```

Behavior notes (intentional, record in the commit message):
- Live authorized machine: identical behavior.
- Live unauthorized machine: identical failure ("Cannot search…") because an
  uninitialized resolver's cache is empty there.
- Only edge that changes: a resolver that *has* cache entries on a machine
  that has since lost authorization will now still resolve from cache. That
  is correct, the cache is data already obtained; resolution isn't a new
  Contacts access.

**Verify**: `cd swift && swift build` → exit 0; existing tests still pass:
`swift test --filter SendResolverTests`.

### Step 2: Add the name-resolution tests

Add to the `SendResolverTests` class, following the existing switch-based
pattern (`:403-415`). All use the existing `makeResolverTestDatabase()`
fixture and `ContactResolver(seedCache:)`:

1. `testResolveNameSingleMatchReturnsParticipant`

```swift
    func testResolveNameSingleMatchReturnsParticipant() async throws {
        let dbPath = try makeResolverTestDatabase()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let contacts = ContactResolver(seedCache: ["+16317087185": "Nick Jones"])
        let resolver = SendResolver(db: Database(path: dbPath), resolver: contacts)
        let result = await resolver.resolve(chatId: nil, to: "Nick")

        switch result {
        case .failure(let message):
            XCTFail("Unexpected failure: \(message)")
        case .ambiguous:
            XCTFail("Unexpected ambiguity")
        case .success(let resolved):
            guard case .participant(let handle, let chatId) = resolved.target else {
                return XCTFail("Expected participant target")
            }
            XCTAssertEqual(handle, "+16317087185")
            XCTAssertEqual(chatId, 11)
            XCTAssertEqual(resolved.deliveredTo, ["Nick Jones"])
        }
    }
```

2. `testResolveNameMultiMatchReturnsAmbiguousSortedByRecency`, seed BOTH
   fixture handles with names matching one query:
   `["+16317087185": "Nick Jones", "+15104615406": "Andrew Jones"]`, resolve
   `to: "Jones"`. Assert:
   - the result is `.ambiguous(let candidates)` with `candidates.count == 2`;
   - `candidates[0].handle == "+16317087185"` (handle 1 has a message row;
     handle 2 has none, and nil-lastContact sorts last per
     `SendResolution.swift:207-214`);
   - `candidates[1].handle == "+15104615406"` and
     `candidates[1].lastContact == "never"` (the
     `formatCompactRelative(nil) ?? "never"` fallback at `:221`);
   - do NOT assert the exact `lastContact` string of candidates[0], it's a
     relative-time format that drifts with the clock.
3. `testResolveNameNoMatchFails`, seed
   `["+16317087185": "Nick Jones"]`, resolve `to: "Zelda"`. Assert the
   result is `.failure` and the message is one of the two known strings:

```swift
        guard case .failure(let message) = result else {
            return XCTFail("Expected failure for unmatched name")
        }
        XCTAssertTrue(
            message.contains("No contact found matching 'Zelda'")
                || message.contains("Cannot search by name without contacts access"),
            "Unexpected failure message: \(message)"
        )
```

   (Which of the two appears depends on the machine's real Contacts
   authorization, the test must pass on both authorized dev machines and
   unauthorized CI, so accept either.)

**Verify**: `cd swift && swift test --filter SendResolverTests` → all pass
(2 existing + 3 new). These MUST pass without any Contacts permission, if
you're on an authorized machine, the test's correctness on unauthorized
machines rests on Step 1's reorder; re-read the diff to confirm the search
precedes the gate.

### Step 3: Full suite

**Verify**: `cd swift && swift test` → exit 0, 0 failures.

## Test plan

Step 2, 3 new tests covering the previously untested third resolution path,
including the ambiguity branch. Exemplar: the existing switch-pattern tests
at `SendResolverTests` (`PlaceholderTests.swift:396-438` at `e3d14da`).

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` exits 0; 0 failures; 3 net-new tests
- [ ] In `resolveContactName`, `searchByName` is called before `authorizationStatus` (verify by reading the diff)
- [ ] The two failure-message strings are byte-identical to the originals (`grep -n "Cannot search by name\|No contact found matching" swift/Sources/iMessageMax/Tools/SendResolution.swift` → both present, unchanged)
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The ambiguity test's ordering assertion fails, the sort comparator or
  `getLastContactTime` doesn't behave as this plan models it; report the
  actual candidate order, do not reorder the fixture to force green.
- Any test needs Contacts authorization to pass, the reorder didn't take
  effect or a second gate exists somewhere; report the call path.
- `ContactResolver` changes seem necessary, they aren't for this scope;
  report what pushed you there.

## Maintenance notes

- Invariant established here: **name resolution consults the resolver's
  cache before any live Contacts authorization check.** If someone later
  adds an on-demand Contacts fetch to `searchByName`, the authorization gate
  must move inside that fetch, not back in front of the cache.
- The seeded-cache pathway is now the standard way to test anything
  involving contact names, no test should ever stub
  `CNContactStore`.
