# Plan 084: Never request Contacts authorization from a headless process; refresh the contact cache on change and clear it on revoke

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 42deb1f..HEAD -- swift/Sources/iMessageMax/Contacts/ContactResolver.swift swift/Sources/iMessageMax/Contacts/ContactsAccessPolicy.swift swift/Sources/iMessageMax/iMessageMaxCommand.swift swift/Sources/iMessageMax/Server/MCPServer.swift swift/Sources/iMessageMax/Tools/Diagnose.swift swift/Tests/iMessageMaxTests/ContactsAccessPolicyTests.swift swift/Tests/iMessageMaxTests/ContactResolverTests.swift swift/Tests/iMessageMaxTests/DiagnoseToolTests.swift README.md AGENTS.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MEDIUM (changes first-run behaviour: a launchd- or client-launched
  server no longer triggers the Contacts prompt; the operator grants access
  with a new one-shot flag instead)
- **Depends on**: none
- **Category**: bug (with a security component: stale PII after revoke)
- **Planned at**: commit `42deb1f`, 2026-09-02. Baseline: `cd swift && swift build && swift test` passes with 433 tests, 0 failures.

## Why this matters

The server almost never has a terminal. launchd starts it with stdin on
`/dev/null` (`swift/launchd/local.imessage-max.plist` runs `--http --port 8080`),
Codex starts the stdio build with stdin as the JSON-RPC pipe, and both
entry points unconditionally call `CNContactStore.requestAccess` when
authorization is `notDetermined`. Nobody is at that process to answer, so
the prompt is attributed to whatever launched us, the startup `Task` sits
inside `requestAccess` until the dialog is dismissed, and every tool call
that runs in the meantime calls `initialize()`, sees `notDetermined`, marks
the resolver initialized with an empty cache, and never looks again. The
result is a server that shows phone numbers instead of names until the next
restart, even after the operator grants access.

The cache has the mirror problem. `initialize()` runs once per process: a
contact added or renamed after startup is invisible until restart, and if
the operator revokes Contacts access in System Settings the process keeps
serving the names it already loaded. The reference implementation
(openclaw/imsg, `Sources/IMsgCore/ContactResolver.swift` and
`ContactCatalog.swift`) solves all of this with a two-case
`ContactsAccessPolicy` chosen from `isatty(STDIN_FILENO)`, a refresh on
`CNContactStoreDidChange` plus a 30 s TTL, and an "unauthorized" branch that
drops the catalog. This plan ports those three behaviours and makes the
headless decision visible in `diagnose` as `contacts.status = "not_requested_headless"`
with a fix that names the one command the operator has to run.

Because macOS only lists an executable in Privacy & Security → Contacts after
it has asked once, skipping the prompt headlessly needs a way to ask
deliberately. That is the new `--request-contacts-access` one-shot flag: run
from a terminal, it triggers the prompt, prints the resulting status, and
exits.

## Current state

### Entry points request access unconditionally

`swift/Sources/iMessageMax/Server/MCPServer.swift:42-55` (stdio mode):

```swift
    private func performStartupChecks() async {
        // Check database access
        let (dbOk, dbStatus) = Database.checkAccess()
        if !dbOk {
            Log.info("Database: \(dbStatus)")
        }

        // Initialize contacts (this may show permission dialog)
        let (contactsOk, contactsStatus) = ContactResolver.authorizationStatus()
        if !contactsOk && contactsStatus == "not_determined" {
            _ = try? await resolver.requestAccess()
        }
        try? await resolver.initialize()
    }
```

`swift/Sources/iMessageMax/iMessageMaxCommand.swift:54-63` (HTTP mode), inside
`run()` after `try await transport.connect()`:

```swift
            Task {
                let (contactsOk, contactsStatus) = ContactResolver.authorizationStatus()
                if !contactsOk && contactsStatus == "not_determined" {
                    _ = try? await resolver.requestAccess()
                }
                try? await resolver.initialize()
                let stats = await resolver.getStats()
                Log.info("Contacts: initialized=\(stats.initialized) handles=\(stats.handleCount)")
            }
```

The command's flags today (`iMessageMaxCommand.swift:13-23`): `--http`,
`--host`, `--port`, `--allow-external-bind`. `validate()` at `:25-29` calls
`HostBindingPolicy.validationError`. There is no environment lookup anywhere
in the command. Nothing in `swift/Sources` calls `isatty`, observes
`CNContactStoreDidChange`, or uses `NotificationCenter`
(`grep -rn "isatty\|CNContactStoreDidChange\|NotificationCenter" swift/Sources` prints nothing).

### The resolver

`swift/Sources/iMessageMax/Contacts/ContactResolver.swift` is 127 lines. The
whole state is:

```swift
actor ContactResolver {
    private var cache: [String: String] = [:]  // handle -> name
    private var isInitialized = false
    /// True when `initialize` returned early because `CI=true` was set.
    /// Surfaced by diagnose so an operator with CI exported in their shell
    /// can see why no names resolve.
    private var skippedForCI = false
    // CNContactStore is not Sendable, so we mark it nonisolated(unsafe)
    // This is safe because we only use it from within actor-isolated methods
    nonisolated(unsafe) private let store = CNContactStore()

    init() {}

    init(seedCache: [String: String]) {
        self.cache = seedCache
        self.isInitialized = true
    }
```

