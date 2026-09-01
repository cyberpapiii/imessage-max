# Plan 052: One source of truth for the version, and a release checklist the Formula test can pass

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 61e75d9..HEAD -- swift/Sources/iMessageMax/Server/Version.swift swift/Sources/Resources/Info.plist mcpb/manifest.json .codex-plugin/plugin.json swift/Formula/imessage-max.rb swift/Makefile swift/Sources/iMessageMax/main.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: 040 (release workflow must work before a release checklist is worth having)
- **Category**: DX / release
- **Planned at**: commit `61e75d9`, 2026-09-01

## Why this matters

The version string `1.4.2` is written by hand in four files. The last release tagged is v1.4.1; `1.4.2` was bumped in source, never tagged, and the Homebrew Formula correctly still points at v1.4.1. Nothing checks the four copies agree, and the Formula's `test do` asserts that `--version` prints "iMessage Max" while the binary prints the bare number, so `brew test imessage-max` fails on a correctly built package. A release today is a sequence of manual edits with no checklist that a tool verifies.

After this plan: one script checks the four copies agree and fails CI if not; `--version` prints a string the Formula test matches; the Makefile gains a `release-check` target that runs the checks a human does before tagging.

## Current state

Version sites at `61e75d9`:

- `swift/Sources/iMessageMax/Server/Version.swift:5` — `static let current = "1.4.2"`, and `:6` `static let name = "iMessage Max"`.
- `swift/Sources/Resources/Info.plist:14,16` — `CFBundleShortVersionString` and `CFBundleVersion` both `1.4.2`.
- `mcpb/manifest.json:5` — `"version": "1.4.2"`.
- `.codex-plugin/plugin.json:3` — `"version": "1.4.2"`.

`swift/Sources/iMessageMax/main.swift:7-11`:

```swift
static let configuration = CommandConfiguration(
    commandName: "imessage-max",
    abstract: "MCP server for iMessage",
    version: Version.current
)
```

so `imessage-max --version` prints `1.4.2`.

`swift/Formula/imessage-max.rb` (note the path: the Formula lives under `swift/`, not the repo root):

```ruby
  url "https://github.com/cyberpapiii/imessage-max/releases/download/v1.4.1/imessage-max-macos.tar.gz"
  ...
  depends_on :macos
  depends_on macos: :sonoma

  def install
    bin.install "imessage-max"
  end

  test do
    assert_match "iMessage Max", shell_output("#{bin}/imessage-max --version")
  end
```

Git tags: `v1.4.1`, `v1.4.0`, `v1.2.1`. No `v1.4.2`.

`swift/Makefile` targets (`grep -n "^[a-z-]*:" swift/Makefile`): `help`, `build`, `test`, `sign`, `restart`, `verify`, `install`, `status`, `logs`, `clean`, `setup-signing`, plus `add-trusted-cert` (line 199, by design). No release target. `docs/validation/2026-04-09-release-checklist.md` is a dated manual checklist.

`.github/workflows/release.yml` after plan 040 builds on tag push and `workflow_dispatch`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | `Build complete!` |
| Version | `cd swift && swift run imessage-max --version` | `iMessage Max 1.4.2` |
| Consistency | `scripts/check-version.sh` | `OK 1.4.2` exit 0 |
| Formula syntax | `ruby -c swift/Formula/imessage-max.rb` | `Syntax OK` |
| Whole suite | `cd swift && swift test` | 0 failures |

## Scope

