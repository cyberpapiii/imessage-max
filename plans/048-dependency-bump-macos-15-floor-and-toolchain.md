# Plan 048: Bump dependencies, raise the floor to macOS 15, and pin the moving parts

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 61e75d9..HEAD -- swift/Package.swift swift/Package.resolved swift/Sources/iMessageMax/main.swift swift/Sources/iMessageMax/Server/ServerExtensions.swift swift/Sources/iMessageMax/Server/ModernProtocol.swift swift/Sources/iMessageMax/Server/ToolRegistry.swift swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift AGENTS.md docs/conformance-baseline.yml README.md swift/README.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MEDIUM
- **Depends on**: 040 (CI must be green on `macos-26` first, or you cannot tell a dependency regression from a runner failure); 044 (the AsyncTimeout gate fix must land before this plan rewrites its lock)
- **Category**: dependencies / modernization
- **Planned at**: commit `61e75d9`, 2026-09-01

## Why this matters

The resolved dependency graph is eight months behind: hummingbird 2.21.1 (latest 2.26.0), swift-nio 2.94.0 (2.102.0), swift-log 1.9.1 (1.15.0), swift-collections 1.3.0 (1.6.0), argument-parser 1.7.0 (1.8.2). The upstream swift-sdk is stalled at 0.12.1 and the package requests `from: "0.12.0"`, so a future 0.13 with a breaking `Server` API would be picked up silently by `swift package update`. The macOS floor is 14 while the only operator machine, the CI runner, and the release build all run 26; the floor blocks `Synchronization.Mutex` (macOS 15+), which is the idiomatic replacement for the four `NSLock` + `@unchecked Sendable` boxes in the server. The `-parse-as-library` unsafe flag exists only because `@main` lives in `main.swift`; renaming the file removes the flag and the "unsafe flags" warning any downstream consumer of the package would see.

A scratch trial of this exact upgrade (tools-version 6.3, all deps latest) built clean and passed 275/278 tests, the 3 failures being `IconMetadataTests` cases that depend on the working-tree path and fail in any copy. Tools-version 6.2 with the "upcoming features" bundle produced 31 errors and is not recommended.

## Current state

`swift/Package.swift` at `61e75d9`:

```swift
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "imessage-max",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "imessage-max", targets: ["iMessageMax"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.19.0"),
    ],
    targets: [
        .executableTarget(
            name: "iMessageMax",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "Sources/iMessageMax",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .testTarget(
            name: "iMessageMaxTests",
            dependencies: [
                "iMessageMax",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            path: "Tests/iMessageMaxTests",
            exclude: ["SendManualValidation.md"]
        ),
    ]
)
```

`swift/Package.resolved` is tracked in git (`.gitignore:96` lists it but it was committed before that line was added; `git ls-files swift/Package.resolved` prints the path). Pins at `61e75d9` that this plan moves:

| Package | Pinned | Latest (2026-09-01) |
|---------|--------|---------------------|
| hummingbird | 2.21.1 | 2.26.0 |
| swift-nio | 2.94.0 | 2.102.0 |
| swift-log | 1.9.1 | 1.15.0 |
| swift-argument-parser | 1.7.0 | 1.8.2 |
| swift-collections | 1.3.0 | 1.6.0 |
| async-http-client | 1.30.3 | 1.36.1 |
| swift-sdk | 0.12.1 | 0.12.1 (unchanged upstream) |

`swift/Sources/iMessageMax/main.swift:1-11`:

```swift
import Foundation
import ArgumentParser
import MCP

@main
struct iMessageMax: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "imessage-max",
        abstract: "MCP server for iMessage",
        version: Version.current
    )
```

Swift refuses `@main` in a file named `main.swift` unless `-parse-as-library` is passed. Renaming the file to anything else (convention: `iMessageMaxCommand.swift`) makes the flag unnecessary.