`authorizationStatus()` at `:25-35` is a static probe returning
`(authorized, status)` with status in `authorized | denied | restricted | not_determined | limited | unknown`;
`requestAccess()` at `:37-39` is `try await store.requestAccess(for: .contacts)`.

`initialize()` at `:43-95` is synchronous inside the actor and one-shot:

```swift
    func initialize() throws {
        guard !isInitialized else { return }

        // GitHub-hosted macos runners report Contacts as authorized, then
        // `enumerateContacts` talks to AddressBook over XPC. ...
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            skippedForCI = true
            isInitialized = true
            return
        }

        let (authorized, _) = Self.authorizationStatus()
        guard authorized else {
            isInitialized = true
            return
        }
        ...
        try store.enumerateContacts(with: request) { contact, _ in
            ...
                if let normalized = PhoneUtils.normalizeToE164(number) {
                    self.cache[normalized] = name
                }
            ...
                self.cache[addr] = name
        }

        isInitialized = true
    }
```

Note the two defects this creates: `guard authorized else { isInitialized = true; return }`
freezes an empty cache forever when the first call happens before the grant,
and nothing ever empties `cache` after a revoke. `resolve(_:)` (`:99-108`),
`searchByName(_:)` (`:112-122`) and `getStats()` (`:124-126`, returns
`(initialized, handleCount, skippedForCI)`) read `cache` directly.

Callers: every tool calls `initialize()` at the top of `execute`
(`GetMessages.swift:249`, `GetUnread.swift:199`, `ListAttachments.swift:155`,
`ListChats.swift:227`, `GetActiveConversations.swift:152` with `try await`;
`FindChat.swift:152`, `Search.swift:366`, `Send.swift:339`, `GetChatDetails.swift:72`,
`GetContext.swift:152` with `try? await`). `Diagnose.swift:137` uses `try await`
inside a `do/catch` to produce `"<status>_load_failed"`. So a throw from
`initialize()` fails five tools outright; today that can only happen on the
first load.

Tests construct the resolver only through `ContactResolver(seedCache:)`
(66 sites) except `DiagnoseToolTests.swift:52`, which uses `ContactResolver()`
under `CI=true`.

### Diagnose

`swift/Sources/iMessageMax/Tools/Diagnose.swift:129-156`:

```swift
        let (contactsAuthorized, authorizationStatus) = contactsProbe()

        var contactsStatus = authorizationStatus
        var contactsLoaded: Int? = nil
        var contactsFix: String? = nil

        if contactsAuthorized {
            do {
                try await resolver.initialize()
                let stats = await resolver.getStats()
                contactsLoaded = stats.handleCount
                if stats.skippedForCI {
                    contactsStatus = "skipped_ci"
                    contactsFix = "CI=true is set in this process's environment, so contact "
                        + "loading was skipped and no names will resolve. Unset CI to load contacts."
                }
            } catch {
                contactsStatus = "\(authorizationStatus)_load_failed"
                ...
            }
        } else {
            contactsFix = "Grant Contacts access: System Settings -> Privacy & Security -> " +
                "Contacts -> Add your terminal app or the imessage-max executable"
        }
```

and the `perm_contacts` capability at `:243-255`:

```swift
        switch authorizationStatus {
        case "authorized", "limited":
            permContactsState = "supported"
            permContactsFix = nil
        case "denied", "restricted":
            permContactsState = "permission-gated"
            permContactsFix = contactsFix
        default:
            permContactsState = "unverified"
            permContactsFix = nil
        }
```

`DiagnoseToolTests.swift:44-63` (`testCIGuardIsVisibleInDiagnose`) is the
structural model for the new diagnose test: inject `dbProbe`, `contactsProbe`,
`automationProbe`, assert on `result.contacts.status`, `.fix`, `result.status`.
`CapabilityContractTests` only exercises `contactsProbe(ok: Bool)` returning
`authorized`/`denied` (`CapabilityContractTests.swift:18-24`); it does not pin
the `not_determined` branch.

### Reference implementation (openclaw/imsg, not visible to you)

Policy, `Sources/IMsgCore/ContactResolver.swift:43-58`:

```swift
public enum ContactsAccessPolicy: Sendable {
  case requestIfNeeded
  case skipIfNotDetermined

  /// Headless stdin (LaunchAgent, pipes, automation) must not block on a
  /// Contacts prompt that will never resolve while authorization remains
  /// `.notDetermined`. Interactive terminals keep the prompt-capable path.
  public static func forStdin(isTTY: Bool) -> ContactsAccessPolicy {
    isTTY ? .requestIfNeeded : .skipIfNotDetermined
  }

  /// Whether the current process stdin is an interactive TTY.
  public static var stdinIsTTY: Bool {
    isatty(STDIN_FILENO) != 0
  }
}
```

used at `create()` (`:105-121`):

```swift
      let initialStatus = CNContactStore.authorizationStatus(for: .contacts)
      if initialStatus == .notDetermined, accessPolicy == .requestIfNeeded {
        _ = await requestAccess(store: store)
      }
```

Commit `674f7c6` ("fix: do not prompt Contacts for headless nickname --local")
is the pattern for wiring and testing it: a static
`contactsAccessPolicy(stdinIsTTY: Bool) -> ContactsAccessPolicy { .forStdin(isTTY: stdinIsTTY) }`
on the command, called with `ContactsAccessPolicy.stdinIsTTY` in production,
and two tests asserting `false → .skipIfNotDetermined`, `true → .requestIfNeeded`.

