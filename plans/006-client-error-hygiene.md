# Plan 006: Stop leaking internal paths and error internals to MCP/HTTP clients

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 57a2ff3..HEAD -- swift/Sources/iMessageMax/Tools/ swift/Sources/iMessageMax/Server/HTTPTransport.swift swift/Tests/iMessageMaxTests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW (message-string changes only; risk is breaking tests that assert on messages)
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `57a2ff3`, 2026-06-11

## Why this matters

Tool and HTTP error responses interpolate filesystem paths and raw `error.localizedDescription` into client-facing messages. For a localhost-only server this is low severity, but these strings cross a trust boundary (the MCP client, and — if the server is ever network-exposed — arbitrary clients), and they cost nothing to clean up. Errors to clients should be stable, generic identifiers; detail belongs in the server's stderr log. The `diagnose` tool remains the sanctioned place to surface paths and setup detail — that is its job.

## Current state

- `swift/Sources/iMessageMax/Tools/Search.swift:426-439` — the pattern to fix:

```swift
        } catch let dbError as DatabaseError {
            switch dbError {
            case .notFound(let path):
                return .failure(SearchError(error: "database_not_found", message: "Database not found at \(path)"))
            case .permissionDenied(let path):
                return .failure(SearchError(error: "permission_denied", message: "Permission denied for \(path)"))
            case .queryFailed(let msg):
                return .failure(SearchError(error: "query_failed", message: msg))
            case .invalidData(let msg):
                return .failure(SearchError(error: "invalid_data", message: msg))
            }
        } catch {
            return .failure(SearchError(error: "internal_error", message: error.localizedDescription))
        }
```

- `swift/Sources/iMessageMax/Tools/GetAttachment.swift:255-262` — `"Database not found at \(path)"` via `.error(type:message:details:)`.
- `swift/Sources/iMessageMax/Tools/ListAttachments.swift:186-196` — same two `\(path)` interpolations.
- `swift/Sources/iMessageMax/Server/HTTPTransport.swift:295-300` — HTTP-level leak:

```swift
            } catch {
                return errorResponse(
                    status: .internalServerError,
                    message: "Failed to process request: \(error.localizedDescription)"
                )
            }
```

  (`errorResponse(status:message:code:)` is defined at `HTTPTransport.swift:712`.)
- There may be more sites: find them all with
  `grep -rn 'at \\(path)\|for \\(path)\|localizedDescription' swift/Sources/iMessageMax/Tools/ swift/Sources/iMessageMax/Server/`
- Logging convention for server-side detail: write to stderr like `main.swift` does — `FileHandle.standardError.write("[iMessage Max] ...".data(using: .utf8)!)`.
- `swift/Sources/iMessageMax/Tools/Diagnose.swift` — intentionally reports paths/permissions. OUT of scope.
- Tests that may assert on error messages: `ResponseContractTests.swift`, `SearchToolTests.swift`, `OverviewResponseTests.swift`, `PlaceholderTests.swift`. Check before and after.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| All tests | `cd swift && swift test` | exit 0, all pass |
| Leak sweep | `grep -rn 'at \\(path)' swift/Sources/iMessageMax/Tools/` | no matches when done |

## Scope

**In scope**:
- `swift/Sources/iMessageMax/Tools/Search.swift`, `GetAttachment.swift`, `ListAttachments.swift`, plus any additional Tools/ sites the grep sweep finds
- `swift/Sources/iMessageMax/Server/HTTPTransport.swift` (the one catch block at ~295)
- Existing test files — ONLY assertions that pin the old leaking messages
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- `Diagnose.swift` — paths there are the product.
- Error `type`/`error` identifier strings (`"database_not_found"`, `"permission_denied"`, ...) — clients may dispatch on them; only the human-readable `message` text changes.
- `DatabaseError` itself — it keeps carrying paths internally; redaction happens at the response edge.
- stderr logging content — server-local, allowed to be detailed.

## Git workflow