Lock sites (`grep -rn "NSLock\|nonisolated(unsafe)" swift/Sources`):

- `Server/ServerExtensions.swift:94-101` — `ToolHandlerRegistry: @unchecked Sendable` with `private let lock = NSLock()`.
- `Server/ModernProtocol.swift:44-46` — `CatalogCache` with `private let lock = NSLock()`; comment at `:41` says it deliberately mirrors the registry idiom.
- `Server/ToolRegistry.swift:11-13` — `private static let boundLock = NSLock()` guarding two `nonisolated(unsafe) private static var` bindings.
- `Utilities/AsyncTimeout.swift:53` — `ResumeGate` lock (plan 044 fixes its logic; this plan only swaps the primitive).
- `Server/ModernProtocol.swift:257,265` — `nonisolated(unsafe) static let` for immutable `[String: Any]` (fine; `Any` is not Sendable, and these are never mutated. Leave them).
- `Contacts/ContactResolver.swift:10` — `nonisolated(unsafe) let store = CNContactStore()` (leave; Apple type).

Toolchain: local Swift 6.3.3 / Xcode 26.6; CI runner `macos-26` after plan 040. macOS floor references in docs: `README.md:406` ("macOS 14+ (Sonoma or later)"), `swift/README.md:44` ("macOS 14+ (Sonoma)"). The Homebrew Formula (`swift/Formula/imessage-max.rb`, note the path under `swift/`) has `depends_on macos: :sonoma` at line 14; plan 040 adds `depends_on arch: :arm64` beside it.

Conformance: `AGENTS.md:156-159` and `docs/conformance-baseline.yml:4-7` run `npx @modelcontextprotocol/conformance` unpinned. npm `latest` is 0.1.16; the `alpha` tag (0.2.0-alpha.11) is what tracks the 2026-07-28 draft the modern lane targets.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Resolve | `cd swift && swift package resolve` | exits 0; `Package.resolved` updated |
| Update deps | `cd swift && swift package update` | exits 0 |
| Build | `cd swift && swift build` | `Build complete!`, zero warnings mentioning `unsafeFlags` |
| Whole suite | `cd swift && swift test` | 0 failures |
| Show graph | `cd swift && swift package show-dependencies` | tree with versions listed above |
| Launchd rule | `cd swift && swift test --filter LaunchdSafetyTests` | 0 failures |

## Scope

**In scope** (the only files you should modify):
- `swift/Package.swift`, `swift/Package.resolved`
- `swift/Sources/iMessageMax/main.swift` → renamed to `swift/Sources/iMessageMax/iMessageMaxCommand.swift` (via `git mv`)
- `swift/Sources/iMessageMax/Server/ServerExtensions.swift`, `Server/ModernProtocol.swift`, `Server/ToolRegistry.swift`, `Utilities/AsyncTimeout.swift` (lock swap only)
- `AGENTS.md` (conformance pin, macOS floor, file rename), `docs/conformance-baseline.yml` (pin), `README.md:406`, `swift/README.md:44`
- `swift/Formula/imessage-max.rb` (change `:sonoma` to `:sequoia`)

**Out of scope** (do NOT touch, even though they look related):
- Migrating off swift-sdk `Server` or adopting a different MCP library. There is nothing to migrate to; the pin is the whole action.
- Enabling upcoming-feature flags (`StrictConcurrency` is already implied by Swift 6 language mode; `ExistentialAny`, `InternalImportsByDefault` etc. produced 31 errors in trial and are rejected).
- Replacing `nonisolated(unsafe)` on `ContactResolver.store` or the `[String: Any]` statics.
- Adopting Swift Testing. Rejected this round.
- CI workflow files — plan 040.

## Git workflow