Cache behaviour, `Sources/IMsgCore/ContactCatalog.swift`. The source is a
struct of three closures so tests never touch Contacts:

```swift
  struct ContactCatalogSource: @unchecked Sendable {
    let authorization: () -> ContactCatalogAuthorization
    let load: () throws -> [ContactCatalogRecord]
    let observeChanges: (@escaping @Sendable () -> Void) -> (() -> Void)
  }
```

The production observer (`:239-249`):

```swift
        observeChanges: { changed in
          let center = NotificationCenter.default
          let token = center.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: nil
          ) { _ in
            changed()
          }
          return { center.removeObserver(token) }
        }
```

The refresh decision (`:104-106`, `refreshInterval` defaults to 30 s, `now`
is `ProcessInfo.processInfo.systemUptime`):

```swift
        let authorizationBecameAvailable = !authorizationWasAvailable
        authorizationWasAvailable = true
        let shouldRefresh = authorizationBecameAvailable || invalidated || now() >= nextRefreshAt
```

and the apply step (`:149-168`): a successful load replaces the records; a
transient failure keeps the last good catalog (`unavailable = !hasLastGoodCatalog`);
unauthorized clears everything:

```swift
      case .unauthorized:
        authorizationWasAvailable = false
        records.removeAll(keepingCapacity: false)
        snapshots.removeAll(keepingCapacity: false)
        ...
        hasLastGoodCatalog = false
        unavailable = true
```

### Facts checked on this machine (2026-09-02)

- `isatty(0)` is `0` both when the probe binary is run with stdin from a
  pipe and when it is run by this agent harness; it is `1` only in a real
  terminal. launchd gives the service `/dev/null` on stdin.
- `/tmp`, `/var`, `/etc` are irrelevant here (that is plan 085).
- The launchd plist is a template: `make install-agent` substitutes `__BIN__`
  and installs it. Flags go in `ProgramArguments` in
  `swift/launchd/local.imessage-max.plist`; do not hand-write the installed
  copy.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `cd swift && swift build` | ends in `Build complete!` |
| Focused tests | `cd swift && swift test --filter "ContactsAccessPolicyTests\|ContactResolverTests\|DiagnoseToolTests\|CapabilityContractTests\|HostBindingPolicyTests"` | 0 failures |
| Whole suite | `cd swift && swift test` | 433 plus the new tests, 0 failures |
| Launchd rule | `cd swift && swift test --filter LaunchdSafetyTests` | 1 test, 0 failures (no `Task.sleep(` under `swift/Sources`) |
| CLI help | `cd swift && .build/debug/imessage-max --help` | lists `--contacts-policy` and `--request-contacts-access` |
| Live status | `cd swift && .build/debug/imessage-max --request-contacts-access` | prints `Contacts authorization: <status>` and exits 0 |

## Scope

**In scope** (the only files you should modify or create):

- `swift/Sources/iMessageMax/Contacts/ContactsAccessPolicy.swift` (create)
- `swift/Sources/iMessageMax/Contacts/ContactResolver.swift`
- `swift/Sources/iMessageMax/iMessageMaxCommand.swift`
- `swift/Sources/iMessageMax/Server/MCPServer.swift`
- `swift/Sources/iMessageMax/Tools/Diagnose.swift`
- `swift/Tests/iMessageMaxTests/ContactsAccessPolicyTests.swift` (create)
- `swift/Tests/iMessageMaxTests/ContactResolverTests.swift`
- `swift/Tests/iMessageMaxTests/DiagnoseToolTests.swift`
- `README.md`, `AGENTS.md` (docs only)

**Out of scope** (do NOT touch):

- `swift/launchd/local.imessage-max.plist`. The default policy (`auto`)
  already does the right thing under launchd; the flag exists for operators
  who want to force a mode. Do not add `EnvironmentVariables` to the plist.
- `SendResolution.swift:187` (`ContactResolver.authorizationStatus()` inside
  `resolveContactName`). It reads the static probe to word an error; it is
  correct as is.
- Every tool's `initialize()` call site. The method keeps its name and
  signature so no caller changes.
- `CapabilityContractTests.swift`, `ResponseContractTests.swift`: must stay
  green without edits.
- `CHANGELOG.md` (release prep owns it), `.mcp.json` (never), `Task.sleep`
  under `swift/Sources` (never; `LaunchdSafetyTests` enforces it).

## Git workflow

- Branch: `git checkout -b advisor/084-headless-contacts-access-policy main`
- Conventional commits, matching `git log` (`fix(http): bound request body reads with a 408 deadline`, `feat(discovery): ...`):
  - Commit 1 (after Step 2): `feat(contacts): add ContactsAccessPolicy with TTY detection`
  - Commit 2 (after Step 4): `fix(contacts): refresh the cache on change and TTL, clear it on revoke`
  - Commit 3 (after Step 6): `feat(cli): --contacts-policy and --request-contacts-access; diagnose reports not_requested_headless`
  - Commit 4 (after Step 7): `docs: document headless Contacts access`
- Do not push, do not merge, do not tag.

## Steps

### Step 1: Policy tests first (red)

