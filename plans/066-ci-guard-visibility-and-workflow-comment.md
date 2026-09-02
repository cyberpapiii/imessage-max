# Plan 066: CI guard visibility in diagnose, and one truthful test command across both workflows

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 639529e..HEAD -- swift/Sources/iMessageMax/Contacts/ContactResolver.swift swift/Sources/iMessageMax/Tools/Diagnose.swift swift/Tests/iMessageMaxTests/DiagnoseToolTests.swift .github/workflows/build.yml .github/workflows/release.yml`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (plan 060, the CI hang work, has landed; this plan corrects what it wrote)
- **Category**: bug / developer experience
- **Planned at**: commit `639529e`, 2026-09-01

## Why this matters

1. **`CI=true` silently disables contact loading, and `diagnose` reports
   that as healthy.** `ContactResolver.initialize` returns early when the
   `CI` environment variable is `"true"`, marking itself initialized with an
   empty cache. `diagnose` then reports `contacts.authorized: true`,
   `contacts.loaded: 0`, `status: "ready"`. An operator who happens to have
   `CI=true` exported (some shells and agent harnesses set it) gets a
   server that never resolves a single name and a diagnose tool that says
   everything is fine. The guard is correct for GitHub runners; its
   invisibility is the bug.
2. **`build.yml` explains its serial test run with a cause that is not the
   cause, and `release.yml` runs the opposite command.** The comment in
   `build.yml` blames `AsyncTimeout.sleep`'s `asyncAfter` timers for pinning
   parallel workers. The comment in `ContactResolver.swift`, written for the
   same incident (serial run 33573931260), records the actual cause: the
   Contacts XPC daemon is absent on hosted runners, and `enumerateContacts`
   retries for minutes. The `CI=true` guard fixed that. Meanwhile
   `release.yml` still runs `swift test --skip-build --parallel` and was
   green for v1.5.0. The next person to touch CI will read `build.yml`,
   conclude `asyncAfter` is unsafe, and rewrite `AsyncTimeout` for nothing.

## Current state

### (a) The guard

`swift/Sources/iMessageMax/Contacts/ContactResolver.swift:39-50`:

```swift
func initialize() throws {
    guard !isInitialized else { return }

    // GitHub-hosted macos runners report Contacts as authorized, then
    // `enumerateContacts` talks to AddressBook over XPC. The daemon is
    // not running, so Core Data retries for minutes per call and
    // `swift test` never finishes (serial run 33573931260: one
    // list_attachments test took 298s, then the next never returned).
    if ProcessInfo.processInfo.environment["CI"] == "true" {
        isInitialized = true
        return
    }
```

`ContactResolver.swift:119-121`:

```swift
func getStats() -> (initialized: Bool, handleCount: Int) {
    (isInitialized, cache.count)
}
```

Nothing records *why* the cache is empty. `ContactResolver(seedCache:)`
(`:14-17`) also sets `isInitialized = true`, which is how every test
builds one.

### (a) diagnose

`swift/Sources/iMessageMax/Tools/Diagnose.swift:135-146`:

```swift
if contactsAuthorized {
    do {
        try await resolver.initialize()
        let stats = await resolver.getStats()
        contactsLoaded = stats.handleCount
    } catch {
        contactsStatus = "\(authorizationStatus)_load_failed"
        ...
    }
} else {
```

`Diagnose.swift:155-156`:

```swift
let allGood = dbOk && contactsAuthorized
let overallStatus = allGood ? "ready" : "needs_setup"
```

`DiagnoseResult.ContactsStatus` (`Diagnose.swift:36-41`) has
`authorized: Bool, status: String, loaded: Int?, fix: String?`. The
`perm_contacts` capability (`:238-250`) switches on `authorizationStatus`
alone.

`swift/Tests/iMessageMaxTests/DiagnoseToolTests.swift` has one test
(`testResponseDoesNotContainHomeDirectory`) and injects all three probes
(`dbProbe`, `contactsProbe`, `automationProbe`) with
`ContactResolver(seedCache: [:])`. `execute(resolver:dbProbe:contactsProbe:automationProbe:)`
is at `Diagnose.swift:107-112`.

### (b) The workflows

`.github/workflows/build.yml:65-72`:

```yaml
      - name: Run tests
        # `--parallel` cannot finish on macos-26: SessionManager's cleanup
        # AsyncTimeout.sleep uses asyncAfter, and cancelled work items stay
        # until the 300s deadline (see AGENTS.md). That pins every parallel
        # worker; the suite then advances one test every ~5 minutes and hits
        # timeout-minutes. Serial is one process, so leftover timers cannot
        # starve sibling workers.
        run: swift test --skip-build
```

`build.yml:33` sets `timeout-minutes: 15`; `:56` keys the build cache with
`-serial-`.

`.github/workflows/release.yml:27-30`:

```yaml
      - name: Build and run tests
        run: |
          swift build --build-tests
          swift test --skip-build --parallel
```

`release.yml` has no `timeout-minutes`. Git history for context:
`19ba87b ci: run the suite serially on macos-26` and `4eaa82f docs: record 060 serial CI`.

`AGENTS.md:240-250` ("No Task.sleep in the service runtime") says cancelled
`asyncAfter` items stay enqueued and retain their closure, which is true
and is about memory under load, not about starving test workers. A
pending Dispatch timer does not block a process from exiting and does not
occupy an XCTest worker.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `cd swift && swift build` | `Build complete!` |
| Focused (a) | `cd swift && swift test --filter "DiagnoseToolTests\|ContactResolverTests"` | 0 failures |
| Guard under CI | `cd swift && CI=true swift test --filter DiagnoseToolTests` | 0 failures |
| Whole suite | `cd swift && swift test` | 0 failures (baseline 370 at `639529e`) |
| YAML sanity | `ruby -ryaml -e 'YAML.load_file(".github/workflows/build.yml"); YAML.load_file(".github/workflows/release.yml"); puts "ok"'` | `ok` |
| Diff the two test steps | `diff <(grep -A1 "Run tests" .github/workflows/build.yml) <(grep -A3 "Build and run tests" .github/workflows/release.yml)` | inspect by eye |

## Scope

### In scope

- `swift/Sources/iMessageMax/Contacts/ContactResolver.swift` (`initialize`, `getStats`, and one new stored property)
- `swift/Sources/iMessageMax/Tools/Diagnose.swift` (contacts block and `ContactsStatus`)
- `swift/Tests/iMessageMaxTests/DiagnoseToolTests.swift`
- `.github/workflows/build.yml` (the `Run tests` step comment only)
- `.github/workflows/release.yml` (the `Build and run tests` step only)

### Out of scope

- Removing the `CI=true` guard. It is what makes hosted runners finish.
- Changing `ContactResolver(seedCache:)` or any test that uses it.
- `AGENTS.md`'s `asyncAfter` paragraph. It is accurate about retention;
  it does not claim the worker-starvation story.
- Restoring `--parallel` in `build.yml`. Whether the suite is parallel-safe
  now that the XPC hang is guarded is a separate experiment that needs a
  `workflow_dispatch` run to prove, and the executor cannot push. This
  plan makes the two workflows agree on the command and on the reason;
  Maintenance notes say how to run the experiment.
- `iMessageMaxCommand.swift`'s startup log line (`Contacts: initialized=... handles=...`);
  it already prints the handle count, which after this plan is enough to
  notice `0`.

## Git workflow

- Branch: `advisor/066-ci-guard-visibility` from current `main`.
- Test-first for (a). Item (b) is a comment and a one-line command change
  with no unit test; verify by YAML load and by eye.
- Commit messages:
  - `test: diagnose surfaces the CI contacts guard`
  - `fix: report contacts as skipped_ci when the CI guard is active`
  - `ci: state the real cause of the serial test run and align release.yml`
- The executor does not merge or push. Report the branch name.

Standing rules:

- Never `Task.sleep` in `swift/Sources`; `LaunchdSafetyTests` enforces it.
- Never touch `.mcp.json`. (`build.yml` lists it as a path trigger; leave
  that list alone.)
- Never commit secrets.

## Steps

### Step 1: Failing test (a)

`DiagnoseToolTests` injects probes but uses a seeded resolver, which never
reaches the guard. Use a real `ContactResolver()` with `contactsProbe`
returning authorized, under `CI=true`. The environment is read at call
time from `ProcessInfo`, so set it for the process with `setenv` and
restore it in `defer`:

```swift
/// CI=true makes ContactResolver.initialize skip contact loading. diagnose
/// must say so instead of reporting an authorized, empty, "ready" store.
func testCIGuardIsVisibleInDiagnose() async throws {
    let previous = ProcessInfo.processInfo.environment["CI"]
    setenv("CI", "true", 1)
    defer {
        if let previous { setenv("CI", previous, 1) } else { unsetenv("CI") }
    }

    let result = try await DiagnoseTool.execute(
        resolver: ContactResolver(),
        dbProbe: DiagnoseToolTests.dbAccessible,
        contactsProbe: DiagnoseToolTests.contactsAuthorized,
        automationProbe: DiagnoseToolTests.automationGranted
    )

    XCTAssertEqual(result.contacts.status, "skipped_ci")
    XCTAssertEqual(result.contacts.loaded, 0)
    XCTAssertNotNil(result.contacts.fix)
    XCTAssertEqual(result.status, "needs_setup",
                   "an empty contact store is not a ready server")
}
```

`ContactResolver()` (the no-arg init) with `CI=true` never touches
`CNContactStore`, so this is hermetic on a runner. `ProcessInfo.processInfo.environment`
is re-read on each access on Darwin Foundation; if the assertion on
`status` fails with `"authorized"` while `CI` is visibly set, see STOP
conditions.

**Verify**: `swift test --filter DiagnoseToolTests` → the new test fails
on `"authorized" != "skipped_ci"`. Commit.

### Step 2: Fix (a)

`ContactResolver.swift`: add a stored property and set it in the guard:

```swift
/// True when `initialize` returned early because `CI=true` was set.
/// Surfaced by diagnose so an operator with CI exported in their shell
/// can see why no names resolve.
private var skippedForCI = false
```

In `initialize`, inside the `CI == "true"` branch, set `skippedForCI = true`
before `isInitialized = true`. Extend `getStats`:

```swift
func getStats() -> (initialized: Bool, handleCount: Int, skippedForCI: Bool) {
    (isInitialized, cache.count, skippedForCI)
}
```

Check every caller of `getStats` (`grep -rn "getStats()" swift/Sources swift/Tests`).
At `639529e` they are `Diagnose.swift:139` and `iMessageMaxCommand.swift:60`,
both of which destructure by label (`stats.handleCount`,
`stats.initialized`), so a third tuple element compiles unchanged.

`Diagnose.swift:135-146`: after `contactsLoaded = stats.handleCount`, add:

```swift
if stats.skippedForCI {
    contactsStatus = "skipped_ci"
    contactsFix = "CI=true is set in this process's environment, so contact "
        + "loading was skipped and no names will resolve. Unset CI to load contacts."
}
```

`Diagnose.swift:155`: `let allGood = dbOk && contactsAuthorized && contactsStatus != "skipped_ci"`.

`Diagnose.swift:238-250` (`perm_contacts`): the switch is on
`authorizationStatus`, not `contactsStatus`, so it still says `supported`.
That is correct; permission *is* granted. Leave it.

Update the tool's description text if it enumerates `contacts.status`
values (`grep -n "authorized\|not_determined" swift/Sources/iMessageMax/Tools/Diagnose.swift`
in the `inputSchema`/description block near `:65-95`); add `skipped_ci`
to the list if one exists.

**Verify**: `swift test --filter "DiagnoseToolTests|ContactResolverTests"` → 0 failures.
`CI=true swift test --filter DiagnoseToolTests` → 0 failures (the test
sets the variable itself, but this confirms the existing test also
tolerates the guard). `swift build` → no warnings about unused tuple
elements. Commit.

### Step 3: Workflows (b)

`.github/workflows/build.yml:66-71`: replace the comment with the real
cause and a pointer to the guard:

```yaml
      - name: Run tests
        # Serial on purpose. The 2026-09 hang (run 33573931260) was Contacts:
        # hosted macos runners report Contacts as authorized but have no
        # AddressBook daemon, and enumerateContacts retried for minutes per
        # test. ContactResolver.initialize now skips loading when CI=true
        # (GitHub sets it). Serial stays until a workflow_dispatch run of
        # `--parallel` with the guard in place is green; see plan 066.
        run: swift test --skip-build
```

`.github/workflows/release.yml:27-30`: use the same command as `build.yml`
so a release never runs a test configuration that the PR workflow does not:

```yaml
      - name: Build and run tests
        # Same command as build.yml on purpose; see its comment.
        run: |
          swift build --build-tests
          swift test --skip-build
```

Also add `timeout-minutes: 30` to the `build-and-release` job (release
builds the arm64 binary and packages after tests; 15 would be tight).
Match the indentation of `permissions:` at `release.yml:12`.

**Verify**: the YAML sanity command prints `ok`.
`grep -n "parallel" .github/workflows/*.yml` → no matches.
`grep -n "asyncAfter" .github/workflows/build.yml` → no matches. Commit.

### Step 4: Full suite

**Verify**: `cd swift && swift test` → 0 failures, ≥ 371 tests.
`CI=true swift test` → 0 failures (this is what the runner executes; the
guard must not break any test locally either).

## Test plan

- `DiagnoseToolTests` +1 (`testCIGuardIsVisibleInDiagnose`).
- Whole suite green with and without `CI=true` in the environment.
- Workflows parse; no `--parallel` remains; the `build.yml` comment names
  Contacts, not `asyncAfter`.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` → 0 failures
- [ ] `cd swift && CI=true swift test` → 0 failures
- [ ] `grep -c "skippedForCI" swift/Sources/iMessageMax/Contacts/ContactResolver.swift` → `3` or more (declaration, assignment, `getStats`)
- [ ] `grep -c '"skipped_ci"' swift/Sources/iMessageMax/Tools/Diagnose.swift` → `2` (status assignment, `allGood`)
- [ ] `grep -n "parallel" .github/workflows/build.yml .github/workflows/release.yml` → no matches
- [ ] `grep -n "asyncAfter" .github/workflows/build.yml` → no matches
- [ ] `grep -n "33573931260" .github/workflows/build.yml` → one match
- [ ] `grep -n "timeout-minutes" .github/workflows/release.yml` → one match
- [ ] `git diff --stat main..HEAD` lists only the five in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The Step 1 test cannot observe `CI=true` through `ProcessInfo` after
  `setenv` (status stays `"authorized"`). Foundation caches `environment`
  on some platforms; if it does here, the fix is an injectable environment
  reader on `ContactResolver`, which is a larger change. Report and stop.
- `getStats()` has a caller beyond the two listed that pattern-matches the
  tuple positionally (`let (a, b) = await resolver.getStats()`), which
  would stop compiling with a third element. Report the site.
- A Makefile target or script parses `contacts.status` from diagnose output
  and enumerates allowed values (`grep -rn "contacts" swift/Makefile scripts/`).
  If so, add `skipped_ci` there in the same commit and say so; if the
  parsing is stricter than a string compare, stop.
- The reviewer wants `--parallel` restored instead of `release.yml`
  serialized. That is a decision, not a drift; ask before changing the
  direction of Step 3.

## Maintenance notes

- Every early return in `ContactResolver.initialize` that leaves the cache
  empty on purpose should set a reason the way `skippedForCI` does, and
  `diagnose` should map each reason to a distinct `contacts.status`. The
  "not authorized" early return already surfaces through the probe; the CI
  one now does too.
- The two workflows must run the same `swift test` command. Check with
  `grep -h "swift test" .github/workflows/build.yml .github/workflows/release.yml | sort -u` → one line.
- To try `--parallel` again: on a branch, change only `build.yml`'s
  `run:` line, trigger `workflow_dispatch`, and require three consecutive
  green runs under `timeout-minutes: 15` before changing `release.yml` to
  match. Record the run ids in the commit message, the way `19ba87b` did
  for the serial switch.
