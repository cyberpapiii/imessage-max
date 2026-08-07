# Plan 036: DX hardening — make test, dual-era verify probe, mktemp in setup-signing, faster CI, dispatchInterval dedup

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat e3d14da..HEAD -- swift/Makefile .github/workflows/build.yml swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift swift/Sources/iMessageMax/Server/HTTPTransport.swift AGENTS.md`
> If the Makefile or workflow changed since this plan was written, compare
> the "Current state" excerpts before proceeding; on a structural mismatch,
> treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S-M (five small independent fixes)
- **Risk**: LOW (tooling + one mechanical dedup; no behavior change in the
  server)
- **Depends on**: none
- **Category**: DX + tech debt
- **Planned at**: commit `e3d14da`, 2026-08-07

## Why this matters

Five small frictions, batched because each is under an hour:

1. **No `make test`, and AGENTS.md never says how to run tests.**
   `grep -c "swift test" AGENTS.md` → 0. The Makefile (`swift/Makefile`)
   has build/sign/install/verify/status/logs/clean/setup-signing — no test
   target. Every agent and contributor has to already know
   `cd swift && swift test`.
2. **`make verify` only proves the legacy lane.** Its health probe
   (`swift/Makefile:55-74`) POSTs a legacy `initialize`. Since v1.3.0 the
   server is dual-era; a regression that breaks only the modern
   `server/discover` lane sails through `make install`'s verification.
3. **`setup-signing` writes the private key to fixed, predictable `/tmp`
   paths** (`/tmp/_im_key.pem`, `/tmp/_im_cert.pem`, `/tmp/_im.p12` at
   `swift/Makefile:121-151`) — world-readable location, guessable names, no
   cleanup on failure (the `rm -f` only runs if every prior step succeeds).
   `mktemp -d` fixes all three.
4. **CI serializes build and tests redundantly.** `build.yml` runs
   `swift build` then `swift test` (which rebuilds in test configuration
   anyway). `swift build --build-tests` + `swift test --skip-build
   --parallel` builds once and runs the suite in parallel.
5. **`dispatchInterval(for:)` is duplicated byte-for-byte** in
   `AsyncTimeout.swift:17-27` and `HTTPTransport.swift:688-698` — the
   Duration→DispatchTimeInterval clamp math is exactly the kind of overflow-
   sensitive code that must not drift into two versions.

## Current state

**Makefile** (`swift/Makefile`): `.PHONY: build sign install restart status
logs clean setup-signing verify help` (`:23`) — no test target. The verify
loop probes with a legacy initialize body only (`:61-64`). setup-signing's
temp usage (`:121-151`): `openssl req ... -keyout /tmp/_im_key.pem -out
/tmp/_im_cert.pem`, `openssl pkcs12 -export -out /tmp/_im.p12 ...`,
`security import /tmp/_im.p12 ...`,
`security add-trusted-cert ... /tmp/_im_cert.pem`, then
`rm -f /tmp/_im_key.pem /tmp/_im_cert.pem /tmp/_im.p12`.

**CI** (`.github/workflows/build.yml`, runs-on macos-15, workdir `swift`):

```yaml
      - name: Build
        run: swift build

      - name: Run tests
        run: swift test
```

**The duplicated function** — `AsyncTimeout.swift:17-27` (private static)
and `HTTPTransport.swift:688-698` (`private nonisolated static`), identical
bodies:

```swift
    private static func dispatchInterval(for duration: Duration) -> DispatchTimeInterval {
        let components = duration.components
        let maxWholeSeconds = Int64(Int.max / 1_000_000_000)
        let clampedSeconds = max(0, min(components.seconds, maxWholeSeconds))
        let secondNanoseconds = Int(clampedSeconds) * 1_000_000_000
        let fractionalNanoseconds = max(0, Int(components.attoseconds / 1_000_000_000))
        let nanoseconds = secondNanoseconds > Int.max - fractionalNanoseconds
            ? Int.max
            : secondNanoseconds + fractionalNanoseconds
        return .nanoseconds(nanoseconds)
    }
