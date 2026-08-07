# Plan 037: Resolve the signing identity by hash, not by name — make setup-signing idempotent

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 58850fb..HEAD -- swift/Makefile`
> If the Makefile moved since this plan was written, re-locate the two targets
> by name (`sign:` and `setup-signing:`) rather than trusting the line numbers
> quoted below.
>
> **This plan touches the operator's login keychain.** Read the "Keychain
> safety" section before running anything. Several obvious verification
> commands are destructive and are explicitly forbidden here.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: MEDIUM (no Swift code changes, but a wrong move here can break the
  operator's code signing and cost them a Full Disk Access re-grant)
- **Depends on**: none
- **Category**: DX / tooling
- **Planned at**: commit `58850fb`, 2026-08-07
- **Found**: during the 2026-08-07 deploy, not by audit — `make setup-signing`
  failed on a real machine and the failure mode turned out to be self-inflicted
  and cumulative.

## Why this matters

`make setup-signing` exists to solve one problem: an ad-hoc-signed binary gets
a new signature on every build, so macOS revokes Full Disk Access every time,
and the operator has to re-grant it in System Settings. A stable signing
identity fixes that permanently.

The target is **not idempotent**, and its failure mode is cumulative. Each run
that cannot sign imports *another* certificate with the same common name. Once
two exist, `codesign --sign "iMessage Max Dev"` can never succeed again — it
fails with `ambiguous` — so every subsequent run adds another one. The tool
that exists to make signing permanent progressively destroys its own ability
to sign.

Observed on the operator's machine on 2026-08-07: **four** certificates named
`iMessage Max Dev` in `login.keychain-db`, of which exactly one had a private
key. `make install` could not sign until it was invoked with an explicit
certificate hash.

The second-order harm is worse than the first: the final `else` branch reports
the cause as *"Certificate imported but needs manual trust"* and tells the
operator to open Keychain Access and set Always Trust. **That diagnosis is
wrong.** Trust was fine. Following those instructions does not help, and the
operator has no way to discover the real cause from the message they were
given.

## Current state (verified against the live Makefile at `58850fb`)

**Variables** — `swift/Makefile:17-21`:

```makefile
BINARY       := .build/release/imessage-max
IDENTITY     := iMessage Max Dev
PORT         := 8080
CERT_CN      := iMessage Max Dev
```

`IDENTITY` and `CERT_CN` are the same string. Everything selects the
certificate by **common name**, which is exactly the thing that stops being
unique.

**The `sign` target** — `swift/Makefile:37-51`:

```makefile
sign: build ## Build and sign with persistent identity
	@if codesign --force --sign "$(IDENTITY)" $(BINARY) 2>/dev/null; then \
		echo "✓ Signed with '$(IDENTITY)' — FDA persists across rebuilds"; \
	elif security find-certificate -c "$(CERT_CN)" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then \
		if codesign --force --sign "$(IDENTITY)" $(BINARY); then \
			echo "✓ Signed with '$(IDENTITY)'"; \
		else \
			echo "✗ Failed to sign with '$(IDENTITY)'"; \
			exit 1; \
		fi; \
	else \
		echo "⚠ No signing identity '$(IDENTITY)' — using ad-hoc (FDA needs re-granting each build)"; \
		echo "  Run 'make setup-signing' once to fix this permanently"; \
		codesign --force --sign - $(BINARY); \
	fi
```

Note the `2>/dev/null` on the first branch: the `ambiguous` error that explains
the whole failure is discarded, so the operator never sees it.

**The `setup-signing` guard** — `swift/Makefile:144-147`:

```makefile
	@if codesign --force --sign "$(IDENTITY)" --generate-entitlement-der /dev/null 2>/dev/null; then \
		echo "✓ Signing identity '$(IDENTITY)' already works"; \
		exit 0; \
	fi; \
```

This is the idempotency guard, and it is the bug. It asks "can I sign by
name?" — which is false whenever duplicates exist — and then falls through to
import yet another certificate. The guard is defeated by the very condition it
should detect.

**The misleading tail** — `swift/Makefile:176-184`:

```makefile
	if codesign --force --sign "$(IDENTITY)" $(BINARY) 2>/dev/null; then \
		echo "✓ Signing identity '$(IDENTITY)' created and working"; \
		echo "  Grant FDA one more time in System Settings — it will persist across rebuilds."; \
	else \
		echo "⚠ Certificate imported but needs manual trust:"; \
		echo "  1. Open Keychain Access"; \
		echo "  2. Find '$(CERT_CN)' in login keychain"; \
		echo "  3. Double-click → Trust → Code Signing → Always Trust"; \
	fi
