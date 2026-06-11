# Plan 007: Cache Swift build artifacts in CI

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 57a2ff3..HEAD -- .github/workflows/build.yml`
> If the file changed since this plan was written, compare against the
> "Current state" excerpt before proceeding; on a mismatch, treat it as a
> STOP condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW (worst case: cache miss → behavior identical to today)
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `57a2ff3`, 2026-06-11

## Why this matters

Every push and PR triggers a from-scratch `swift build` + `swift test` on a macOS-15 runner, recompiling all dependencies (MCP swift-sdk, Hummingbird, ArgumentParser) each time — several minutes of latency per run and unnecessary runner cost. Caching `.build` keyed on `Package.resolved` makes dependency compilation incremental across runs.

## Current state

`.github/workflows/build.yml` in full (the only CI build workflow; `release.yml` is out of scope):

```yaml
name: Build Swift

on:
  push:
    branches: [main]
    paths:
      - 'swift/**'
      - '.github/workflows/build.yml'
  pull_request:
    branches: [main]
    paths:
      - 'swift/**'
      - '.github/workflows/build.yml'

jobs:
  build:
    runs-on: macos-15
    defaults:
      run:
        working-directory: swift

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Build
        run: swift build

      - name: Run tests
        run: swift test
```

Note: the lockfile is at `swift/Package.resolved` (repo has the Swift package in the `swift/` subdirectory; `hashFiles` paths are relative to the repo root, while run steps use `working-directory: swift`).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| YAML sanity | `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/build.yml')); print('ok')"` | prints `ok` (if PyYAML is missing, use the actionlint check instead) |
| Action lint (optional) | `brew list actionlint >/dev/null 2>&1 && actionlint .github/workflows/build.yml` | no output / exit 0 (skip if actionlint not installed — do NOT install anything) |
| Local tests still fine | `cd swift && swift test` | all pass (CI change shouldn't affect local, this is a sanity baseline) |

## Scope

**In scope**:
- `.github/workflows/build.yml`
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- `.github/workflows/release.yml` — release builds should stay clean/reproducible; do not add caching there.
- The Makefile, Package.swift, any Swift source.
- Do not pin a Swift toolchain version or add new jobs — caching only.

## Git workflow

- Branch: `advisor/007-ci-build-cache`
- Commit style: lowercase conventional prefix, e.g. `ci: cache swift build artifacts keyed on Package.resolved`.
- Do NOT push or open a PR unless the operator instructed it (note: the caching effect can only be observed after a push; see Done criteria).

## Steps

### Step 1: Add the cache step

Insert between "Checkout code" and "Build":

```yaml
      - name: Cache Swift build
        uses: actions/cache@v4
        with:
          path: swift/.build
          key: ${{ runner.os }}-swift-build-${{ hashFiles('swift/Package.resolved') }}
          restore-keys: |
            ${{ runner.os }}-swift-build-
```

(`path` is repo-root-relative for actions/cache, hence `swift/.build` despite the job's `working-directory`.)

**Verify**: the YAML sanity command from the table → `ok`.

### Step 2: Confirm key file exists

```bash
ls swift/Package.resolved
```

**Verify**: file exists (it is checked in). If it does not exist, STOP — the cache key strategy needs rethinking, and `swift build` resolving freshly each run may be intentional.

## Test plan

No test-suite changes. Real verification happens on the next push to a branch with this change: the first run populates the cache (look for the `Cache Swift build` step saving), the second run should show "Cache restored from key" and a visibly shorter Build step. Record both run durations in the status row note when available. If the operator does not want a push yet, mark the plan DONE-pending-CI-observation in `plans/README.md`.

## Done criteria

- [ ] `build.yml` contains an `actions/cache@v4` step with `path: swift/.build` keyed on `hashFiles('swift/Package.resolved')`
- [ ] YAML parses (`python3 -c "import yaml,..."` → ok, or actionlint clean)
- [ ] No other workflow files modified (`git status`)
- [ ] `plans/README.md` status row updated (with the CI-observation caveat if not yet pushed)

## STOP conditions

Stop and report back (do not improvise) if:

- `swift/Package.resolved` is not checked into the repo.
- `build.yml` has materially changed since the excerpt above (e.g. someone already added caching or a matrix).

## Maintenance notes

- If CI later pins Swift toolchain versions, add the Swift version to the cache key (a stale `.build` across toolchains can cause confusing failures — `restore-keys` makes this possible; if mysterious CI-only build errors appear after a toolchain bump, clearing the cache is the first move).
- Reviewer should scrutinize: the repo-root-relative `path`/`hashFiles` vs the job's `working-directory: swift` (an easy mismatch).