- Branch: `advisor/048-deps-and-floor`
- Commits, in order: `build: pin swift-sdk to 0.12.x and bump hummingbird/argument-parser floors`; `build: raise the deployment floor to macOS 15 and tools-version 6.3`; `refactor: rename main.swift so -parse-as-library is unnecessary`; `refactor: replace NSLock boxes with Synchronization.Mutex`; `docs: pin the conformance suite and record the macOS 15 floor`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Baseline

Run `cd swift && swift test` and record the count (expect 278 at `61e75d9` plus whatever earlier plans added). Run `git ls-files swift/Package.resolved` to confirm it is tracked.

**Verify**: 0 failures; count recorded.

### Step 2: Pin and bump in `Package.swift`

Change the dependency block to:

```swift
dependencies: [
    // Upstream is stalled at 0.12.1; an exact-minor pin keeps `swift package update`
    // from pulling a breaking 0.13 unreviewed.
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.1")),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.26.0"),
],
```

Then `cd swift && swift package update`.

**Verify**: `swift package show-dependencies | grep -E "hummingbird|swift-nio |swift-log|argument-parser|swift-sdk"` shows hummingbird 2.26.x, swift-nio 2.102.x, swift-log 1.15.x, argument-parser 1.8.2, swift-sdk 0.12.1. `swift build && swift test` → 0 failures. If a test fails here, the dependency bump alone caused it: STOP and report the test name and the dependency diff.

### Step 3: tools-version 6.3 and macOS 15

Change line 1 to `// swift-tools-version: 6.3` and `platforms` to `[.macOS(.v15)]`.

**Verify**: `swift build` → `Build complete!`; `swift test` → 0 failures. Check for any `@available(macOS 15` guards now redundant: `grep -rn "available(macOS 15" swift/Sources` → if matches, remove the guard and the fallback branch (each one is a small cleanup; list them in the commit).

### Step 4: Rename `main.swift` and drop the unsafe flag

```bash
cd swift && git mv Sources/iMessageMax/main.swift Sources/iMessageMax/iMessageMaxCommand.swift
```

Remove the `swiftSettings: [.unsafeFlags(["-parse-as-library"])]` block from the executable target. Update `AGENTS.md`'s project-structure section (it lists `main.swift`; find it with `grep -n "main.swift" AGENTS.md README.md swift/README.md docs -r`) to the new name.

**Verify**: `swift build 2>&1 | grep -i "unsafe\|parse-as-library"` → no output; `swift build` → `Build complete!`; `swift run imessage-max --version` prints the version; `grep -rn "main.swift" AGENTS.md README.md swift/README.md docs` → no stale references (the validation checklist under `docs/validation/` may mention it historically; leave dated historical documents alone).

### Step 5: `Synchronization.Mutex`

For each of the four sites, replace the `NSLock` + mutable fields pattern with `Mutex<State>`. Exemplar for `ToolRegistry.swift:11-13`:

```swift
import Synchronization

private struct Bound {
    var database: Database?
    var resolver: ContactResolver?
}
private static let bound = Mutex(Bound())
```

and every `boundLock.lock(); defer { boundLock.unlock() }; boundDatabase = db` becomes `bound.withLock { $0.database = db }`. `Mutex` is `Sendable` when its state is; `Database` and `ContactResolver` must be `Sendable` for this to compile. If they are not, wrap the whole `Bound` in `nonisolated(unsafe)`-free form by keeping the fields `nonisolated(unsafe)` and using the `Mutex<Void>` purely as a lock: `private static let bound = Mutex(())` with `bound.withLock { _ in ... }`. That still removes the `NSLock` and the manual lock/unlock pairs.

Apply the same to `ToolHandlerRegistry` (`ServerExtensions.swift:94-101`; the class can drop `@unchecked` once its only stored property is a `Mutex`), `CatalogCache` (`ModernProtocol.swift:44-46`; update the comment at `:41`), and `ResumeGate` (`AsyncTimeout.swift:51-98`; keep the exact logic from plan 044, only swap the primitive; `cancelAndResume` releases the lock before resuming, so structure it as `let (item, cont) = state.withLock { ... return (item, cont) }` then act outside).