```

**The exact observed failure**, for reference:

```
iMessage Max Dev: ambiguous (matches "iMessage Max Dev" and "iMessage Max Dev" in /Users/…/login.keychain-db)
```

**The proven workaround** (this is what unblocked the 2026-08-07 deploy, and it
is the seed of the fix): `codesign --force --sign <SHA-1-hash>` succeeds
immediately. `security find-identity -v -p codesigning` prints exactly the
identities that have a usable private key, each with its hash:

```
  2) F9E455A3BB848F2623DA215A224E7F826B09C4BC "iMessage Max Dev"
```

A hash is unique by construction. Selecting on it makes duplicates harmless
instead of fatal.

## Keychain safety

**Read this before running anything.**

- **Do NOT run `security delete-certificate` or `security delete-identity`
  against the operator's `login.keychain-db`.** Cleaning up duplicates is out
  of scope for this plan. The fix must make duplicates *harmless*, not absent —
  a fix that requires cleanup first is not a fix, because the next machine will
  hit the same state.
- **Do NOT run `make setup-signing` against the real login keychain as a test.**
  That is what created the duplicates. Every test in this plan uses a scratch
  keychain (Step 4) or is a pure shell/`make -n` inspection.
- **Do NOT re-sign `$(BINARY)` as a casual verification.** The operator's Full
  Disk Access is bound to the current signature. Changing it costs them a
  manual GUI re-grant. Sign a throwaway copy in a temp directory instead.
- A `security` command may raise a GUI password dialog that blocks
  indefinitely with no output. If a command produces no output for more than
  ~60 seconds, assume it is blocked on a dialog, STOP, and report — do not
  retry it in a loop.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| List usable identities | `security find-identity -v -p codesigning` | zero or more lines, each `N) <SHA1> "<name>"` |
| Makefile syntax check | `cd swift && make -n sign` | prints the recipe, exit 0 |
| Same for setup | `cd swift && make -n setup-signing` | prints the recipe, exit 0 |
| Build | `cd swift && swift build` | exit 0 |
| Full suite | `cd swift && swift test` | exit 0, 0 failures, **233 tests** |

Baseline is **233 tests, 0 failures** at `58850fb`. This plan changes no Swift
code, so that number must be unchanged at the end.

## Scope

**In scope** (the only files you should modify):
- `swift/Makefile`
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch):
- Any file under `swift/Sources/` or `swift/Tests/` — this plan adds no Swift
  code and changes no behavior of the server.
- `AGENTS.md`, `README.md`, `swift/README.md` — the operator-facing signing
  instructions do not change. The workflow is still
  `make setup-signing` once, then `make install`.
- The operator's keychain contents (see "Keychain safety").
- `.github/workflows/build.yml` — CI does not sign.

## Git workflow

- Branch: `advisor/037-signing-identity-resolution`
- Conventional commit, e.g.
  `fix(make): resolve signing identity by hash so duplicate certs cannot break signing`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add an identity-resolution helper variable

The goal: one place that turns "the common name" into "the hash of a
certificate that actually has a private key", and yields empty when there is
none.

Add near the other variables (`swift/Makefile:17-21`), after `CERT_CN`:

```makefile
# Resolve CERT_CN to a certificate SHA-1. `codesign --sign <name>` fails with
# "ambiguous" when the login keychain holds more than one cert with that common
# name, which is a state setup-signing itself used to create. A hash is unique
# by construction, and find-identity lists only certs that have a usable
# private key — so this both disambiguates and filters out orphaned certs.
# Evaluated lazily (`=`, not `:=`) because setup-signing creates the identity
# during the same make invocation that later needs to read it.
SIGN_HASH = $(shell security find-identity -v -p codesigning 2>/dev/null | \
	grep -F '"$(CERT_CN)"' | head -1 | awk '{print $$2}')
