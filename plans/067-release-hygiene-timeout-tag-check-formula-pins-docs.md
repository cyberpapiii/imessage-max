# Plan 067: Release hygiene — workflow timeout, tag check, Formula version check, action SHA pins, and truthful release docs

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 639529e..HEAD -- .github/workflows/release.yml .github/workflows/build.yml .github/dependabot.yml scripts/check-version.sh swift/Tests/iMessageMaxTests/VersionConsistencyTests.swift swift/Formula/imessage-max.rb docs/RELEASING.md CHANGELOG.md AGENTS.md README.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S-M
- **Risk**: LOW
- **Depends on**: 066
- **Category**: dx / docs
- **Planned at**: commit `639529e`, 2026-09-01

## Why this matters

The release path works, but it is held together by things a human remembers rather than things a script checks. The release workflow has no timeout (a hung `swift test` on a tag push runs until GitHub's six-hour default), does not run the `--tag` version check that `make release-check` runs locally, and only *prints* the binary's version and the tarball's sha256 instead of asserting or publishing them. The Homebrew Formula is a fifth hand-written copy of the version that neither `scripts/check-version.sh` nor `VersionConsistencyTests` looks at, so `docs/RELEASING.md` saying "four places" is already wrong. Third-party actions are pinned to floating major tags, which is the one supply-chain hole a release job with `contents: write` should not have. And `RELEASING.md` step 4 tells the operator to run `brew install --build-from-source <path>`, which Homebrew 6 refuses because a formula of that name already exists in the `cyberpapiii/tap` tap; the last release was verified by hand-extracting the asset and the tap was updated manually, none of which is written down. Finally `CHANGELOG.md` still carries a provisional line about the v1.4.1 tarball, and `AGENTS.md` names the wrong Swift version and omits a whole source directory.

After this plan: the release job fails fast and fails loudly on a bad tag or version, the Formula is covered by the same checks as the other version sites, actions are SHA-pinned with Dependabot keeping them current, the tarball digest lands in the release body, and the release doc describes the procedure that actually works.

## Current state

### Release workflow

`.github/workflows/release.yml:9-30` — no `timeout-minutes`, no version check step:

```yaml
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
      ...
      - name: Build and run tests
        run: |
          swift build --build-tests
          swift test --skip-build --parallel
```

`.github/workflows/release.yml:48-53` — the version is echoed, never asserted:

```yaml
      - name: Assert architecture, identifier, and version
        run: |
          BINARY=".build/arm64-apple-macosx/release/imessage-max"
          lipo -info "$BINARY" | grep -q "arm64" || { echo "not arm64"; exit 1; }
          codesign -dvv "$BINARY" 2>&1 | grep -q "Identifier=com.cyberpapiii.imessage-max" || { echo "wrong identifier"; exit 1; }
          echo "Binary reports version: $("$BINARY" --version)"
```

`.github/workflows/release.yml:55-73` — sha256 is echoed to the log only; upload and release actions float on major tags:

```yaml
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

Note the release workflow runs `swift test --skip-build --parallel` (line 30). Plan 066 addresses whether that should be serial like `build.yml`; this plan does not touch line 30.

### Build workflow

`.github/workflows/build.yml:31-53` — already has a timeout and a version check (the pattern to copy), and floats on `actions/checkout@v7` and `actions/cache@v6`:

```yaml
  build:
    runs-on: macos-26
    timeout-minutes: 15
    ...
      - name: Checkout code
        uses: actions/checkout@v7
      ...
      # Version check runs before the build on purpose (fail fast).
      - name: Check version consistency
        working-directory: .
        run: scripts/check-version.sh

      - name: Cache Swift build
        uses: actions/cache@v6
```

### Version check script and test

`scripts/check-version.sh:6-19` reads four sites (Version.swift, Info.plist short and build, mcpb manifest, codex plugin) and compares. `:27-33` is the `--tag` mode:

```bash
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

The Formula is not read anywhere in the script.

`swift/Tests/iMessageMaxTests/VersionConsistencyTests.swift:4-24`:

```swift
/// Pins the four hand-written copies of the version to `Version.current`.
...
final class VersionConsistencyTests: XCTestCase {
    func testAllVersionSitesMatchVersionCurrent() throws {
        let root = try findRepoRoot(from: URL(fileURLWithPath: #filePath))
        let expected = Version.current

        let plist = try plistObject(at: root.appendingPathComponent("swift/Sources/Resources/Info.plist"))
        ...
        let plugin = try jsonObject(at: root.appendingPathComponent(".codex-plugin/plugin.json"))
        XCTAssertEqual(plugin["version"] as? String, expected, ".codex-plugin/plugin.json version")

        XCTAssertEqual(Version.display, "\(Version.name) \(expected)")
    }
}
```

`findRepoRoot` (`:38-48`) walks up from `#filePath` until it finds `icon.png`. Reuse it.

`swift/Sources/iMessageMax/Server/Version.swift` has `static let current = "1.5.0"` and `static let display = "\(name) \(current)"` where `name` is `"iMessage Max"`.

### Formula

`swift/Formula/imessage-max.rb` (25 lines, whole file):

```ruby
class ImessageMax < Formula
  desc "MCP server for iMessage - AI assistant integration"
  homepage "https://github.com/cyberpapiii/imessage-max"
  version "1.5.0"
  url "https://github.com/cyberpapiii/imessage-max/releases/download/v1.5.0/imessage-max-macos.tar.gz"
  # sha256 of the ad-hoc-signed imessage-max-macos.tar.gz built from v1.5.0.
  # ...
  sha256 "67506beed6266c83714fb844cff22a824af2d6d03960096570328ebf664fe72d"
  license "MIT"

  depends_on :macos
  depends_on macos: :sequoia
  depends_on arch: :arm64

  def install
    bin.install "imessage-max"
  end

  test do
    assert_match "iMessage Max", shell_output("#{bin}/imessage-max --version")
  end
end
```

Observed `brew audit` nits: `url` should come before `version`; `version` is redundant when the url's `vX.Y.Z` segment carries it (keep it anyway, see Step 2 — it is the value the check script reads); `arch:` dependency should precede the `macos:` dependency. The Formula installs a prebuilt binary; there is no build step, which is why `--build-from-source` in the docs is misleading.

### Docs

`docs/RELEASING.md:3-6`:

```
The version is written by hand in four places. `scripts/check-version.sh`
(also `make version`, CI, and `VersionConsistencyTests`) fails if they
disagree. `swift/Sources/iMessageMax/Server/Version.swift` is the source
of truth; the other three must match it.
```

`docs/RELEASING.md:42-59` (step 4, the broken part):

```
## 4. Update the Homebrew Formula

curl -LO https://github.com/cyberpapiii/imessage-max/releases/download/v1.4.3/imessage-max-macos.tar.gz
shasum -a 256 imessage-max-macos.tar.gz

In `swift/Formula/imessage-max.rb`, set `url` to the new release asset
and `sha256` to the printed digest. Then confirm the package installs and
its test passes ...

brew install --build-from-source swift/Formula/imessage-max.rb
brew test imessage-max

Commit the Formula change.
```

There is no step that publishes the Formula to the tap. `README.md:107-110` tells users `brew tap cyberpapiii/tap` then `brew install imessage-max`, so the tap is the thing users install from. The tap checkout on the operator's machine lives at `/opt/homebrew/Library/Taps/cyberpapiii/homebrew-tap/` (verify with `brew tap-info cyberpapiii/tap` before writing that path into the doc; if the path differs, use the printed one).

`CHANGELOG.md:31-34`:

```
- `--version` prints `iMessage Max <version>`; `scripts/check-version.sh` and `make release-check` keep the four version sites aligned.
- CI and release workflows target `macos-26`, current action majors, and an arm64-only release asset.

Formula `url`/`sha256` still point at the v1.4.1 tarball until the v1.5.0 tag artifact exists.
```

Line 34 is stale: the Formula already points at v1.5.0 (see the Formula excerpt).

`AGENTS.md:90`: `- Language: Swift 6.1`. The toolchain in use is Swift 6.3 (`swift --version` on the operator's machine and the `macos-26` runner both report 6.3; confirm with the command in Step 6).

`AGENTS.md:100-121` directory tree omits `Models/` entirely and lists only 8 of 12 `Server/` files. Actual tree (from `find swift/Sources/iMessageMax -type f -name '*.swift' | sort`):

```
Contacts/    ContactResolver.swift, PhoneUtils.swift
Database/    AppleTime.swift, Database.swift, Errors.swift, QueryBuilder.swift, SQLiteRow.swift
Enrichment/  ImageProcessor.swift
Models/      AttachmentType.swift, ChatIdentity.swift, Reactions.swift, ResponsePrimitives.swift, SendPayload.swift
Server/      DualEraStdioTransport.swift, HTTPTransport.swift, IconMetadata.swift, MCPServer.swift,
             ModernProtocol.swift, OriginValidationMiddleware.swift, ServerExtensions.swift,
             SessionManager.swift, SSEConnection.swift, ToolCallDispatch.swift, ToolRegistry.swift, Version.swift
Tools/       16 files (Diagnose, FindChat, GetActiveConversations, GetAttachment, GetChatDetails, GetContext,
             GetMessages, GetMessagesInternals, GetUnread, ListAttachments, ListChats, Search, SearchInternals,
             Send, SendResolution, SendVerifier)
Utilities/   19 files
iMessageMaxCommand.swift
```

`swift/Makefile:60-66` — `version` and `release-check` targets call the script; `release-check` runs `ruby -c Formula/imessage-max.rb`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| Full suite | `cd swift && swift test` | `Executed 370 tests, with 0 failures` (count may be higher after this plan; failures must be 0) |
| Version test | `cd swift && swift test --filter VersionConsistencyTests` | `Executed 1 test, with 0 failures` |
| Version script | `scripts/check-version.sh` | prints `OK 1.5.0`, exit 0 |
| Tag mode (off-tag) | `scripts/check-version.sh --tag; echo $?` | prints `TAG MISMATCH HEAD tag '' != v1.5.0`, exit 1 |
| Formula syntax | `ruby -c swift/Formula/imessage-max.rb` | `Syntax OK` |
| Formula audit | `brew audit --strict --formula swift/Formula/imessage-max.rb` | no output, exit 0 (Homebrew 6 may refuse a path; see Step 4) |
| Workflow YAML lint | `python3 -c 'import yaml,sys;[yaml.safe_load(open(f)) for f in sys.argv[1:]]' .github/workflows/release.yml .github/workflows/build.yml .github/dependabot.yml` | no output, exit 0 (if `yaml` is not installed: `ruby -ryaml -e 'ARGV.each{|f| YAML.load_file(f)}' <files>`) |
| Tag SHA lookup | `gh api repos/actions/checkout/git/ref/tags/v7 --jq .object.sha` | 40-hex SHA (if `.object.type` is `tag`, dereference: see Step 3) |
| Swift version | `swift --version 2>&1 \| head -1` | `Apple Swift version 6.3...` |

## Scope

**In scope** (the only files you should modify):
- `.github/workflows/release.yml`
- `.github/workflows/build.yml` (SHA pins only)
- `.github/dependabot.yml` (create)
- `scripts/check-version.sh`
- `swift/Tests/iMessageMaxTests/VersionConsistencyTests.swift`
- `swift/Formula/imessage-max.rb` (ordering only; do not change `url`, `sha256`, or `version` values)
- `docs/RELEASING.md`
- `CHANGELOG.md` (delete one line; add nothing about this plan — the release notes are written at release time)
- `AGENTS.md` (lines 90 and 100-121 only)
- `README.md` (only if the tap text at 107-110 is found wrong; expected: no change)

**Out of scope** (do NOT touch, even though they look related):
- `swift/Sources/**` — no source changes in this plan.
- `.github/workflows/release.yml:27-30` test invocation (`--parallel`) — plan 066 owns it.
- `swift/Makefile` — `release-check` already does the right thing locally.
- Any version bump. `Version.current` stays `1.5.0`.
- The tap repository itself (`cyberpapiii/homebrew-tap`). The doc describes the operator's step; the executor does not push to the tap.
- `.mcp.json` — never touch.

## Git workflow

- Branch: `advisor/067-release-hygiene` from current `main`.
- Conventional commits, one per step: `ci:`, `test:`, `chore:`, `docs:`. Examples from `git log`: `ci: run the suite serially on macos-26`, `docs: record 060 serial CI`.
- Do NOT push, tag, or open a PR. Do not push to the tap.
- Never commit secrets. No tokens are needed for this plan; `gh api` uses the operator's existing auth.

Standing rules for this repo: never add `Task.sleep` under `swift/Sources` (`LaunchdSafetyTests` enforces it; this plan adds no source, so it cannot trip); never touch `.mcp.json`.

## Steps

### Step 1: Release workflow — timeout, tag check, version assertion

Edit `.github/workflows/release.yml`:

1. After `runs-on: macos-26` (line 11) add `timeout-minutes: 20`. The release job builds twice (debug+tests, then release) so it needs more than build.yml's 15.
2. After the "Show toolchain" step, add a step that runs the version check in tag mode. It must run from the repo root, mirroring `build.yml:48-50`. On `workflow_dispatch` there is no tag, so gate the `--tag` flag on the ref:

```yaml
      - name: Check version consistency (and tag on tag pushes)
        working-directory: .
        run: |
          if [[ "$GITHUB_REF" == refs/tags/v* ]]; then
            scripts/check-version.sh --tag
          else
            scripts/check-version.sh
          fi
```

`actions/checkout` fetches the tag ref on a tag push, so `git describe --tags --exact-match` works there. Add `with: fetch-tags: true` to the checkout step defensively (checkout v4+ supports it; it is harmless on v7).

3. Replace line 53 (`echo "Binary reports version: ..."`) with an assertion that the binary's `--version` output contains the number from `Version.swift`:

```yaml
          EXPECTED=$(sed -nE 's/^ *static let current = "([^"]+)"/\1/p' Sources/iMessageMax/Server/Version.swift)
          REPORTED=$("$BINARY" --version)
          echo "Binary reports version: $REPORTED"
          [[ "$REPORTED" == *"$EXPECTED"* ]] || { echo "version mismatch: binary '$REPORTED' vs Version.swift '$EXPECTED'"; exit 1; }
```

(The step's `working-directory` is `swift`, so the `Sources/...` path is relative to that. The `sed` expression is copied from `scripts/check-version.sh:6`.)

**Verify**: YAML lint command from the table → exit 0. `grep -n "timeout-minutes: 20" .github/workflows/release.yml` → one match. `grep -n "check-version.sh --tag" .github/workflows/release.yml` → one match. `grep -n 'echo "Binary reports version' .github/workflows/release.yml` → one match, followed by the `[[ ... ]] ||` assertion line.

Commit: `ci: time out, tag-check, and assert the version in the release job`.

### Step 2: Formula becomes a checked version site

Edit `scripts/check-version.sh`:

1. After line 10 add two reads:

```bash
formula_v=$(sed -nE 's/^ *version "([^"]+)"/\1/p' swift/Formula/imessage-max.rb)
formula_url_v=$(sed -nE 's|^ *url ".*/releases/download/v([^/]+)/.*"|\1|p' swift/Formula/imessage-max.rb)
```

2. Extend the `for pair in` list on line 13 with `"Formula version:$formula_v" "Formula url:$formula_url_v"`.
3. Update the header comment on line 2 if it says "every hand-written copy" (it does; the text stays true, no change needed).

Edit `swift/Tests/iMessageMaxTests/VersionConsistencyTests.swift`:

1. Change the doc comment on line 4 from "four hand-written copies" to "hand-written copies" (do not bake a count in).
2. Before the `Version.display` assertion (line 23) add:

```swift
        let formula = try String(contentsOf: root.appendingPathComponent("swift/Formula/imessage-max.rb"), encoding: .utf8)
        XCTAssertTrue(formula.contains("version \"\(expected)\""), "Formula version")
        XCTAssertTrue(formula.contains("/releases/download/v\(expected)/"), "Formula url tag segment")
```

Edit `docs/RELEASING.md`:

1. Line 3: "written by hand in four places" → "written by hand in five places" and line 6 "the other three" → "the other four". Line 10 "Edit all four sites" → "Edit all five sites". Line 29 "checks the four version sites" → "checks the five version sites".
2. In the §1 `sed` block (lines 13-19) add a line for the Formula:

```bash
sed -i '' "s/v$OLD\//v$NEW\//; s/version \"$OLD\"/version \"$NEW\"/" swift/Formula/imessage-max.rb
```

and note after the block: "The Formula `sha256` cannot be known until the release asset exists; step 4 fills it in. `scripts/check-version.sh` checks the version and url tag only."

**Verify**:
- `scripts/check-version.sh` → `OK 1.5.0`.
- Prove the check bites: `sed -i '' 's/version "1.5.0"/version "9.9.9"/' swift/Formula/imessage-max.rb && scripts/check-version.sh; echo "exit=$?"; git checkout swift/Formula/imessage-max.rb` → prints `MISMATCH Formula version = 9.9.9 (Version.swift = 1.5.0)` and `exit=1`.
- `cd swift && swift test --filter VersionConsistencyTests` → `Executed 1 test, with 0 failures`.
- Same mutation with the test: mutate, run the filter, expect 1 failure naming "Formula version", restore with `git checkout`.
- `grep -c "four" docs/RELEASING.md` → `0`.

Commit: `test: check the Formula version and url tag with the other version sites`.

### Step 3: Pin actions to commit SHAs, add Dependabot, publish the tarball digest

For each of the five action references, look up the SHA of the tag currently in use. For every action, run:

```bash
gh api repos/<owner>/<repo>/git/ref/tags/<tag> --jq '.object | "\(.type) \(.sha)"'
```

If the output starts with `commit`, use that SHA. If it starts with `tag` (an annotated tag), dereference it:

```bash
gh api repos/<owner>/<repo>/git/tags/<sha> --jq .object.sha
```

The five references:

| File:line | Reference | Lookup |
|-----------|-----------|--------|
| `release.yml:20` | `actions/checkout@v7` | `gh api repos/actions/checkout/git/ref/tags/v7 ...` |
| `build.yml:40` | `actions/checkout@v7` | same SHA as above |
| `build.yml:53` | `actions/cache@v6` | `gh api repos/actions/cache/git/ref/tags/v6 ...` |
| `release.yml:63` | `actions/upload-artifact@v6` | `gh api repos/actions/upload-artifact/git/ref/tags/v6 ...` |
| `release.yml:70` | `softprops/action-gh-release@v3` | `gh api repos/softprops/action-gh-release/git/ref/tags/v3 ...` |

Also record the exact patch tag the major points at (`gh api repos/<owner>/<repo>/releases/latest --jq .tag_name`, or list tags) so the comment is precise. Write each reference as `uses: owner/repo@<40-hex-sha> # vX.Y.Z`. Dependabot reads that trailing comment to know the current version.

Create `.github/dependabot.yml`:

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: monthly
    commit-message:
      prefix: ci
```

GitHub Actions ecosystem only. Do not add a `swift` ecosystem entry (Dependabot's Swift support would open PRs against `Package.resolved`, which this repo pins deliberately).

Put the tarball digest into the release body. In `release.yml`, change the "Create tarball" step so the digest is captured, and pass it to the release step:

```yaml
      - name: Create tarball
        id: tarball
        run: |
          cd .build/arm64-apple-macosx/release
          tar -czvf imessage-max-macos.tar.gz imessage-max
          DIGEST=$(shasum -a 256 imessage-max-macos.tar.gz | cut -d' ' -f1)
          echo "sha256=$DIGEST" >> "$GITHUB_OUTPUT"
          echo "imessage-max-macos.tar.gz sha256 $DIGEST"
          mv imessage-max-macos.tar.gz $GITHUB_WORKSPACE/
```

and in the release step add:

```yaml
        with:
          files: imessage-max-macos.tar.gz
          generate_release_notes: true
          append_body: true
          body: |
            `imessage-max-macos.tar.gz` sha256: `${{ steps.tarball.outputs.sha256 }}`
```

(`append_body` is a documented `softprops/action-gh-release` input; with `generate_release_notes: true` the generated notes come first and the body is appended.)

Optional, only if `gh api repos/actions/attest-build-provenance/git/ref/tags/v3` resolves: add after the tarball step

```yaml
      - name: Attest build provenance
        if: startsWith(github.ref, 'refs/tags/v')
        uses: actions/attest-build-provenance@<sha> # vX.Y.Z
        with:
          subject-path: imessage-max-macos.tar.gz
```

and add `id-token: write` and `attestations: write` to the job `permissions`. If you add it, say so in the commit body. If in doubt, skip it; it is not a done criterion.

**Verify**:
- `grep -nE "uses: [^@]+@v[0-9]+$" .github/workflows/*.yml` → no matches.
- `grep -nE "uses: [^@]+@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+" .github/workflows/*.yml` → 5 matches (6 if provenance was added).
- For each SHA, `gh api repos/<owner>/<repo>/commits/<sha> --jq .sha` → echoes the same SHA (proves it exists in that repo).
- YAML lint command from the table → exit 0 for all three files.
- `grep -n "append_body: true" .github/workflows/release.yml` → one match.

Commit: `ci: pin actions to commit SHAs, add Dependabot, publish the tarball sha256`.

### Step 4: Formula ordering per brew audit

Reorder `swift/Formula/imessage-max.rb` without changing any value:

```ruby
class ImessageMax < Formula
  desc "MCP server for iMessage - AI assistant integration"
  homepage "https://github.com/cyberpapiii/imessage-max"
  url "https://github.com/cyberpapiii/imessage-max/releases/download/v1.5.0/imessage-max-macos.tar.gz"
  # version is redundant with the url's tag segment; kept because
  # scripts/check-version.sh and VersionConsistencyTests read it.
  version "1.5.0"
  # (existing sha256 comment unchanged)
  sha256 "67506beed6266c83714fb844cff22a824af2d6d03960096570328ebf664fe72d"
  license "MIT"

  depends_on arch: :arm64
  depends_on :macos
  depends_on macos: :sequoia
  ...
```

Keep `version` (Step 2 reads it). If `brew audit --strict` still flags `version` as redundant, note it in the commit body and leave it.

**Verify**:
- `ruby -c swift/Formula/imessage-max.rb` → `Syntax OK`.
- `brew audit --strict --formula swift/Formula/imessage-max.rb` → exit 0, or only the `version`-redundant note. If Homebrew refuses a path argument ("No available formula" or similar), instead run `brew audit --strict cyberpapiii/tap/imessage-max` after copying the file over the tap's copy locally (`cp swift/Formula/imessage-max.rb "$(brew --repository cyberpapiii/tap)/Formula/imessage-max.rb"` — check whether the tap keeps formulas at the root or under `Formula/` with `ls "$(brew --repository cyberpapiii/tap)"`), then `git -C "$(brew --repository cyberpapiii/tap)" checkout -- .` to restore. Do not commit or push in the tap.
- `scripts/check-version.sh` → `OK 1.5.0` (ordering change must not break the `sed` reads).
- `cd swift && swift test --filter VersionConsistencyTests` → 0 failures.

Commit: `chore: order the Formula the way brew audit wants`.

### Step 5: Rewrite RELEASING.md step 4 and add the tap step and close-out

Replace `docs/RELEASING.md:42-59` with:

````markdown
## 4. Verify the release asset

```bash
VERSION=1.4.3
curl -LO https://github.com/cyberpapiii/imessage-max/releases/download/v$VERSION/imessage-max-macos.tar.gz
shasum -a 256 imessage-max-macos.tar.gz
mkdir -p /tmp/imessage-max-release && tar -xzf imessage-max-macos.tar.gz -C /tmp/imessage-max-release
/tmp/imessage-max-release/imessage-max --version      # iMessage Max 1.4.3
codesign -dv /tmp/imessage-max-release/imessage-max 2>&1 | grep Signature   # Signature=adhoc
```

The digest must match the one in the GitHub release body. `Signature=adhoc`
is required: the Formula ships this binary as-is, and a binary signed with
the local "iMessage Max Dev" identity is trusted by no other machine.

Do not run `brew install --build-from-source swift/Formula/imessage-max.rb`.
Homebrew 6 refuses a path argument when a formula of that name already
exists in a tap (`cyberpapiii/tap/imessage-max`), and the Formula installs
the prebuilt tarball anyway, so there is nothing to build.

## 5. Update the Formula and publish it to the tap

In `swift/Formula/imessage-max.rb`, set `url` to the new asset and `sha256`
to the digest from step 4 (`version` was already bumped in step 1). Commit.

Then copy it into the tap checkout, commit, and push (this is the operator's
push, not CI's):

```bash
TAP=$(brew --repository cyberpapiii/tap)
cp swift/Formula/imessage-max.rb "$TAP/imessage-max.rb"   # or "$TAP/Formula/imessage-max.rb" if the tap uses a Formula/ directory
git -C "$TAP" commit -am "imessage-max $VERSION"
git -C "$TAP" push
brew update
brew install cyberpapiii/tap/imessage-max   # or brew upgrade imessage-max
brew test imessage-max
```

`brew test` runs `imessage-max --version` and matches `iMessage Max`.

## 6. Close out

Remove any provisional line from `CHANGELOG.md` (for example a note that
the Formula still points at an older tarball) and commit it with the
Formula change.
````

Before writing the tap path, run `ls "$(brew --repository cyberpapiii/tap)"` and put the real layout in the doc instead of the "or" alternative.

**Verify**:
- `grep -c "build-from-source" docs/RELEASING.md` → `1` (the "do not run" sentence only).
- `grep -n "Signature=adhoc" docs/RELEASING.md` → one match.
- `grep -n "brew install cyberpapiii/tap/imessage-max" docs/RELEASING.md` → one match.
- `grep -n "^## 6. Close out" docs/RELEASING.md` → one match.

Commit: `docs: describe the release verification and tap publish that actually work`.

### Step 6: CHANGELOG and AGENTS.md corrections

1. Delete `CHANGELOG.md:34` (the "Formula `url`/`sha256` still point at the v1.4.1 tarball..." line) and the blank line before it if that leaves two consecutive blank lines. Do not add a new entry.
2. `AGENTS.md:90`: `Swift 6.1` → `Swift 6.3`. Confirm first: `swift --version 2>&1 | head -1` must show 6.3. If it shows something else, use that number.
3. Regenerate the tree in `AGENTS.md:100-121`. Run

```bash
find swift/Sources/iMessageMax -type f -name '*.swift' | sort
```

and rewrite the block so every directory is present, `Models/` is listed with its five files, and `Server/` lists all twelve. Keep the one-line role comments that exist; add short ones for the new entries (`ToolCallDispatch.swift # tools/call routing`, `ServerExtensions.swift # Server helpers`, `IconMetadata.swift # icon/_meta for tools/list`, `Version.swift # Version.current, the source of truth`). Keep `Tools/ # 12 MCP tools` as a summary line rather than listing 16 files, but make it `Tools/ # 12 MCP tools across 16 files`.
4. Read `README.md:104-110`. If it says `brew tap cyberpapiii/tap` then `brew install imessage-max`, leave it. Change it only if the tap name does not match `brew tap-info cyberpapiii/tap`.

**Verify**:
- `grep -n "v1.4.1" CHANGELOG.md` → no matches.
- `grep -n "Swift 6.1" AGENTS.md` → no matches; `grep -n "Swift 6.3" AGENTS.md` → one match.
- `grep -n "Models/" AGENTS.md` → at least one match inside the tree block.
- `for f in ToolCallDispatch ServerExtensions IconMetadata Version; do grep -q "$f.swift" AGENTS.md || echo "missing $f"; done` → no output.
- `cd swift && swift build` → exit 0 (nothing should have changed; this catches an accidental source edit).

Commit: `docs: drop the stale Formula note and fix the AGENTS.md toolchain and tree`.

## Test plan

- `VersionConsistencyTests` gains two assertions (Formula `version`, Formula url tag segment). Prove each bites with the mutation in Step 2, then restore.
- `scripts/check-version.sh` gains two sites; prove with the same mutation.
- No other Swift tests change. Full suite: `cd swift && swift test` → 0 failures, count ≥ 370.
- Workflow changes cannot be executed locally. The YAML lint plus the `gh api` SHA existence checks are the gate. The first real tag push after merge is the integration test; the maintenance notes say what to look at.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift build` exits 0
- [ ] `cd swift && swift test` exits 0 with 0 failures
- [ ] `scripts/check-version.sh` prints `OK 1.5.0`
- [ ] `grep -n "timeout-minutes: 20" .github/workflows/release.yml` → 1 match
- [ ] `grep -n "check-version.sh --tag" .github/workflows/release.yml` → 1 match
- [ ] `grep -nE "uses: [^@]+@v[0-9]+$" .github/workflows/*.yml` → no matches
- [ ] `test -f .github/dependabot.yml && grep -q github-actions .github/dependabot.yml`
- [ ] `grep -n "append_body: true" .github/workflows/release.yml` → 1 match
- [ ] `grep -q 'formula' scripts/check-version.sh` and `grep -q 'imessage-max.rb' swift/Tests/iMessageMaxTests/VersionConsistencyTests.swift`
- [ ] `grep -c "four" docs/RELEASING.md` → 0; `grep -c "build-from-source" docs/RELEASING.md` → 1
- [ ] `grep -n "v1.4.1" CHANGELOG.md` → no matches
- [ ] `grep -n "Swift 6.1" AGENTS.md` → no matches
- [ ] `ruby -c swift/Formula/imessage-max.rb` → `Syntax OK`; `url` line precedes `version` line
- [ ] `git status --porcelain` lists only in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any "Current state" excerpt does not match the live file (drift).
- `gh api repos/<owner>/<repo>/git/ref/tags/<tag>` fails (auth, rate limit, or 404) for any of the five actions. Do not guess a SHA and do not copy one from memory or another repo.
- `swift --version` does not report 6.3.x (then the AGENTS.md line needs a different number, and plan 066's assumptions may be off too).
- `brew tap-info cyberpapiii/tap` reports the tap is not installed (the doc's tap path cannot be verified; write the step with `brew --repository cyberpapiii/tap` and say in the report that the layout was not checked).
- The `sed` in Step 2 returns empty for either Formula field after Step 4's reordering (the regexes assume `version "..."` and a `/releases/download/vX.Y.Z/` url on their own lines).
- `README.md:107-110` names a tap other than `cyberpapiii/tap`.
- Any step needs a change under `swift/Sources`.

## Maintenance notes

- **First tag push after merge**: watch the release job. The new tag-check step will fail if the tag does not equal `v<Version.current>`; that is the intended behaviour. The version assertion will fail if the binary was built without the embedded plist and `--version` reports something unexpected.
- **Dependabot PRs** will bump the SHA and the trailing `# vX.Y.Z` comment together. Review the diff shows both moving; a PR that changes only the comment is wrong.
- **Adding a sixth version site** (for example a `Cargo.toml`-style manifest or a docs badge) means: add a read to `scripts/check-version.sh`, an assertion to `VersionConsistencyTests`, and a `sed` line to `RELEASING.md` §1. All three, every time.
- **Reviewer should scrutinize**: the five SHAs resolve to the intended tags (run the `gh api .../commits/<sha>` check yourself), the `append_body` output renders in a test release if one is cut, and the tap layout named in RELEASING.md step 5 is the real one.
- **Deferred**: provenance attestation is optional here and can be its own change. Making the Formula `version` line disappear (deriving from url) was rejected because two checks read it.
- **Plan 066 owns** the `--parallel` question in `release.yml:30`; if 066 lands after this plan, its edit is on a different line and merges cleanly.