**In scope** (the only files you should modify):
- `scripts/check-version.sh` (create; `scripts/` may not exist, create it)
- `swift/Sources/iMessageMax/main.swift` (the `version:` argument only)
- `swift/Sources/iMessageMax/Server/Version.swift` (add a `display` string)
- `swift/Makefile` (add `release-check` and `version` targets)
- `.github/workflows/ci.yml` (add one step running the script; coordinate with plan 040's edits by adding the step after its build step)
- `swift/Tests/iMessageMaxTests/VersionConsistencyTests.swift` (create)
- `docs/RELEASING.md` (create; short)

**Out of scope** (do NOT touch, even though they look related):
- Bumping the version or tagging a release. This plan makes releasing checkable; the operator releases.
- The Formula `url`/`sha256` (they are correct for v1.4.1) and `depends_on` lines (plans 040 and 048).
- Automating the Formula update in CI (needs a tap repo decision; record as deferred).

## Git workflow

- Branch: `advisor/052-version-dx`
- Commits: `build: add a version consistency check across the four version sites`; `fix: print the product name in --version so the Formula test matches`; `docs: add RELEASING.md and a make release-check target`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Consistency script

Create `scripts/check-version.sh`:

```bash
#!/usr/bin/env bash
# Verify every hand-written copy of the version agrees with Version.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

swift_v=$(sed -nE 's/^ *static let current = "([^"]+)"/\1/p' swift/Sources/iMessageMax/Server/Version.swift)
plist_short=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' swift/Sources/Resources/Info.plist)
plist_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' swift/Sources/Resources/Info.plist)
mcpb_v=$(python3 -c 'import json,sys;print(json.load(open("mcpb/manifest.json"))["version"])')
codex_v=$(python3 -c 'import json,sys;print(json.load(open(".codex-plugin/plugin.json"))["version"])')

status=0
for pair in "Info.plist short:$plist_short" "Info.plist build:$plist_build" "mcpb/manifest.json:$mcpb_v" ".codex-plugin/plugin.json:$codex_v"; do
  name=${pair%%:*}; v=${pair##*:}
  if [[ "$v" != "$swift_v" ]]; then
    echo "MISMATCH $name = $v (Version.swift = $swift_v)" >&2
    status=1
  fi
done

if [[ -n "${1:-}" && "$1" == "--tag" ]]; then
  tag=$(git describe --tags --exact-match 2>/dev/null || true)
  if [[ "$tag" != "v$swift_v" ]]; then
    echo "TAG MISMATCH HEAD tag '$tag' != v$swift_v" >&2
    status=1
  fi
fi

[[ $status -eq 0 ]] && echo "OK $swift_v"
exit $status
```

`chmod +x scripts/check-version.sh`.

**Verify**: `scripts/check-version.sh` → `OK 1.4.2`, exit 0. Temporarily edit `mcpb/manifest.json` to `1.4.3`, rerun → `MISMATCH`, exit 1; revert.

### Step 2: `--version` output

In `Version.swift` add `static let display = "\(name) \(current)"`. In `main.swift` change `version: Version.current` to `version: Version.display`. `ArgumentParser` prints the string verbatim.

**Verify**: `cd swift && swift run imessage-max --version` → `iMessage Max 1.4.2`. Check nothing parses the bare number: `grep -rn "\-\-version" swift/Makefile docs scripts .github` → for each hit that captures output (the Makefile `status` target at line 116 may), confirm it displays rather than compares; if it compares, adjust it to `grep -o '[0-9.]*$'`.

### Step 3: Test that pins the four sites

Create `VersionConsistencyTests.swift` with one test that locates the repo root (copy `findRepoRoot(from:)` from `IconMetadataTests.swift:176`) and asserts the four files carry `Version.current`. Reuse `jsonObject(at:)` from `IconMetadataTests.swift:171` for the two JSON files; parse the plist with `PropertyListSerialization`. This duplicates the script on purpose: the script is for CI/Make, the test is for `swift test` in the loop.

**Verify**: `cd swift && swift test --filter VersionConsistencyTests` → 1 test, 0 failures.

### Step 4: Makefile and CI

Add to `swift/Makefile`:

```make
version: ## Print the version and check all copies agree
	@../scripts/check-version.sh

release-check: build test version ## Everything that must pass before tagging
	@../scripts/check-version.sh --tag || echo "Not on a matching tag yet (expected before tagging)."
	@ruby -c Formula/imessage-max.rb
	@echo "Release checks passed. Next: git tag v$$(sed -nE 's/^ *static let current = \"([^\"]+)\"/\1/p' Sources/iMessageMax/Server/Version.swift) && git push --tags"
```

Match the file's existing tab/`##` help convention (line 41 shows the `help` target that greps `##`).

In `.github/workflows/ci.yml`, add a step `- name: Check version consistency` running `scripts/check-version.sh` after checkout.

**Verify**: `cd swift && make version` → `OK 1.4.2`; `make -n release-check` prints the commands without error; `python3 -c 'import yaml,sys;yaml.safe_load(open(".github/workflows/ci.yml"))'` exits 0 (or use `ruby -ryaml -e 'YAML.load_file(".github/workflows/ci.yml")'`).

### Step 5: `docs/RELEASING.md`

Write a short document (under 60 lines): bump the four files (or run a one-line `sed` you include), `make release-check`, tag `vX.Y.Z`, push tag, wait for `release.yml`, download the asset, `shasum -a 256`, update `swift/Formula/imessage-max.rb` `url` and `sha256`, `brew install --build-from-source swift/Formula/imessage-max.rb && brew test imessage-max`. Link it from `AGENTS.md`'s build/install section with one line.

**Verify**: `grep -n "RELEASING.md" AGENTS.md` → one match.

## Test plan

- `VersionConsistencyTests` (1).
- Script self-test in Step 1 (manual mismatch injection).

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `scripts/check-version.sh` → exit 0
- [ ] `cd swift && swift run imessage-max --version | grep -q "^iMessage Max 1\.4\.2$"`
- [ ] `cd swift && swift test` → 0 failures
- [ ] `grep -n "release-check" swift/Makefile` → ≥ 1 match
- [ ] `grep -n "check-version.sh" .github/workflows/ci.yml` → 1 match
- [ ] `test -f docs/RELEASING.md`
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Some consumer parses `--version` as a bare number and cannot be adjusted within the in-scope files (for example the `mcpb` packaging in `mcpb/` reads it). Report the consumer.
- Plan 040 has not landed and `ci.yml` is mid-edit on another branch. Land 040 first.

## Maintenance notes

- Deferred: a `bump-version` target that edits all four files. Easy to add once the check exists; the operator asked for checks, not automation, this round.
- Deferred: auto-updating the Formula from `release.yml`. Needs a tap repository or a commit-back token; a product decision.
- If a fifth version site appears (a Swift package manifest for a plugin, a Sparkle feed), add it to both the script and the test.