```

**`=` and not `:=` is load-bearing.** `:=` expands once when the Makefile is
parsed; `setup-signing` imports the certificate *during* the recipe, so a
`:=` value would still be the empty string afterward and the success branch in
Step 3 would never fire.

**Verify**: `cd swift && make -n sign` still prints a recipe and exits 0. Then
confirm the variable resolves on a machine that has an identity:
`cd swift && make -s print-sign-hash` after temporarily adding
`print-sign-hash: ; @echo "$(SIGN_HASH)"` — remove that helper target before
committing. Expect a 40-character hex string, or empty if no identity exists.
Both are valid outcomes; you are checking that it does not error.

### Step 2: Rewrite the `sign` target to use the hash

Replace `swift/Makefile:37-51` in full:

```makefile
sign: build ## Build and sign with persistent identity
	@HASH="$(SIGN_HASH)"; \
	if [ -n "$$HASH" ]; then \
		if codesign --force --sign "$$HASH" $(BINARY); then \
			echo "✓ Signed with '$(CERT_CN)' ($$HASH) — FDA persists across rebuilds"; \
		else \
			echo "✗ Found identity '$(CERT_CN)' ($$HASH) but signing failed — see the error above"; \
			exit 1; \
		fi; \
	else \
		echo "⚠ No signing identity '$(CERT_CN)' — using ad-hoc (FDA needs re-granting each build)"; \
		echo "  Run 'make setup-signing' once to fix this permanently"; \
		codesign --force --sign - $(BINARY); \
	fi
```

Three deliberate changes beyond the hash:

- The `elif security find-certificate …` branch is **deleted**. It tested for a
  certificate that may have no private key, then retried the same failing
  command. `find-identity` already filters to usable identities, so the branch
  has no remaining job.
- The `2>/dev/null` on the signing call is **removed**. Swallowing that stream
  is what hid `ambiguous` from the operator for as long as this bug existed. If
  signing fails now, they see why.
- The success line prints the hash, so a confused operator can compare it
  against `security find-identity` output without knowing the internals.

**Verify**: `cd swift && make -n sign` prints the new recipe and exits 0. Do
**not** run `make sign` for real yet — see "Keychain safety".

### Step 3: Fix the `setup-signing` guard and its tail

Replace the guard at `swift/Makefile:144-147`:

```makefile
	@if [ -n "$(SIGN_HASH)" ]; then \
		echo "✓ Signing identity '$(CERT_CN)' already exists ($(SIGN_HASH))"; \
		exit 0; \
	fi; \
```

This is the actual bug fix. The question becomes "does a usable identity
exist?" instead of "can I sign by name?", so duplicates no longer defeat the
guard and no longer cause another import.

Then replace the tail at `swift/Makefile:176-184`:

```makefile
	if [ -n "$(SIGN_HASH)" ]; then \
		echo "✓ Signing identity '$(CERT_CN)' created and working"; \
		echo "  Grant FDA one more time in System Settings — it will persist across rebuilds."; \
	else \
		echo "⚠ Certificate imported but no usable signing identity was found."; \
		echo "  This usually means the private key did not import. Check with:"; \
		echo "    security find-identity -v -p codesigning"; \
		echo "  If '$(CERT_CN)' is absent there, the import failed — re-run this target."; \
		echo "  If it IS listed, signing should now work; report this as a bug."; \
	fi
```

The old text sent the operator to Keychain Access to fix a trust setting that
was never the problem. The new text names the one thing that is actually
checkable and gives them the command to check it.

**Verify**: `cd swift && make -n setup-signing` prints the recipe and exits 0.
Confirm the misleading string is gone:
`grep -n "Always Trust" swift/Makefile` → no matches.

### Step 4: Prove idempotency against a scratch keychain

This is the step that demonstrates the fix. **Use a scratch keychain — never
the login keychain.**

```sh
set -e
SCRATCH="$HOME/Library/Keychains/imx-plan037-test.keychain-db"
security create-keychain -p testpass "$SCRATCH"
security unlock-keychain -p testpass "$SCRATCH"
```

Import the *same* self-signed certificate twice into the scratch keychain,
reusing the openssl/pkcs12 block from `setup-signing` but with
`-k "$SCRATCH"`. Then confirm the pathology and the fix:

```sh
# Both certs are present under one name:
security find-certificate -a -c "iMessage Max Dev" "$SCRATCH" | grep -c "labl"   # expect 2