Create `swift/Tests/iMessageMaxTests/ContactsAccessPolicyTests.swift`,
modelled on `HostBindingPolicyTests.swift` (plain `XCTestCase`, table-driven
loops, no Contacts access). Cases:

```swift
final class ContactsAccessPolicyTests: XCTestCase {
    func testAutoFollowsStdin() {
        XCTAssertEqual(ContactsAccessPolicy.forStdin(isTTY: true), .requestIfNeeded)
        XCTAssertEqual(ContactsAccessPolicy.forStdin(isTTY: false), .skipIfNotDetermined)
    }

    func testFlagOverridesStdin() {
        XCTAssertEqual(ContactsAccessPolicy.resolve(flag: .request, environment: [:], isTTY: false), .requestIfNeeded)
        XCTAssertEqual(ContactsAccessPolicy.resolve(flag: .skip, environment: [:], isTTY: true), .skipIfNotDetermined)
    }

    func testEnvironmentOverridesStdinWhenFlagIsAuto() {
        let env = ["IMESSAGE_MAX_CONTACTS_POLICY": "request"]
        XCTAssertEqual(ContactsAccessPolicy.resolve(flag: .auto, environment: env, isTTY: false), .requestIfNeeded)
        let skip = ["IMESSAGE_MAX_CONTACTS_POLICY": "skip"]
        XCTAssertEqual(ContactsAccessPolicy.resolve(flag: .auto, environment: skip, isTTY: true), .skipIfNotDetermined)
    }

    func testFlagBeatsEnvironment() {
        let env = ["IMESSAGE_MAX_CONTACTS_POLICY": "skip"]
        XCTAssertEqual(ContactsAccessPolicy.resolve(flag: .request, environment: env, isTTY: false), .requestIfNeeded)
    }

    func testUnknownEnvironmentValueFallsBackToStdin() {
        let env = ["IMESSAGE_MAX_CONTACTS_POLICY": "yes please"]
        XCTAssertEqual(ContactsAccessPolicy.resolve(flag: .auto, environment: env, isTTY: true), .requestIfNeeded)
        XCTAssertEqual(ContactsAccessPolicy.resolve(flag: .auto, environment: env, isTTY: false), .skipIfNotDetermined)
    }
}
```

**Verify**: `cd swift && swift build --build-tests` fails with
`cannot find 'ContactsAccessPolicy' in scope`. Expected red.

### Step 2: The policy type