```

`HTTPTransport` uses its copy at `:668`
(`deadline: .now() + Self.dispatchInterval(for: timeout)`).

**Modern-lane probe shape** (for the verify addition) — the stateless lane
accepts, per `swift/Sources/iMessageMax/Server/ModernProtocol.swift`:
`method == "server/discover"` with
`params._meta["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"`
and a `clientCapabilities` object; success returns `result.serverInfo`.
Working example body (used by existing integration tests):

```json
{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"},"clientCapabilities":{}}}
```

**AGENTS.md**: has build/install workflow sections but zero mentions of
`swift test`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| Full suite | `cd swift && swift test` | exit 0, 0 failures |
| New target | `cd swift && make test` | runs the suite, exit 0 |
| Makefile syntax | `make -n -C swift test verify setup-signing` | prints recipes, no errors |
| Workflow lint | `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/build.yml'))"` | no exception |

## Scope

**In scope** (the only files you should modify):
- `swift/Makefile`
- `.github/workflows/build.yml`
- `swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift`
- `swift/Sources/iMessageMax/Server/HTTPTransport.swift` (delete the dup,
  retarget one call)
- `AGENTS.md` (add the testing commands to the build/test workflow section)
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):
- `release.yml` — release packaging is plan 035's / the operator's domain.
- The verify loop's retry structure, port, or timeout values.
- `AsyncTimeout.sleep`'s semantics (non-throwing, non-cancellable — that's
  the documented launchd-crash-safe contract; only the helper's access
  level changes).
- Any HTTPTransport logic beyond deleting the duplicate and retargeting its
  one caller.

## Git workflow

- Branch: `advisor/036-dx-makefile-ci`
- Conventional commits, one per fix area, e.g. `build: add make test`,
  `build: probe both MCP eras in make verify`,
  `build: mktemp for signing artifacts`, `ci: build once, test parallel`,
  `refactor: single dispatchInterval helper`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: `make test` + AGENTS.md

Add to `swift/Makefile` (and add `test` to `.PHONY` and the header comment
block):

```make
test: ## Run the full test suite
	@swift test
```

In AGENTS.md's build/testing workflow section, document:
`cd swift && swift test` (full suite), `swift test --filter <ClassName>`
(one class), and `make test`. Match the surrounding section's formatting.

**Verify**: `cd swift && make test` → suite runs, exit 0;
`grep -c "swift test" AGENTS.md` → ≥1.

### Step 2: Dual-era verify probe

In the `verify` target, after the existing legacy check succeeds (inside the
`if [ "$$SERVER_VERSION" = "$$BINARY_VERSION" ]` branch, before `exit 0`),
add a modern-lane probe:

```make
				MODERN=$$(curl -sf http://127.0.0.1:$(PORT) -X POST \
					-H "Content-Type: application/json" \
					-H "Accept: application/json" \
					-d '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"},"clientCapabilities":{}}}' 2>/dev/null); \
				if echo "$$MODERN" | grep -q '"serverInfo"'; then \
					echo "✓ Modern lane (2026-07-28) healthy"; \
					exit 0; \
				else \
					echo "✗ Legacy lane OK but modern server/discover failed"; \
					exit 1; \
				fi; \
```

(Adapt the exact escaping to the existing recipe's style — it's one shell
program with `\;` continuations; test with `make -n`.)

**Verify**: `make -n -C swift verify` prints a coherent recipe. If the
service is running locally, `make -C swift verify` → both checkmarks.

### Step 3: mktemp in setup-signing