**Verify**: `grep -rn "NSLock" swift/Sources` → no matches; `grep -rn "@unchecked Sendable" swift/Sources` → only sites unrelated to these four (list them in the report); `swift build` → 0 warnings about Sendable; `swift test` → 0 failures; `swift test --filter "AsyncTimeoutTests|ModernDispatcherTests|ToolRegistryBindingTests"` → 0 failures across three consecutive runs.

### Step 6: Pin the conformance suite and record the floor

- `AGENTS.md:156-159` and `docs/conformance-baseline.yml:4-7`: change `npx @modelcontextprotocol/conformance` to `npx @modelcontextprotocol/conformance@0.2.0-alpha.11` (the alpha line tracks the 2026-07-28 draft the modern lane implements; `latest` 0.1.16 does not know the draft suite). Add one sentence in `AGENTS.md` saying why the alpha tag is pinned.
- `README.md:406`: "macOS 15+ (Sequoia or later)". `swift/README.md:44`: same.
- `swift/Formula/imessage-max.rb`: change `depends_on macos: :sonoma` to `depends_on macos: :sequoia`.

**Verify**: `grep -rn "conformance " AGENTS.md docs/conformance-baseline.yml | grep -v "@0.2.0-alpha.11"` → no unpinned invocations; `grep -rn "macOS 14" README.md swift/README.md AGENTS.md` → no matches; `ruby -c swift/Formula/imessage-max.rb` → `Syntax OK`; `grep -n "macos: :sequoia" swift/Formula/imessage-max.rb` → one match.

### Step 7: Full verification

**Verify**: `cd swift && swift build && swift test` → 0 failures, same count as Step 1. `swift build -c release` → `Build complete!`.

## Test plan

- No new tests. The dependency bump is verified by the whole suite, the lock swap by the three concurrency test classes run three times each, the rename by `--version`.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` → 0 failures, count equals Step 1
- [ ] `head -1 swift/Package.swift` → `// swift-tools-version: 6.3`
- [ ] `grep -n "macOS(.v15)" swift/Package.swift` → one match
- [ ] `grep -n "upToNextMinor(from: \"0.12.1\")" swift/Package.swift` → one match
- [ ] `grep -n "unsafeFlags" swift/Package.swift` → no matches
- [ ] `test ! -f swift/Sources/iMessageMax/main.swift && test -f swift/Sources/iMessageMax/iMessageMaxCommand.swift`
- [ ] `grep -rn "NSLock" swift/Sources` → no matches
- [ ] `grep -rn "conformance " AGENTS.md docs/conformance-baseline.yml | grep -vc "alpha.11"` → `0`
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Step 2 fails a test that passed in Step 1. Report the test and `git diff swift/Package.resolved`; the operator decides whether to hold a specific package back.
- Hummingbird 2.26 changes the body-streaming behaviour that `HTTPTransport.collectBodyDrainingOverflow` (`Server/HTTPTransport.swift:750-772`) works around (hummingbird issue #821). `OversizedBodyTests` failing after Step 2 is the signal. Do not remove the workaround; report.
- `Database` or `ContactResolver` Sendability forces changes outside the four lock files. Use the `Mutex<Void>` fallback described in Step 5 rather than editing those types.
- `swift package update` moves swift-sdk off 0.12.1. The pin is wrong; fix the pin, do not accept the new version.

## Maintenance notes

- `Package.resolved` is tracked on purpose (reproducible release builds). Keep it tracked; the `.gitignore:96` line is a no-op for an already-tracked file and plan 053 removes it.
- When swift-sdk ships a version that supports the 2026-07-28 revision natively, the pin and the hand-rolled lane in `ModernProtocol.swift` are the two things to revisit together.
- Review rule after this plan: no new `NSLock`. `Mutex` for shared mutable state, actors for anything with async work.