Create `swift/Sources/iMessageMax/Contacts/ContactsAccessPolicy.swift`. No
`import Contacts`; `import Foundation` only (`isatty` and `STDIN_FILENO` come
through Foundation's Darwin re-export).

```swift
/// Whether this process may put up the macOS Contacts permission dialog.
/// A process with no terminal (launchd, an MCP client's stdio pipe) cannot
/// answer the prompt; asking from there leaves the request hanging and the
/// dialog attributed to whatever launched us. Ported from openclaw/imsg.
enum ContactsAccessPolicy: Equatable, Sendable {
    case requestIfNeeded
    case skipIfNotDetermined

    /// CLI / environment override. `auto` follows stdin.
    enum Override: String, CaseIterable, Sendable {
        case auto, request, skip
    }

    static let environmentKey = "IMESSAGE_MAX_CONTACTS_POLICY"

    static func forStdin(isTTY: Bool) -> ContactsAccessPolicy {
        isTTY ? .requestIfNeeded : .skipIfNotDetermined
    }

    /// Precedence: explicit flag, then the environment variable, then stdin.
    /// Unknown environment values are ignored (the flag is validated by
    /// ArgumentParser before it gets here).
    static func resolve(flag: Override, environment: [String: String], isTTY: Bool) -> ContactsAccessPolicy {
        switch flag {
        case .request: return .requestIfNeeded
        case .skip: return .skipIfNotDetermined
        case .auto:
            switch environment[environmentKey].flatMap(Override.init(rawValue:)) {
            case .request?: return .requestIfNeeded
            case .skip?: return .skipIfNotDetermined
            default: return forStdin(isTTY: isTTY)
            }
        }
    }

    static var stdinIsTTY: Bool { isatty(STDIN_FILENO) != 0 }
}
```

**Verify**: `cd swift && swift test --filter ContactsAccessPolicyTests` → 5 tests, 0 failures. Commit 1.

### Step 3: Resolver tests first (red)

Add to `swift/Tests/iMessageMaxTests/ContactResolverTests.swift`. These use
a new internal initializer that injects a `ContactResolver.Source` (added in
Step 4), so nothing touches CNContactStore. Use a small mutable box for the
counters (`final class Box: @unchecked Sendable { var loads = 0; var requested = false; var authorized = true; var status = "authorized" }`)
captured by the closures, and a `now` closure driven by a `var clock: TimeInterval`
in the same box.

```swift
    private func makeInjected(refreshInterval: TimeInterval = 30) -> (ContactResolver, Box) {
        let box = Box()
        let resolver = ContactResolver(
            source: ContactResolver.Source(
                authorization: { (box.authorized, box.status) },
                load: { box.loads += 1; return box.names },
                requestAccess: { box.requested = true; return true }
            ),
            refreshInterval: refreshInterval,
            now: { box.clock }
        )
        return (resolver, box)
    }
```

Cases (six tests):

1. `testHeadlessPolicySkipsRequestWhenNotDetermined`: `box.authorized = false; box.status = "not_determined"`;
   `await resolver.requestAccessIfAllowed(policy: .skipIfNotDetermined)`;
   `box.requested == false`; `await resolver.getStats().accessRequestSkippedHeadless == true`.
2. `testInteractivePolicyRequestsWhenNotDetermined`: same setup with
   `.requestIfNeeded`; `box.requested == true`; `accessRequestSkippedHeadless == false`.
3. `testNoRequestWhenAlreadyDetermined`: `box.status = "denied"`, policy
   `.requestIfNeeded`; `box.requested == false` and `accessRequestSkippedHeadless == false`
   (the flag means "we could have asked and chose not to", nothing else).
4. `testCacheRefreshesAfterTTL`: `box.names = ["+15550000001": "Old"]`;
   `try await resolver.initialize()`; `resolve("+15550000001") == "Old"`;
   `box.names["+15550000001"] = "New"`; `initialize()` again with `box.clock`
   unchanged → still `"Old"` and `box.loads == 1`; `box.clock += 31`;
   `initialize()` → `"New"`, `box.loads == 2`.
5. `testChangeNotificationInvalidatesCache`: load `"Old"`; change names;
   `await resolver.invalidate()`; `initialize()` with the clock unchanged →
   `"New"`.
6. `testRevokeClearsCachedNames`: load `"Old"`; `box.authorized = false; box.status = "denied"`;
   `box.clock += 31`; `initialize()` → `resolve(...) == nil`,
   `getStats().handleCount == 0`, and `searchByName("ol")` is empty.
7. `testLoadFailureKeepsLastGoodCache`: load `"Old"`; make `load` throw
   (`box.failNext = true`); `box.clock += 31`; `initialize()` must NOT throw
   and `resolve(...) == "Old"`. Then a fresh resolver whose very first load
   throws must throw from `initialize()` (diagnose relies on this for
   `_load_failed`).

Model the environment handling on `DiagnoseToolTests.testCIGuardIsVisibleInDiagnose`
if `CI` happens to be set in your shell: the CI guard runs before the source
is consulted, so unset `CI` for these tests with the same `setenv`/`defer`
pattern, or the loads never happen.

**Verify**: `cd swift && swift build --build-tests` fails on the unknown
`ContactResolver.Source` / `requestAccessIfAllowed` / `invalidate` names. Expected red.

### Step 4: Resolver rewrite

Rewrite `swift/Sources/iMessageMax/Contacts/ContactResolver.swift`. Keep the
file's public surface for callers: `authorizationStatus()` (static, unchanged),
`initialize() throws`, `resolve(_:)`, `searchByName(_:)`, `getStats()`,
`init()`, `init(seedCache:)`. Remove `requestAccess()` (only the two entry
points used it; they switch to the new method in Step 6). Target shape:

```swift
actor ContactResolver {
    /// Contacts access behind three closures so tests never touch
    /// CNContactStore (mirrors imsg's ContactCatalogSource). Closures run
    /// inside the actor; `@unchecked` for the same reason the old
    /// `nonisolated(unsafe) store` existed: CNContactStore is not Sendable.
    struct Source: @unchecked Sendable {
        let authorization: () -> (authorized: Bool, status: String)
        let load: () throws -> [String: String]   // normalized handle -> name
        let requestAccess: () async -> Bool

        static func live() -> Source {
            let store = CNContactStore()
            return Source(
                authorization: { ContactResolver.authorizationStatus() },
                load: { try ContactResolver.loadNames(from: store) },
                requestAccess: { (try? await store.requestAccess(for: .contacts)) ?? false }
            )
        }
    }

    private let source: Source
    private let refreshInterval: TimeInterval
    private let now: () -> TimeInterval

    private var cache: [String: String] = [:]
    private var isInitialized = false
    private var loadedAt: TimeInterval = -.infinity
    private var invalidated = false
    private var lastAuthorized = false
    private var hasLastGoodCache = false
    private var skippedForCI = false
    /// True when authorization was notDetermined and the policy said not to
    /// prompt. Surfaced by diagnose as `not_requested_headless`.
    private var accessRequestSkippedHeadless = false
    nonisolated(unsafe) private var changeObserver: (any NSObjectProtocol)?

    init() {
        self.init(source: .live(), refreshInterval: 30, now: { ProcessInfo.processInfo.systemUptime })
        // Registered here, not in the designated init, so seeded/test resolvers never observe.
        changeObserver = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            Task { await self?.invalidate() }
        }
    }

    init(seedCache: [String: String]) {
        self.init(
            source: Source(authorization: { (true, "authorized") }, load: { seedCache }, requestAccess: { true }),
            refreshInterval: .infinity,
            now: { 0 }
        )
        self.cache = seedCache
        self.isInitialized = true
        self.lastAuthorized = true
        self.hasLastGoodCache = true
    }

    init(source: Source, refreshInterval: TimeInterval, now: @escaping () -> TimeInterval) { ... }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }
```

`initialize()`:

```swift
    func initialize() throws {
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            skippedForCI = true
            isInitialized = true
            return   // keep the existing comment block explaining the CI runner hang
        }
        let (authorized, _) = source.authorization()
        let expired = now() - loadedAt >= refreshInterval
        let authorizationChanged = authorized != lastAuthorized
        guard !isInitialized || invalidated || expired || authorizationChanged else { return }

        invalidated = false
        loadedAt = now()
        lastAuthorized = authorized
        isInitialized = true

        guard authorized else {
            // Revoked or never granted: never serve names we are no longer allowed to have.
            cache.removeAll()
            hasLastGoodCache = false
            return
        }
        do {
            cache = try source.load()
            hasLastGoodCache = true
        } catch {
            // Keep the last good cache; a transient AddressBook failure must
            // not fail five tools every 30 s. First-ever failure still throws
            // so diagnose can report `<status>_load_failed`.
            Log.warning("Contacts: refresh failed, keeping \(cache.count) cached names")
            if !hasLastGoodCache { throw error }
        }
    }

    func invalidate() { invalidated = true }

    func requestAccessIfAllowed(policy: ContactsAccessPolicy) async {
        let (_, status) = source.authorization()
        guard status == "not_determined" else { return }
        switch policy {
        case .requestIfNeeded:
            let granted = await source.requestAccess()
            Log.info("Contacts: authorization requested, granted=\(granted)")
        case .skipIfNotDetermined:
            accessRequestSkippedHeadless = true
            Log.info("Contacts: authorization not determined and this process is headless; not prompting. Run `imessage-max --request-contacts-access` from a terminal once, then restart the service.")
        }
    }

    func getStats() -> (initialized: Bool, handleCount: Int, skippedForCI: Bool, accessRequestSkippedHeadless: Bool) {
        (isInitialized, cache.count, skippedForCI, accessRequestSkippedHeadless)
    }
```

`loadNames(from:)` is the old enumeration body (`:63-92`) moved into a
`private static func loadNames(from store: CNContactStore) throws -> [String: String]`
that builds and returns a fresh dictionary instead of writing `self.cache`
inside the callback. Same keys (`PhoneUtils.normalizeToE164` for phones,
lowercased emails), same name assembly.

Notes for Swift 6 language mode (tools-version 6.3, strict concurrency on):
`Source` is `@unchecked Sendable` and its closures are plain (not
`@Sendable`), which is what lets `live()` capture the non-Sendable
`CNContactStore`. `changeObserver` is `nonisolated(unsafe)` so `deinit` can
read it. The notification closure hops into the actor with `Task { await self?.invalidate() }`;
there is no `Task.sleep` anywhere (`LaunchdSafetyTests` will check).

**Verify**: `cd swift && swift test --filter "ContactResolverTests\|DiagnoseToolTests\|CapabilityContractTests\|LaunchdSafetyTests"`
→ 0 failures, the seven new resolver tests green, the existing four
`searchByName` tests untouched. Commit 2.

### Step 5: Diagnose test first (red)

Add to `DiagnoseToolTests.swift`:

```swift
    /// A headless process that declined to prompt must say so, and must point
    /// at the one command that triggers the prompt, instead of the generic
    /// System Settings advice (the binary is not listed there until it asks).
    func testHeadlessSkipIsVisibleInDiagnose() async throws {
        let resolver = ContactResolver(
            source: ContactResolver.Source(
                authorization: { (false, "not_determined") },
                load: { [:] },
                requestAccess: { XCTFail("must not prompt"); return false }
            ),
            refreshInterval: 30,
            now: { 0 }
        )
        await resolver.requestAccessIfAllowed(policy: .skipIfNotDetermined)

        let result = try await DiagnoseTool.execute(
            resolver: resolver,
            dbProbe: DiagnoseToolTests.dbAccessible,
            contactsProbe: { (false, "not_determined") },
            automationProbe: DiagnoseToolTests.automationGranted
        )

        XCTAssertEqual(result.contacts.status, "not_requested_headless")
        XCTAssertFalse(result.contacts.authorized)
        XCTAssertTrue(result.contacts.fix?.contains("--request-contacts-access") == true)
        XCTAssertEqual(result.status, "needs_setup")
        XCTAssertEqual(result.capabilities["perm_contacts"]?.state, "permission-gated")
        XCTAssertNotNil(result.capabilities["perm_contacts"]?.fix)
    }

    /// Plain not_determined (interactive process, prompt pending or dismissed)
    /// keeps today's wording and the `unverified` capability state.
    func testNotDeterminedWithoutSkipIsUnchanged() async throws {
        let result = try await DiagnoseTool.execute(
            resolver: ContactResolver(seedCache: [:]),
            dbProbe: DiagnoseToolTests.dbAccessible,
            contactsProbe: { (false, "not_determined") },
            automationProbe: DiagnoseToolTests.automationGranted
        )
        XCTAssertEqual(result.contacts.status, "not_determined")
        XCTAssertEqual(result.capabilities["perm_contacts"]?.state, "unverified")
    }
```

**Verify**: `cd swift && swift test --filter DiagnoseToolTests` → the first
new test fails on `contacts.status` (`"not_determined"` vs
`"not_requested_headless"`); the second passes. Expected red.

### Step 6: Diagnose, the two entry points, the flags

**Diagnose** (`Diagnose.swift:153-156`, the `else` branch): replace with

```swift
        } else {
            let stats = await resolver.getStats()
            if authorizationStatus == "not_determined", stats.accessRequestSkippedHeadless {
                contactsStatus = "not_requested_headless"
                contactsFix = "This process has no terminal, so it did not ask for Contacts access "
                    + "(macOS lists an app under Privacy & Security -> Contacts only after it asks). "
                    + "Run `imessage-max --request-contacts-access` from a terminal once, approve the "
                    + "prompt, then restart the service (`make install`)."
            } else {
                contactsFix = "Grant Contacts access: System Settings -> Privacy & Security -> " +
                    "Contacts -> Add your terminal app or the imessage-max executable"
            }
        }
```

and in the `perm_contacts` switch (`:243-255`) switch on `contactsStatus`
instead of `authorizationStatus`, adding `"not_requested_headless"` to the
`permission-gated` arm:

```swift
        switch contactsStatus {
        case "authorized", "limited":
            ...
        case "denied", "restricted", "not_requested_headless":
            permContactsState = "permission-gated"
            permContactsFix = contactsFix
        default:
            permContactsState = "unverified"
            permContactsFix = nil
        }
```

Check that this does not change the `skipped_ci` or `_load_failed` outcomes:
both previously fell to `default` via `authorizationStatus == "authorized"`
matching the first arm. With `contactsStatus`, `"skipped_ci"` and
`"authorized_load_failed"` now hit `default` (`unverified`, no fix). That is
the more honest state (no names are loading), and `testCIGuardIsVisibleInDiagnose`
does not assert on `perm_contacts`. If `CapabilityContractTests` fails
because of this, STOP and report which assertion; do not edit that file.

**MCPServer.swift** `performStartupChecks` (`:49-54`): replace the four lines with

```swift
        let policy = ContactsAccessPolicy.resolve(
            flag: contactsPolicy,
            environment: ProcessInfo.processInfo.environment,
            isTTY: ContactsAccessPolicy.stdinIsTTY
        )
        await resolver.requestAccessIfAllowed(policy: policy)
        try? await resolver.initialize()
```

with `contactsPolicy: ContactsAccessPolicy.Override` stored on the actor and
passed through `init(contactsPolicy: ContactsAccessPolicy.Override = .auto)`.
The stdio path is the one Codex uses: stdin is the JSON-RPC pipe, so `auto`
resolves to `.skipIfNotDetermined` there.

**iMessageMaxCommand.swift**:

```swift
    @Option(name: .long, help: "When Contacts authorization is not yet determined: auto (prompt only if stdin is a terminal), request, or skip. IMESSAGE_MAX_CONTACTS_POLICY=request|skip is honoured when auto.")
    var contactsPolicy: ContactsAccessPolicy.Override = .auto

    @Flag(name: .long, help: "Ask macOS for Contacts access once, print the resulting status, and exit. Run this from a terminal; the server never prompts when it has no terminal.")
    var requestContactsAccess = false
```

Add `extension ContactsAccessPolicy.Override: ExpressibleByArgument {}` in
this file (it imports ArgumentParser; the policy file must not). At the top
of `run()`:

```swift
        if requestContactsAccess {
            let resolver = ContactResolver()
            await resolver.requestAccessIfAllowed(policy: .requestIfNeeded)
            let (_, status) = ContactResolver.authorizationStatus()
            print("Contacts authorization: \(status)")
            return
        }
```

Then replace the HTTP-mode block (`:55-59`) with the same `resolve` +
`requestAccessIfAllowed` pair, keeping the `initialize()` and the
`Log.info("Contacts: initialized=...")` line, and pass `contactsPolicy` into
`MCPServerWrapper(contactsPolicy: contactsPolicy)` in the stdio branch.

**Verify**:
- `cd swift && swift build` → `Build complete!`
- `cd swift && swift test --filter "DiagnoseToolTests\|CapabilityContractTests\|ContactResolverTests\|ContactsAccessPolicyTests\|LaunchdSafetyTests"` → 0 failures.
- `cd swift && .build/debug/imessage-max --help` → shows both options.
- `cd swift && echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | .build/debug/imessage-max 2>err.log >/dev/null; grep -c "Contacts" err.log; rm err.log`
  → if this machine's Contacts status is `not_determined`, exactly one
  `not prompting` line; if already authorized/denied, `0` and no dialog
  appeared. Either way no dialog appears for a piped stdin.
- `cd swift && .build/debug/imessage-max --request-contacts-access` →
  `Contacts authorization: authorized` (or the real current status), exit 0.
  On a machine where the status is `not_determined` this shows the macOS
  dialog; that is the intended path.

Commit 3.

### Step 7: Docs

`README.md`:

- Replace `### 2. Grant Contacts access` (`:181-185`) body with: "Required to
  resolve phone numbers to names. The server only asks for access when it is
  started from a terminal; launchd and MCP clients start it headless, and a
  headless process never prompts. Grant access once with
  `imessage-max --request-contacts-access` from a terminal, then restart the
  service. `--contacts-policy request|skip` (or
  `IMESSAGE_MAX_CONTACTS_POLICY`) overrides the terminal detection." Keep the
  System Settings line as the manual alternative.
- Under `### Contacts showing as phone numbers` (`:400-403`) add: "If
  `diagnose` reports `contacts.status: "not_requested_headless"`, run
  `imessage-max --request-contacts-access` from a terminal. Names refresh
  within 30 s of a Contacts change and are dropped as soon as access is
  revoked; no restart needed."
- Under `### diagnose` (`:359-366`) add one line listing `contacts.status`
  values: `authorized`, `limited`, `denied`, `restricted`, `not_determined`,
  `not_requested_headless`, `skipped_ci`, `<status>_load_failed`.

`AGENTS.md`: in "Manual build and run" after the stdio example (`:45-46`) add
`./.build/release/imessage-max --request-contacts-access   # one-shot Contacts prompt, run from a terminal`
and in "Required macOS permissions" change the Contacts bullet to
"Contacts, for AddressBook resolution (granted via `--request-contacts-access`; headless starts never prompt)".

**Verify**: `grep -c "request-contacts-access" README.md AGENTS.md` → at
least 3 and 2. `cd swift && swift build && swift test` → 433 + 14 = 447
tests, 0 failures. Commit 4.

### Step 8: Live check (no code change)

`make install` is an operator action; do not run it. Instead, from `swift/`:
`.build/debug/imessage-max --http --port 8099 </dev/null 2>live.log & sleep 3; curl -s -X POST http://127.0.0.1:8099 -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H 'MCP-Protocol-Version: 2026-07-28' -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"diagnose","arguments":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}' | head -c 600; kill %1; cat live.log; rm live.log`

Expect: no dialog; `contacts.status` is this machine's real status
(`authorized` on the operator's Mac, with `loaded` > 0); the log has the
`Contacts: initialized=true handles=N` line. If the status is
`not_requested_headless` here, the diagnose `fix` names
`--request-contacts-access`.

## Test plan

- 5 new `ContactsAccessPolicyTests` (decision table: stdin, flag, env,
  precedence, unknown env value).
- 7 new `ContactResolverTests` (skip vs request vs already-determined; TTL
  refresh; change-notification invalidation; revoke clears; load failure
  keeps last-good and first failure throws).
- 2 new `DiagnoseToolTests` (`not_requested_headless` with fix and
  `permission-gated`; plain `not_determined` unchanged).
- Existing `CapabilityContractTests`, `SendResolverTests`, and all
  `ContactResolver(seedCache:)` users unchanged and green.
- `LaunchdSafetyTests` green (no `Task.sleep`).
- Manual: Step 6 pipe check and Step 8 HTTP check.

## Done criteria

- [ ] `grep -n "requestAccess()" swift/Sources/iMessageMax/Server/MCPServer.swift swift/Sources/iMessageMax/iMessageMaxCommand.swift` prints nothing; both call `requestAccessIfAllowed(policy:)`.
- [ ] `grep -n "CNContactStoreDidChange" swift/Sources/iMessageMax/Contacts/ContactResolver.swift` finds the observer; `grep -n "cache.removeAll" ...` finds the revoke branch.
- [ ] `grep -n "not_requested_headless" swift/Sources/iMessageMax/Tools/Diagnose.swift` → 2 matches (status assignment and the capability arm).
- [ ] `grep -rn "Task.sleep(" swift/Sources` prints nothing.
- [ ] `cd swift && .build/debug/imessage-max --help` lists `--contacts-policy` and `--request-contacts-access`.
- [ ] `cd swift && swift test` reports 447 tests, 0 failures.
- [ ] `git diff main -- swift/Tests/iMessageMaxTests/CapabilityContractTests.swift swift/launchd/local.imessage-max.plist` is empty.
- [ ] Four commits on `advisor/084-headless-contacts-access-policy`, not pushed.
- [ ] `plans/README.md` row added/updated.

## STOP conditions

- The drift check shows in-scope changes and the excerpts no longer match.
- `CapabilityContractTests` fails after Step 6 (the `perm_contacts` switch
  now keys on `contactsStatus`). Report the failing assertion; do not edit
  the test.
- Swift 6 strict concurrency rejects `Source` as written and the fix would
  need `@preconcurrency import Contacts` or a global mutable store. Report
  the diagnostic; do not sprinkle `nonisolated(unsafe)` across the file.
- The notification closure cannot be registered from the actor's `init()`
  without a data-race diagnostic (`self` escaping before initialization).
  Fallback to report, not to implement: register lazily in the first
  `initialize()` call.
- Any tool other than `diagnose` needs an edit to compile (the `initialize()`
  signature was meant to stay stable).
- Running the piped-stdin check in Step 6 shows a Contacts dialog.

## Maintenance notes

- Refresh cost: after the 30 s TTL, the next tool call re-enumerates the
  AddressBook (tens to hundreds of ms for a few thousand contacts) inside
  the actor. Change notifications make that mostly a no-op, but if a large
  contact store makes the periodic refresh visible in tool latency, raise
  `refreshInterval` in `init()` or move the load off the actor onto a GCD
  queue with the same last-good semantics. Do not use `Task.sleep`.
- The `CNContactStoreDidChange` observer is only registered by the
  production `init()`. If a second production initializer is ever added,
  register it there too or changes will only be picked up by the TTL.
- `perm_contacts` now keys on the derived `contactsStatus`. `skipped_ci` and
  `_load_failed` report `unverified`; if a future plan wants them
  `permission-gated` with a fix, add the strings to that arm.
- `--request-contacts-access` reuses `ContactResolver()`; it does not start
  a transport. It is safe to run while the launchd service is up, because
  TCC grants are per executable path and the running service refreshes
  within 30 s (the `authorizationChanged` branch).
- Deferred on purpose: a `--contacts-policy` value in the shipped plist
  (`auto` is correct under launchd), and touching `SendResolution`'s
  authorization wording.
