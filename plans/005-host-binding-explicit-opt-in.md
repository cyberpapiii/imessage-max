# Plan 005: Require explicit opt-in to bind the HTTP server to non-loopback hosts

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 57a2ff3..HEAD -- swift/Sources/iMessageMax/main.swift swift/Sources/iMessageMax/Utilities/ swift/Tests/iMessageMaxTests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `57a2ff3`, 2026-06-11

## Why this matters

The HTTP transport exposes every iMessage in the user's database plus the ability to send messages as them, with no authentication — its security model is "loopback only". Today `imessage-max --http --host 0.0.0.0` binds to all interfaces with nothing but a stderr warning that nobody running a launchd service will ever see. One typo'd flag in a plist turns the user's message history into an unauthenticated LAN service. Binding non-loopback should require a second, deliberate flag.

## Current state

- `swift/Sources/iMessageMax/main.swift` — `@main struct iMessageMax: AsyncParsableCommand` (swift-argument-parser). The host option and the warning-only check:

```swift
    @Option(name: .long, help: "Host for HTTP transport (default: 127.0.0.1 for security)")
    var host: String = "127.0.0.1"
```

```swift
            // Warn if binding to a non-localhost address
            if host != "127.0.0.1" && host != "::1" && host != "localhost" {
                FileHandle.standardError.write(
                    "[WARNING] Binding to '\(host)' exposes iMessage data to the network. Use 127.0.0.1 for local-only access.\n"
                        .data(using: .utf8)!)
            }
```

- The command already uses `@Flag` (see `var http = false` in the same file) — follow that pattern.
- swift-argument-parser supports `func validate() throws` on `ParsableCommand`/`AsyncParsableCommand`; throwing `ValidationError("...")` prints the message and exits non-zero before `run()`.
- Caveat for tests: the type is named `iMessageMax` inside a module also named `iMessageMax`, and `@main` types can be awkward to reference from tests. To keep the logic unit-testable regardless, the decision function lives in a separate file.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| All tests | `cd swift && swift test` | exit 0, all pass |
| Focused | `cd swift && swift test --filter HostBindingPolicyTests` | all pass |
| Manual check | `cd swift && swift build && ./.build/debug/imessage-max --http --host 0.0.0.0 --port 18099` | exits non-zero with a validation error, server does NOT start |
| Manual check | `cd swift && ./.build/debug/imessage-max --http --host 0.0.0.0 --port 18099 --allow-external-bind` | starts (Ctrl-C to stop); warning printed |

## Scope

**In scope**:
- `swift/Sources/iMessageMax/main.swift`
- `swift/Sources/iMessageMax/Utilities/HostBindingPolicy.swift` (create)
- `swift/Tests/iMessageMaxTests/HostBindingPolicyTests.swift` (create)
- `README.md` and `swift/README.md` — only if they document `--host` (check; add one line about `--allow-external-bind` where `--host` is documented)
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- `OriginValidationMiddleware.swift`, `HTTPTransport.swift` — origin validation is a separate layer; leave it.
- The launchd plist / Makefile.
- Adding authentication — explicitly deferred (see `plans/README.md` rejected/deferred list).

## Git workflow

- Branch: `advisor/005-host-binding-opt-in`
- Commit style: lowercase conventional prefix, e.g. `feat: require --allow-external-bind for non-loopback hosts`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Create the policy function

New file `swift/Sources/iMessageMax/Utilities/HostBindingPolicy.swift`:

```swift
import Foundation

enum HostBindingPolicy {
    static let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]

    static func isLoopback(_ host: String) -> Bool {
        loopbackHosts.contains(host.lowercased())
    }

    /// nil if binding is allowed; otherwise the validation error message.
    static func validationError(host: String, allowExternalBind: Bool) -> String? {
        if isLoopback(host) || allowExternalBind { return nil }
        return """
        Refusing to bind to '\(host)': this would expose iMessage data to the network \
        without authentication. Use the default 127.0.0.1, or pass --allow-external-bind \
        if you really intend to expose the server.
        """
    }
}
```

**Verify**: `cd swift && swift build` → exit 0.

### Step 2: Wire it into the command

In `main.swift`:
- Add below the existing options:

```swift
    @Flag(name: .long, help: "Allow binding the HTTP transport to a non-loopback host (exposes iMessage data to the network; no authentication is provided)")
    var allowExternalBind = false
```

- Add a `validate()` method to the struct:

```swift
    func validate() throws {
        if http, let message = HostBindingPolicy.validationError(host: host, allowExternalBind: allowExternalBind) {
            throw ValidationError(message)
        }
    }
```

- Change the existing warning condition from the inline host comparison to `if !HostBindingPolicy.isLoopback(host)` (the warning now only fires when the user has opted in — keep it, it's still useful).

**Verify**: `cd swift && swift build` → exit 0, then both manual checks from the commands table behave as stated.

### Step 3: Tests

`swift/Tests/iMessageMaxTests/HostBindingPolicyTests.swift` (plain XCTest, no fixtures needed):

1. `testLoopbackHostsAllowedWithoutFlag` — `127.0.0.1`, `::1`, `localhost`, `LOCALHOST` → nil error.
2. `testExternalHostRejectedWithoutFlag` — `0.0.0.0`, `192.168.1.10`, `example.com` → non-nil error mentioning `--allow-external-bind`.
3. `testExternalHostAllowedWithFlag` — same hosts with `allowExternalBind: true` → nil.

**Verify**: `cd swift && swift test --filter HostBindingPolicyTests` → 3 tests pass; `cd swift && swift test` → all pass.

### Step 4: Docs touch-up

`grep -n "\-\-host" README.md swift/README.md AGENTS.md`. Where `--host` is documented, add one sentence: non-loopback hosts additionally require `--allow-external-bind`. Do not restructure anything.

**Verify**: `grep -rn "allow-external-bind" README.md swift/README.md AGENTS.md` → at least one hit (in whichever files documented `--host`).

## Test plan

Covered in Step 3, plus the two manual checks in the commands table (run them — startup behavior is the actual deliverable). Note the manual run does not need Full Disk Access to reach argument validation; validation fails before any database access.

## Done criteria

- [ ] `cd swift && swift build` exits 0
- [ ] `cd swift && swift test` exits 0; 3 new tests pass
- [ ] `./.build/debug/imessage-max --http --host 0.0.0.0 --port 18099` exits non-zero with the validation message (manual check performed)
- [ ] Stdio mode unaffected: `echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | ./.build/debug/imessage-max` still returns a tools list
- [ ] No files outside the in-scope list modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `validate()` is never called in this AsyncParsableCommand setup (verify with the manual check — if the server starts despite the validation, the ArgumentParser version may handle async commands differently; report rather than hacking around it).
- You find an existing consumer that legitimately binds non-loopback (search the repo and `~/Library/LaunchAgents` plist template in `mcpb/` or Makefile for `--host`); flag it before changing behavior.
- The warning/validation needs to consider IPv4-mapped or CIDR forms — out of scope; exact-string loopback matching is the accepted design.

## Maintenance notes

- If authentication lands later (deferred finding: the HTTP transport has no auth layer), `--allow-external-bind` should require it.
- Reviewer should scrutinize: that `validate()` only gates `--http` mode (stdio mode ignores host entirely).