Rework the temp handling in `setup-signing`: at the top of the recipe create
`SIGNTMP=$$(mktemp -d)`, replace every `/tmp/_im_key.pem` /
`/tmp/_im_cert.pem` / `/tmp/_im.p12` with `$$SIGNTMP/key.pem` /
`$$SIGNTMP/cert.pem` / `$$SIGNTMP/bundle.p12`, and make cleanup
unconditional (`trap 'rm -rf "$$SIGNTMP"' EXIT` at the start of the shell
program, replacing the tail `rm -f`). Note the recipe currently spans
multiple `@`-prefixed logical lines — each make recipe line is a separate
shell, so either join them into one shell program (preferred; the recipe
already mostly chains) or export the path via a single line. Verify the
joined recipe still prints its guidance messages in order.

**Verify**: `make -n -C swift setup-signing` → recipe prints, no fixed
`/tmp/_im` paths remain (`grep -n "_im_key\|_im_cert\|_im\.p12" swift/Makefile`
→ no matches). Do NOT actually run `make setup-signing` (it mutates the
login keychain) unless the operator asks.

### Step 4: CI build-once, test-parallel

In `.github/workflows/build.yml` replace the two steps:

```yaml
      - name: Build (including tests)
        run: swift build --build-tests

      - name: Run tests
        run: swift test --skip-build --parallel
```

**Verify**: YAML parses (command in the table). Locally sanity-check the
pair once: `cd swift && swift build --build-tests && swift test --skip-build --parallel`
→ exit 0, 0 failures. If `--parallel` surfaces test interdependence
(failures that don't occur serially), drop `--parallel`, keep
`--skip-build`, and report which tests collided.

### Step 5: dispatchInterval dedup

- In `AsyncTimeout.swift`, change the helper's access from `private static`
  to `static` and add a doc comment: overflow-clamped Duration→
  DispatchTimeInterval conversion, shared by all Dispatch-deadline code.
- In `HTTPTransport.swift`, delete the duplicate (`:688-698`) and change the
  call at `:668` to `deadline: .now() + AsyncTimeout.dispatchInterval(for: timeout)`.

**Verify**: `cd swift && swift build && swift test` → green;
`grep -rn "func dispatchInterval" swift/Sources` → exactly 1 match
(AsyncTimeout.swift).

## Test plan

No new Swift tests (tooling plan). The full suite is the regression gate for
Step 5; `make -n` is the gate for Makefile edits; the local
build-once/test-parallel run is the gate for Step 4.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && make test` runs the suite and exits 0
- [ ] `grep -c "swift test" AGENTS.md` ≥ 1
- [ ] `grep -n "server/discover" swift/Makefile` → present in verify
- [ ] `grep -n "_im_key\|_im_cert\|_im\.p12" swift/Makefile` → no matches; `grep -n "mktemp" swift/Makefile` → present
- [ ] `grep -n "build-tests" .github/workflows/build.yml` → present
- [ ] `grep -rn "func dispatchInterval" swift/Sources` → exactly 1 match
- [ ] `cd swift && swift test` exits 0; 0 failures
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `--parallel` produces failures that serial runs don't — report the
  colliding tests (that's a real isolation bug worth its own finding), ship
  `--skip-build` without `--parallel`.
- The setup-signing recipe restructure (multi-line → single shell) changes
  observable behavior you can't verify without touching the keychain —
  report the recipe diff for operator review instead of running it.
- `AsyncTimeout.dispatchInterval` being non-private tempts you to also
  "clean up" `AsyncTimeout.sleep` or HTTPTransport's deadline logic — out
  of scope; report the temptation as a note.

## Maintenance notes

- `make verify` is now the dual-era smoke test; if a third protocol era ever
  ships, add its probe here alongside the era-routing test matrix (plan 027).
- CI intentionally builds tests in the Build step so a compile error is
  attributed to "Build", not "Run tests" — keep that split when editing the
  workflow.
- `dispatchInterval` is shared precisely because its overflow clamping is
  subtle; any future change to it must keep the Int.max saturation and gets
  exercised by every timeout in the server.