- Branch: `advisor/006-client-error-hygiene`
- Commit style: lowercase conventional prefix, e.g. `fix: redact paths and error internals from client-facing messages`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Define the replacement messages once

Add to `swift/Sources/iMessageMax/Database/Errors.swift` is out of scope, so instead create a tiny helper in `swift/Sources/iMessageMax/Utilities/ClientErrorMessages.swift`:

```swift
enum ClientErrorMessages {
    static let databaseNotFound = "iMessage database not found. Run the diagnose tool for setup help."
    static let permissionDenied = "Cannot read the iMessage database (Full Disk Access may be missing). Run the diagnose tool."
    static let internalError = "Internal error. Check the server log for details."
}
```

**Verify**: `cd swift && swift build` → exit 0.

### Step 2: Replace tool-level interpolations

At every site found by the sweep grep, replace `"Database not found at \(path)"` → `ClientErrorMessages.databaseNotFound` and `"Permission denied for \(path)"` → `ClientErrorMessages.permissionDenied`. Leave `queryFailed`/`invalidData` messages as is (they carry SQLite error text, not paths — acceptable). Where a generic `catch` returns `error.localizedDescription` inside a *tool* (e.g. `Search.swift:438`), keep it — MCP tool errors going to the agent are part of the contract and aid agent recovery; this plan only removes *path* interpolation at the tool level.

**Verify**: `grep -rn 'at \\(path)\|for \\(path)' swift/Sources/iMessageMax/Tools/` → no matches. `cd swift && swift build` → exit 0.

### Step 3: Fix the HTTP catch block

In `HTTPTransport.swift` (~line 295), log the detail to stderr and return the generic message:

```swift
            } catch {
                FileHandle.standardError.write(
                    "[iMessage Max] Request handling failed: \(error)\n".data(using: .utf8)!
                )
                return errorResponse(
                    status: .internalServerError,
                    message: ClientErrorMessages.internalError
                )
            }
```

Check whether `HTTPTransport.swift` already imports Foundation (it will) and whether other `errorResponse(...)` call sites in the same file interpolate error internals — apply the same treatment ONLY where the interpolated value is an internal Swift error; validation messages like "Duplicate in-flight JSON-RPC request id" are intentional protocol feedback, keep them.

**Verify**: `cd swift && swift build` → exit 0.

### Step 4: Reconcile tests

Run the full suite. Any failure should be an assertion pinning an old message string — update those assertions to the new constants. If a failure is anything other than a message-string assertion, STOP.

**Verify**: `cd swift && swift test` → all pass.

## Test plan

No new test files. The contract is enforced by the done-criteria greps plus existing contract tests (updated where they pinned old strings). If `HTTPTransportTests.swift` has a reachable error-path test, extend it with one assertion that the 500 body does not contain `"Failed to process request"`; if no such test exists, skip — do not build new HTTP test scaffolding for this.

## Done criteria

- [ ] `cd swift && swift build` exits 0; `cd swift && swift test` exits 0
- [ ] `grep -rn 'at \\(path)\|for \\(path)' swift/Sources/iMessageMax/Tools/` → no matches
- [ ] `grep -n 'localizedDescription' swift/Sources/iMessageMax/Server/HTTPTransport.swift` → no matches in client-facing response construction (stderr logging is fine)
- [ ] Error `type` identifiers unchanged: `grep -rn '"database_not_found"\|"permission_denied"' swift/Sources/iMessageMax/Tools/ | wc -l` is unchanged from before your edits (record the before count)
- [ ] No files outside the in-scope list modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- A test failure in Step 4 is not a message-string assertion.
- You find client-facing messages embedding *message content or contact data* (worse than paths) — report it as a new finding rather than silently expanding scope.
- The sweep grep turns up more than ~10 sites (the pattern is more widespread than audited; the plan's scope estimate is wrong).

## Maintenance notes

- Convention going forward: client-facing `message` strings are static or near-static; paths and Swift error dumps go to stderr. `diagnose` is the sanctioned channel for setup detail.
- Reviewer should scrutinize: that error `type` identifiers (which agents may branch on) are byte-identical to before.