# Name-based signing is ambiguous (the old behavior):
cp .build/release/imessage-max /tmp/imx-signtest
codesign --force --sign "iMessage Max Dev" --keychain "$SCRATCH" /tmp/imx-signtest 2>&1 | grep -c ambiguous   # expect 1

# Hash-based signing succeeds (the new behavior):
HASH=$(security find-identity -v -p codesigning "$SCRATCH" | grep -F '"iMessage Max Dev"' | head -1 | awk '{print $2}')
codesign --force --sign "$HASH" --keychain "$SCRATCH" /tmp/imx-signtest && echo "HASH SIGNING OK"
```

Tear down unconditionally, including on failure:

```sh
security delete-keychain "$SCRATCH"
rm -f /tmp/imx-signtest
```

**Verify**: the ambiguous grep returns 1 and `HASH SIGNING OK` prints. Confirm
teardown left nothing behind:
`security list-keychains | grep -c imx-plan037-test` → 0.

Record both observed outputs verbatim in your report. This is the evidence that
the fix addresses the real failure and not a guess about it.

### Step 5: Full suite

This plan changes no Swift code, so the suite is a regression gate only.

**Verify**: `cd swift && swift test` → exit 0, 0 failures, **233 tests**. If the
count differs from 233, STOP — something outside this plan's scope changed.

## Test plan

No new Swift tests — there is no Swift code here. Step 4 is the behavioral
test, and it is the meaningful one: it reproduces the exact failure against a
disposable keychain and shows the new selection method surviving it.

If a future round adds shell-level test infrastructure to this repo, Step 4 is
the natural first case to move into it.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` exits 0; 0 failures; **233 tests**
- [ ] `grep -n "SIGN_HASH" swift/Makefile` → at least 3 matches (definition,
      `sign`, `setup-signing`)
- [ ] `grep -c 'sign "$(IDENTITY)"' swift/Makefile` → 0 (no name-based signing
      call remains)
- [ ] `grep -n "Always Trust" swift/Makefile` → no matches
- [ ] `grep -n 'SIGN_HASH :=' swift/Makefile` → no matches (must be lazy `=`)
- [ ] `cd swift && make -n sign` exits 0
- [ ] `cd swift && make -n setup-signing` exits 0
- [ ] `security list-keychains | grep -c imx-plan037-test` → 0 (scratch keychain
      torn down)
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- **Any `security` command produces no output for ~60 seconds.** It is blocked
  on a GUI password dialog. Do not retry in a loop — report it, because on a
  headless or automated run this will hang forever and that fact belongs in the
  report.
- `security find-identity -v -p codesigning` returns nothing at all on this
  machine. Step 4 still works (it creates its own identity in the scratch
  keychain), but Step 1's verification cannot be completed — say so rather than
  inventing a result.
- You find yourself wanting to delete a certificate from the login keychain to
  make something pass. That is the out-of-scope action this plan exists to
  avoid needing. Report what you saw instead.
- The `awk '{print $$2}'` field index does not match this machine's
  `find-identity` output format. Do not hardcode a different index blindly —
  paste the raw output in your report and propose a parse that fits it.
- The suite is not 233 tests before you start. The Makefile is not the cause;
  something else drifted. Report and stop.

## Maintenance notes

- **The root cause is a class, not an instance**: selecting a keychain item by
  a human-readable name that the tool itself can create more of. If any future
  target needs a certificate, select it by hash through `SIGN_HASH` — do not
  add another `--sign "$(CERT_CN)"`.
- `IDENTITY` and `CERT_CN` are currently the same string, and after this plan
  `IDENTITY` has no remaining callers. It is left in place deliberately rather
  than deleted, because operators may reference it in local scripts. A future
  cleanup could remove it — check `grep -rn IDENTITY swift/Makefile` first.
- The operator's login keychain still holds duplicate `iMessage Max Dev`
  certificates from before this fix. **They are now harmless** —
  `find-identity` returns only the one with a private key. Cleaning them up is
  optional cosmetic work, deliberately not part of this plan, and requires
  interactive confirmation because deleting the wrong one costs an FDA
  re-grant.
- Watch in review: anyone reintroducing `2>/dev/null` on a `codesign` call.
  That redirect is why this bug was undiagnosable for as long as it existed —
  the error message named the cause precisely and was being thrown away.
