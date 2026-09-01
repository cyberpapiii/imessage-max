# Plan 053: One logger, a Makefile that fails honestly, and docs that match the code

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 61e75d9..HEAD -- swift/Makefile AGENTS.md README.md swift/README.md .gitignore swift/Sources/iMessageMax/Utilities/ClientErrorMessages.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: 048 (macOS floor and `main.swift` rename change the docs this plan touches; land 048 first so the docs sweep is done once)
- **Category**: DX / docs
- **Planned at**: commit `61e75d9`, 2026-09-01

## Why this matters

Nineteen `FileHandle.standardError.write(Data("...".utf8))` calls across nine files use three different prefixes (`[iMessage Max]` eleven times, `[imessage-max]` four, `[WARNING]` once) and no shared helper, so `make logs` output cannot be filtered reliably and every new log line reinvents the string building. The Makefile `verify` target parses the server's JSON with `python3`; when the parse fails for any reason (server not up yet, python missing, a schema change) it reports "Server not responding", which has sent at least one debugging session down the wrong path. `.gitignore` lists `swift/Package.resolved` which is tracked, `AGENTS.md` describes itself as guidance to "Codex (Codex.ai/code)", the `Enrichment/` directory is described as "Image/video/audio processors" when only images are processed, and the launchd plist the Makefile restarts is not in the repo.

None of this is a bug a user sees. All of it costs the next contributor an hour.

## Current state

### stderr logging

`grep -rn "FileHandle.standardError.write" swift/Sources` at `61e75d9` returns 19 call sites: `main.swift:39,52`; `Server/MCPServer.swift:46`; `Server/HTTPTransport.swift:260,302,381,444`; `Server/ToolCallDispatch.swift:67`; `Server/DualEraStdioTransport.swift:65,77`; `Server/ModernProtocol.swift:289,350,386`; `Server/SessionManager.swift:166`; `Utilities/AppleScript.swift:347,524`; `Utilities/ClientErrorMessages.swift:16,36`. Pattern at each:

```swift
FileHandle.standardError.write(
    Data("[iMessage Max] Database: \(dbStatus)\n".utf8)
)
```

`ClientErrorMessages.swift:16,36` are the closest thing to a logging helper (they log the unsanitized detail server-side before returning a sanitized message). swift-log is already in the dependency graph via hummingbird but the project does not import `Logging` anywhere (`grep -rn "import Logging" swift/Sources` → none). Adopting swift-log is more than this plan wants; a 15-line `Log` enum writing to stderr with one prefix is the right size.

Stdio transport constraint: stdout is the MCP channel; every diagnostic must go to stderr. That is why these are not `print`.

### Makefile

`swift/Makefile:77-108` (`verify`): curls the server, pipes to `python3 -c "import json,sys; ..."` at `:88`, loops with a retry, and on exhaustion prints "Server not responding" at `:108`. `:127-132` (`status`) also uses python3. `:73-74` (`restart`) runs `launchctl` against `~/Library/LaunchAgents/local.imessage-max.plist`, which is not in the repo; `AGENTS.md` install section describes creating it by hand. `:53-54` (`test`) is `swift test` with no way to pass a filter.

### Docs drift

- `.gitignore:96` — `swift/Package.resolved` (tracked file; the ignore is inert and misleading).
- `AGENTS.md:3` — "guidance to Codex (Codex.ai/code)". The file is read by Claude Code, Codex, and humans.
- `AGENTS.md:113` — `Enrichment/ # Image/video/audio processors`. `ls swift/Sources/iMessageMax/Enrichment/` shows image processing only.
- `README.md:406` and `swift/README.md:44` — macOS floor (plan 048 updates these; this plan checks they were).
- `docs/validation/2026-04-09-release-checklist.md:126` — an `rg` command whose pattern includes `cursor`, a dated document; leave dated documents alone.
- `AGENTS.md` build/test section — after plan 048 renames `main.swift`, its structure listing must match.
- `SSEConnection.swift:94-96` comment says the keep-alive sleep is "non-cancellable"; after plan 044 it is cancellable.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | `Build complete!` |
| Whole suite | `cd swift && swift test` | 0 failures |
| Filtered test | `cd swift && make test FILTER=LaunchdSafetyTests` | runs only that class |
| Makefile parse | `cd swift && make -n verify` | prints commands, no error |
| Doc references | `grep -rn "main.swift\|macOS 14\|Codex.ai" AGENTS.md README.md swift/README.md` | no matches |

## Scope

**In scope** (the only files you should modify):
- `swift/Sources/iMessageMax/Utilities/Log.swift` (create)
- The nine files with stderr writes listed above (replace call sites only)
- `swift/Makefile`
- `swift/launchd/local.imessage-max.plist` (create; template)
- `.gitignore`, `AGENTS.md`, `README.md`, `swift/README.md`
- `swift/Sources/iMessageMax/Server/SSEConnection.swift` (comment at `:94-96` only)
- `swift/Tests/iMessageMaxTests/LogTests.swift` (create, small)

**Out of scope** (do NOT touch, even though they look related):
- Adopting swift-log / `Logger`. Deferred; see Maintenance notes.
- Changing what is logged or its wording beyond the prefix.
- `add-trusted-cert` target (by design).
- `docs/validation/*` dated documents.
- Tool `description` strings (they are the MCP contract; a separate pass if ever).

## Git workflow

- Branch: `advisor/053-logging-and-docs`
- Commits: `refactor: route stderr diagnostics through one Log helper`; `build: make verify distinguish not-running from bad-JSON, add FILTER to test, ship the launchd plist`; `docs: fix AGENTS.md, README, and .gitignore drift`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: `Log` helper

