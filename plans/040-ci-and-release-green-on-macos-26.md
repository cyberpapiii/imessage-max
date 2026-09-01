# Plan 040: Make CI and the release workflow green again on macOS 26 runners

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 61e75d9..HEAD -- .github/workflows/build.yml .github/workflows/release.yml swift/Formula/imessage-max.rb`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P0
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none. Every other plan in this round depends on this one, because until it lands no CI run can confirm anything.
- **Category**: dx
- **Planned at**: commit `61e75d9`, 2026-09-01

## Why this matters

Every run of the "Build Swift" workflow has failed since 2026-08-07, and the "Release Swift" workflow has not produced an asset since v1.0.2 (2026-01-29). The v1.4.0 and v1.4.1 release assets were hand-built on the operator's machine: arm64-only, ad-hoc signed, with a per-build identifier instead of the `com.cyberpapiii.imessage-max` identifier the workflow promises. Nothing merged in the last month has been verified by CI, and the release job runs no tests at all before publishing a public binary.

The cause is not the code. The `macos-15` runner ships Xcode 16.4 (macOS 15 SDK), where `CIContext` is not `Sendable` and the compiler rejects two declarations that the macOS 26 SDK (Xcode 26.x, which the operator builds with locally) accepts. Moving the runner to `macos-26` fixes both errors with no source change. While in these two files, the plan also bumps the three GitHub Actions whose Node runtimes are being removed from runners on 2026-09-23, widens the build trigger to cover the manifests that tests assert on, adds a test step to the release job, and fixes the universal-binary build that hits a SwiftPM bug.

## Current state

Files:

- `.github/workflows/build.yml` — PR/push CI. Runner `macos-15`, `actions/checkout@v4`, `actions/cache@v4`. Path filter only watches `swift/**`.
- `.github/workflows/release.yml` — tag-triggered release. Runner `macos-15`, `actions/checkout@v4`, `softprops/action-gh-release@v1`. No test step. Builds `--arch arm64 --arch x86_64`.
- `swift/Formula/imessage-max.rb` — Homebrew formula. No architecture constraint.
- `swift/Sources/iMessageMax/Enrichment/ImageProcessor.swift:38` and `swift/Sources/iMessageMax/Server/HTTPTransport.swift:420` — the two lines the old SDK rejects. **Do not edit them.** They are correct under the macOS 26 SDK.

The failing CI output (run for commit `61e75d9`, 2026-08-31), quoted exactly:

```
swift/Sources/iMessageMax/Enrichment/ImageProcessor.swift:38:24: error: static property 'sharedContext' is not concurrency-safe because non-'Sendable' type 'CIContext' may have shared mutable state
swift/Sources/iMessageMax/Server/HTTPTransport.swift:420:46: error: non-sendable result type 'ToolCallDispatch.Result' cannot be sent from nonisolated context
```

`build.yml` as it exists today (whole file):

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

      - name: Cache Swift build
        uses: actions/cache@v4
        with:
          path: swift/.build
          key: ${{ runner.os }}-swift-build-${{ hashFiles('swift/Package.resolved') }}
          restore-keys: |
            ${{ runner.os }}-swift-build-

      # Tests are compiled in this step on purpose, so a compile error is
      # attributed to "Build" rather than "Run tests".
      - name: Build (including tests)
        run: swift build --build-tests

      - name: Run tests
        run: swift test --skip-build --parallel
```

`release.yml` as it exists today (whole file):

```yaml
name: Release Swift

on:
  push:
    tags:
      - 'v*'

jobs:
  build-and-release:
    runs-on: macos-15
    permissions:
      contents: write
    defaults:
      run:
        working-directory: swift

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Build universal binary with embedded Info.plist
        run: |
          swift build -c release --arch arm64 --arch x86_64 \
            -Xlinker -sectcreate \
            -Xlinker __TEXT \
            -Xlinker __info_plist \
            -Xlinker "$PWD/Sources/Resources/Info.plist"

      - name: Re-sign binary with bundle identifier
        run: |
          BINARY=".build/apple/Products/Release/imessage-max"
          BUNDLE_ID="com.cyberpapiii.imessage-max"
          codesign --force --sign - --identifier "$BUNDLE_ID" "$BINARY"
          echo "Verifying code signature..."
          codesign -dvvv "$BINARY" 2>&1 | grep -E "(Identifier|Info.plist)"

      - name: Create tarball
        run: |
          cd .build/apple/Products/Release
          tar -czvf imessage-max-macos.tar.gz imessage-max
          mv imessage-max-macos.tar.gz $GITHUB_WORKSPACE/

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v1
        with:
          files: imessage-max-macos.tar.gz
          generate_release_notes: true
```

`swift/Formula/imessage-max.rb:13-14`:

```ruby
  depends_on :macos
  depends_on macos: :sonoma
```

Facts established during planning:

- The two-arch build (`--arch arm64 --arch x86_64`) fails on the runner with a SwiftPM PIF error mentioning `_RopeModule` (swift-collections). This is SwiftPM issue #7958. Every published asset to date has been arm64-only, and the only machines that run this server (Messages.app plus Full Disk Access) are the operator's Apple Silicon Macs. The plan drops x86_64 and declares arm64 in the Formula, which is honest about what has shipped for eight months.
- The macOS 26 runner image ships Xcode 26.x. Locally the project builds with Xcode 26.6 / Swift 6.3.3, and the test suite is 278/278 at `61e75d9`.
- Tests read files outside `swift/`: `swift/Tests/iMessageMaxTests/IconMetadataTests.swift:85-115` reads `.codex-plugin/plugin.json`, `.mcp.json`, `mcpb/manifest.json`, and PNGs under `mcpb/assets/` and `assets/codex/`. A change to any of those runs zero CI today.
- Node 20 is removed from GitHub-hosted runners on 2026-09-23. `actions/checkout@v4` and `actions/cache@v4` run on Node 20; `softprops/action-gh-release@v1` runs on Node 16. Current majors: `actions/checkout@v7`, `actions/cache@v6`, `softprops/action-gh-release@v3`.

Repo conventions that apply: workflows use `defaults.run.working-directory: swift`; the release build embeds `Sources/Resources/Info.plist` via `-sectcreate` (the Makefile `build` target at `swift/Makefile:44-51` does the same). Keep both.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | last line `Build complete!` |
| Build tests | `cd swift && swift build --build-tests` | `Build complete!` |
| Tests | `cd swift && swift test --skip-build --parallel` | `Executed 278 tests, with 0 failures` (count may be higher if other plans landed first; failures must be 0) |
| Release build (local dry run) | `cd swift && swift build -c release -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PWD/Sources/Resources/Info.plist"` | `Build complete!`, binary at `swift/.build/release/imessage-max` |
| YAML syntax | `ruby -ryaml -e 'YAML.load_file(ARGV[0]); puts "ok"' .github/workflows/build.yml` | `ok` |
| Arch check | `lipo -info swift/.build/release/imessage-max` | `Non-fat file: ... is architecture: arm64` |
| Workflow runs | `gh run list -w build.yml -L 3` | after push: `completed  success` on the branch's run |

## Scope

**In scope** (the only files you should modify):
- `.github/workflows/build.yml`
- `.github/workflows/release.yml`
- `swift/Formula/imessage-max.rb` (only the two `depends_on` lines)

**Out of scope** (do NOT touch, even though they look related):
- `swift/Sources/iMessageMax/Enrichment/ImageProcessor.swift` and `swift/Sources/iMessageMax/Server/HTTPTransport.swift` — the errors are SDK-version artifacts, not bugs. Adding `@unchecked Sendable` or `nonisolated(unsafe)` to make Xcode 16 happy would weaken real concurrency checking for no benefit.
- `swift/Package.swift` — tools-version, platform floor, and dependency bumps are plan 048.
- `swift/Sources/Resources/Info.plist` — the `LSMinimumSystemVersion` change is plan 048.
- The Formula `url`, `sha256`, and `test do` block — plan 052 owns Formula/version agreement.
- `swift/Makefile` — plan 053.

## Git workflow

- Branch: `advisor/040-ci-macos-26`
- Conventional commits, one per step where it makes sense. Examples from `git log`: `fix: raise the session cap that a fleet of agents hit in seconds`, `perf: bind the tool catalog once instead of per session`. Use `ci:` as the type for workflow changes, e.g. `ci: run build and release on macos-26 with current action majors`.
- Do NOT push or open a PR unless the operator instructed it. The final verification step needs a push; ask the operator, or note it as pending in your report.

## Steps

### Step 1: Rewrite `build.yml`

Replace the file with the following. Changes from the current file: runner `macos-26`; a `concurrency` group so a superseded push cancels its run; path filters extended to the manifest and asset directories the tests read; `checkout@v7` and `cache@v6`; a toolchain-logging step.

```yaml
name: Build Swift

on:
  push:
    branches: [main]
    paths:
      - 'swift/**'
      - 'mcpb/**'
      - '.codex-plugin/**'
      - '.mcp.json'
      - 'assets/**'
      - '.github/workflows/build.yml'
  pull_request:
    branches: [main]
    paths:
      - 'swift/**'
      - 'mcpb/**'
      - '.codex-plugin/**'
      - '.mcp.json'
      - 'assets/**'
      - '.github/workflows/build.yml'

concurrency:
  group: build-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build:
    runs-on: macos-26
    defaults:
      run:
        working-directory: swift

    steps:
      - name: Checkout code
        uses: actions/checkout@v7

      - name: Show toolchain
        run: |
          xcodebuild -version
          swift --version

      - name: Cache Swift build
        uses: actions/cache@v6
        with:
          path: swift/.build
          key: ${{ runner.os }}-swift-build-${{ hashFiles('swift/Package.resolved') }}
          restore-keys: |
            ${{ runner.os }}-swift-build-

      # Tests are compiled in this step on purpose, so a compile error is
      # attributed to "Build" rather than "Run tests".
      - name: Build (including tests)
        run: swift build --build-tests

      - name: Run tests
        run: swift test --skip-build --parallel
```

**Verify**: `ruby -ryaml -e 'YAML.load_file(ARGV[0]); puts "ok"' .github/workflows/build.yml` → `ok`. Then `grep -c "macos-26\|checkout@v7\|cache@v6" .github/workflows/build.yml` → `3`.

### Step 2: Rewrite `release.yml`

Replace the file with the following. Changes: runner `macos-26`; `workflow_dispatch` trigger so the operator can dry-run without a tag; a build-and-test gate before the release build; arm64-only release build (the two-arch build trips SwiftPM #7958 and no universal asset has ever shipped); assertions on architecture and signing identifier; `checkout@v7` and `action-gh-release@v3`; the publish step only runs for a tag ref.

```yaml
name: Release Swift

on:
  push:
    tags:
      - 'v*'
  workflow_dispatch:

jobs:
  build-and-release:
    runs-on: macos-26
    permissions:
      contents: write
    defaults:
      run:
        working-directory: swift

    steps:
      - name: Checkout code
        uses: actions/checkout@v7

      - name: Show toolchain
        run: |
          xcodebuild -version
          swift --version

      - name: Build and run tests
        run: |
          swift build --build-tests
          swift test --skip-build --parallel

      - name: Build release binary (arm64) with embedded Info.plist
        run: |
          swift build -c release --arch arm64 \
            -Xlinker -sectcreate \
            -Xlinker __TEXT \
            -Xlinker __info_plist \
            -Xlinker "$PWD/Sources/Resources/Info.plist"

      - name: Re-sign binary with bundle identifier
        run: |
          BINARY=".build/arm64-apple-macosx/release/imessage-max"
          BUNDLE_ID="com.cyberpapiii.imessage-max"
          codesign --force --sign - --identifier "$BUNDLE_ID" "$BINARY"
          echo "Verifying code signature..."
          codesign -dvvv "$BINARY" 2>&1 | grep -E "(Identifier|Info.plist)"

      - name: Assert architecture, identifier, and version
        run: |
          BINARY=".build/arm64-apple-macosx/release/imessage-max"
          lipo -info "$BINARY" | grep -q "arm64" || { echo "not arm64"; exit 1; }
          codesign -dvv "$BINARY" 2>&1 | grep -q "Identifier=com.cyberpapiii.imessage-max" || { echo "wrong identifier"; exit 1; }
          echo "Binary reports version: $("$BINARY" --version)"

      - name: Create tarball
        run: |
          cd .build/arm64-apple-macosx/release
          tar -czvf imessage-max-macos.tar.gz imessage-max
          shasum -a 256 imessage-max-macos.tar.gz
          mv imessage-max-macos.tar.gz $GITHUB_WORKSPACE/

      - name: Upload tarball as workflow artifact
        uses: actions/upload-artifact@v6
        with:
          name: imessage-max-macos
          path: imessage-max-macos.tar.gz

      - name: Create GitHub Release
        if: startsWith(github.ref, 'refs/tags/v')
        uses: softprops/action-gh-release@v3
        with:
          files: imessage-max-macos.tar.gz
          generate_release_notes: true
```

Note on the build output path: with a single `--arch arm64`, SwiftPM writes to `.build/arm64-apple-macosx/release/`, not `.build/apple/Products/Release/` (that path is only used for multi-arch builds). Confirm locally in the verify step.

**Verify**:
1. `ruby -ryaml -e 'YAML.load_file(ARGV[0]); puts "ok"' .github/workflows/release.yml` → `ok`.
2. `cd swift && swift build -c release --arch arm64 -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PWD/Sources/Resources/Info.plist"` → `Build complete!`, and `ls .build/arm64-apple-macosx/release/imessage-max` exists. If SwiftPM puts it somewhere else on your machine, run `find .build -name imessage-max -type f -path '*release*'` and use that path in the YAML for every occurrence.
3. `lipo -info swift/.build/arm64-apple-macosx/release/imessage-max` → contains `arm64`.
4. `codesign --force --sign - --identifier com.cyberpapiii.imessage-max swift/.build/arm64-apple-macosx/release/imessage-max && codesign -dvv swift/.build/arm64-apple-macosx/release/imessage-max 2>&1 | grep Identifier` → `Identifier=com.cyberpapiii.imessage-max`. (This signs a local build artifact only; it does not touch the installed service.)

### Step 3: Declare the architecture in the Formula

In `swift/Formula/imessage-max.rb`, replace lines 13-14:

```ruby
  depends_on :macos
  depends_on macos: :sonoma
```

with:

```ruby
  depends_on :macos
  depends_on macos: :sonoma
  depends_on arch: :arm64
```

(Plan 048 raises `:sonoma` to `:sequoia` when the platform floor moves. Leave it.)

**Verify**: `ruby -c swift/Formula/imessage-max.rb` → `Syntax OK`. `grep -n "arch: :arm64" swift/Formula/imessage-max.rb` → one line.

### Step 4: Local full verification

**Verify**: `cd swift && swift build --build-tests && swift test --skip-build --parallel 2>&1 | tail -3` → `Executed N tests, with 0 failures`.

### Step 5: Push and observe (operator-gated)

If the operator has authorized pushing: push the branch, open a PR against `main`, and wait for the "Build Swift" run.

**Verify**: `gh run list -w build.yml -L 1 --branch advisor/040-ci-macos-26` → status `completed`, conclusion `success`. Then `gh workflow run release.yml --ref advisor/040-ci-macos-26` and `gh run list -w release.yml -L 1` → `success`, with an `imessage-max-macos` artifact and no GitHub Release created (the publish step is skipped on non-tag refs).

If pushing is not authorized, report the plan as complete locally with this step pending, and say exactly which two commands the operator should run.

## Test plan

No Swift tests change in this plan. The verification is the workflow run itself (Step 5) plus the local release-build dry run (Step 2). The release job now runs the full unit suite before building the asset, which is the test gate this plan adds.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -c "macos-15" .github/workflows/*.yml` → `0`
- [ ] `grep -c "@v4\b\|@v1\b" .github/workflows/*.yml` → `0`
- [ ] `grep -n "x86_64" .github/workflows/release.yml` → no matches
- [ ] `grep -n "swift test" .github/workflows/release.yml` → one match
- [ ] `grep -n "mcpb/\*\*" .github/workflows/build.yml` → two matches (push and pull_request)
- [ ] Both YAML files load with `ruby -ryaml`
- [ ] `cd swift && swift test` → 0 failures
- [ ] If pushed: `gh run list -w build.yml -L 1` on the branch → `success`
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The `macos-26` runner does not exist or is not available to this repository (the run shows `queued` for more than 15 minutes or fails at scheduling). Report; do not fall back to `macos-15` with source changes.
- On the runner, `swift build` still fails on `ImageProcessor.swift:38` or `HTTPTransport.swift:420`. That means the runner's default Xcode is older than 26; report the `xcodebuild -version` output from the "Show toolchain" step. The operator may choose to add `sudo xcode-select -s /Applications/Xcode_26.x.app`; do not guess a path.
- The arm64-only release build fails locally with an error that is not a path mismatch.
- Any test fails locally that also fails at `61e75d9` on a clean checkout (pre-existing failure, not yours). Report it with the test name; the three `IconMetadataTests` methods are known to be sensitive to the checkout location of the repo root.
- You find you need to edit any file outside the in-scope list.

## Maintenance notes

- The release job now builds arm64 only. If an Intel user ever appears, the two-arch build must be retried against a newer SwiftPM (issue #7958) and the Formula `arch` line removed. Until then the Formula tells Intel users the truth at install time instead of at `test do`.
- Reviewer should scrutinize: the release binary path (`.build/arm64-apple-macosx/release/`) is correct for a single-arch build on the runner, and the `if: startsWith(github.ref, 'refs/tags/v')` guard is on the publish step only.
- Deferred: SHA-pinning the third-party `softprops/action-gh-release` action. Major-tag pinning is what the repo uses today; pinning to a commit SHA is stricter and can be done later without other changes.
- The `concurrency` group cancels in-progress runs for the same ref. On `main` that means a rapid double merge only verifies the second; that is the intended trade.
- Plan 052 adds a version-agreement test and the Formula `test do` fix. Plan 048 changes `swift-tools-version`, the platform floor, and the Formula's macOS requirement. Neither touches the workflow files.