Create `swift/Sources/iMessageMax/Utilities/Log.swift`:

```swift
import Foundation

/// stderr diagnostics. stdout is the MCP stdio channel and must stay clean.
enum Log {
    enum Level: String { case info = "INFO", warning = "WARN", error = "ERROR" }

    static func write(_ level: Level, _ message: @autoclosure () -> String) {
        let line = "[imessage-max] \(level.rawValue) \(message())\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    static func info(_ message: @autoclosure () -> String) { write(.info, message()) }
    static func warning(_ message: @autoclosure () -> String) { write(.warning, message()) }
    static func error(_ message: @autoclosure () -> String) { write(.error, message()) }
}
```

Replace all 19 call sites. Choose the level from context: the `[WARNING]` bind warning in `main.swift:52` is `.warning`; anything logged in a `catch` is `.error`; startup status lines are `.info`. Keep the message text; drop the old prefix from it.

Add `LogTests.testFormatIsStable` asserting the produced line for a known input (make `write` return the formatted line, or add an internal `format(_:_:)` function the test can call).

**Verify**: `grep -rn "FileHandle.standardError.write" swift/Sources` → only the one inside `Log.swift`; `swift build && swift test` → 0 failures; `swift run imessage-max --http 2>&1 >/dev/null | head -3` shows `[imessage-max] INFO ...` lines (Ctrl-C after).

### Step 2: Makefile

- `verify` (`:77-108`): split the failure paths. If `curl` exits non-zero → "Server not responding on <url>". If curl succeeds but python3's JSON parse fails → print the first 200 bytes of the body and "Unexpected response (not JSON)". If `python3` is missing (`command -v python3`), fall back to `grep -q '"result"'`.
- `status` (`:127-132`): same python3 fallback.
- `test` (`:53-54`): `swift test $(if $(FILTER),--filter $(FILTER),)`; document `FILTER=` in the `##` help.
- `restart` (`:73-74`): add a check that the plist exists with a hint: `@test -f $(PLIST) || (echo "Install the launch agent first: make install-agent" && exit 1)`; add `install-agent` that copies `swift/launchd/local.imessage-max.plist` into `~/Library/LaunchAgents/` with the binary path substituted (`sed "s|__BIN__|$(shell pwd)/.build/release/imessage-max|"`), then `launchctl bootstrap gui/$$(id -u) <plist>`.

Create `swift/launchd/local.imessage-max.plist` from the shape `AGENTS.md`'s install section describes (Label `local.imessage-max`, ProgramArguments `__BIN__ --http --port 8080`, `RunAtLoad`, `KeepAlive`, `StandardErrorPath` under `~/Library/Logs/imessage-max.log` or whatever path `make logs` tails at line 134).

**Verify**: `cd swift && make -n verify status test restart install-agent` all print without `make` errors; `make test FILTER=LaunchdSafetyTests` runs only that class; `plutil -lint launchd/local.imessage-max.plist` → `OK`.

### Step 3: Docs and gitignore

- `.gitignore:96`: delete the `swift/Package.resolved` line; add a comment above the Swift section: `# Package.resolved is tracked on purpose for reproducible release builds.`
- `AGENTS.md:3`: "guidance to coding agents (Claude Code, Codex) and contributors."
- `AGENTS.md:113`: `Enrichment/ # Image processors (thumbnail, vision, full variants)`.
- `AGENTS.md` structure listing: confirm `iMessageMaxCommand.swift` (from 048) and add `Utilities/Log.swift`, `launchd/`.
- `AGENTS.md` install section: point at `make install-agent` instead of hand-writing the plist.
- `README.md:406`, `swift/README.md:44`: confirm plan 048 changed them to macOS 15; fix if not.
- `SSEConnection.swift:94-96`: reword to say the sleep is cancellable and the loop exits on cancellation.

**Verify**: `grep -rn "main.swift\|macOS 14\|Codex.ai\|video/audio" AGENTS.md README.md swift/README.md` → no matches; `git check-ignore swift/Package.resolved` → exit 1 (not ignored); `grep -n "non-cancellable" swift/Sources/iMessageMax/Server/SSEConnection.swift` → no matches.

### Step 4: Full suite

**Verify**: `cd swift && swift test` → 0 failures.

## Test plan

- `LogTests` (1). Everything else is verified by grep and `make -n`.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -rn "FileHandle.standardError.write" swift/Sources | grep -vc "Utilities/Log.swift"` → `0`
- [ ] `grep -rn "\[iMessage Max\]\|\[WARNING\]" swift/Sources` → no matches
- [ ] `cd swift && swift test` → 0 failures
- [ ] `cd swift && make -n verify status test restart install-agent` → exit 0
- [ ] `plutil -lint swift/launchd/local.imessage-max.plist` → `OK`
- [ ] `git check-ignore swift/Package.resolved` → exit 1
- [ ] `grep -rn "main.swift\|macOS 14\|Codex.ai\|video/audio" AGENTS.md README.md swift/README.md` → no matches
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any stderr write is inside a `nonisolated` or `@Sendable` closure where calling `Log` changes isolation and produces a Swift 6 error you cannot resolve by keeping `Log` a static enum (it should not; `Log` has no state).
- The operator's live launch agent uses a different label or path than `AGENTS.md` describes. Check `launchctl list | grep imessage` before writing the template and match the live label.

## Maintenance notes

- Deferred: swift-log adoption. `Log` is a seam; when the project wants levels controlled by an environment variable or structured metadata, replace `Log.write`'s body with a `Logger` and keep the call sites.
- Reviewers: any new `FileHandle.standardError.write` outside `Log.swift` is a regression. `print` to stdout is a protocol break in stdio mode.
