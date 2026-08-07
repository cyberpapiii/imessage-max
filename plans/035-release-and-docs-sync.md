# Plan 035: Sync release metadata and docs with reality (Formula, macOS floor, content API, architecture tree)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat e3d14da..HEAD -- swift/Formula README.md swift/README.md AGENTS.md swift/Package.swift`
> If versions moved again since this plan was written, sync to the LIVE
> values (`swift/Sources/iMessageMax/Server/Version.swift` and
> `Package.swift` are the source of truth), not to the numbers quoted here.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW (docs + metadata; one dependency floor bump)
- **Depends on**: none. **Ordering note**: plan 032 deletes
  `AudioProcessor.swift`/`VideoProcessor.swift` and three `Models/` files —
  if 032 has landed, the architecture tree you write in Step 4 must reflect
  that; if not, reflect the current tree and expect 032 to touch it again.
- **Category**: docs + release
- **Planned at**: commit `e3d14da`, 2026-08-07

## Why this matters

The repo's outward-facing claims disagree with its code in four places. Each
is small; together they mean a new user following the docs hits a wall:

1. **The Homebrew formula installs v1.0.2** while the code is v1.3.0 — three
   minor versions (including the entire dual-era MCP lane and the
   verified-send contract) behind what the docs describe.
2. **Both READMEs claim macOS 13 (Ventura)** but `Package.swift` declares
   `.macOS(.v14)` — the binary won't run on Ventura, and the formula's
   `depends_on macos: :ventura` lets Homebrew try anyway.
3. **AGENTS.md documents a tool-content API that doesn't exist in this
   codebase** (`.text(...)` / `.image(data:..., metadata: nil)`); the actual
   convention is the `.plainText`/`.plainImage` helpers. Agents reading
   AGENTS.md as ground truth will write non-compiling code.
4. **swift/README's architecture tree** is missing roughly half the current
   source files and says "12 MCP tools" over a list of 11.

## Current state (each item verified against the live code)

**Version truth**: `swift/Sources/iMessageMax/Server/Version.swift:5` →
`static let current = "1.3.0"`. Platform truth: `swift/Package.swift:6` →
`platforms: [.macOS(.v14)]`.

**(1) Formula** — `swift/Formula/imessage-max.rb`:

```ruby
  url "https://github.com/cyberpapiii/imessage-max/releases/download/v1.0.2/imessage-max-macos.tar.gz"
  sha256 "9359d6e8142b3473dd55877cd6a1f38f7629751f59f24e72600b17d0adce2e68"
  ...
  depends_on macos: :ventura
```

**(2) macOS floor** — `README.md:404`: `- macOS 13+ (Ventura or later)`;
`swift/README.md:44`: `- macOS 13+ (Ventura)`.

**(3) Content API** — `AGENTS.md:254-257` shows:

```swift
return [
    .text("photo.jpg (800x600, 45KB)"),
    .image(data: base64String, mimeType: "image/jpeg", metadata: nil)
]
```

The real API (`swift/Sources/iMessageMax/Server/ServerExtensions.swift:174-178`):
`static func plainText(_ text: String)` and
`static func plainImage(data: String, mimeType: String)`. Real usage
exemplar (`swift/Sources/iMessageMax/Tools/GetAttachment.swift:73-76`):

```swift
                return [
                    .plainText(try FormatUtils.encodeJSON(metadata)),
                    .plainImage(data: imageData, mimeType: mimeType)
                ]
```

`grep -rn "\.plainText\|\.plainImage" swift/Sources` → dozens of hits;
`grep -rn "\.text(\|\.image(" swift/Sources/iMessageMax/Tools` → none.

**(4) Architecture tree** — `swift/README.md` "### Core Components" block
lists e.g. `Utilities/` with only 3 files (AppleTime, PhoneUtils, TimeUtils)
while the live directory has ~20; omits `Models/`, `SendVerifier.swift`,
`SendResolution.swift`, `GetChatDetails.swift`, `ServerExtensions.swift`,
`Version.swift`, and more; and still lists `VideoProcessor.swift` /
`AudioProcessor.swift` (dead code that plan 032 deletes).

**(5) Dependency floor** — `swift/Package.swift:13` pins
`hummingbird from: "2.0.0"`; `Package.resolved` has 2.19.0; upstream latest
is 2.26.x. (The MCP swift-sdk pin `from: "0.12.0"` is already at the latest
release line — leave it.)

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `cd swift && swift build` | exit 0 |
| Full suite | `cd swift && swift test` | exit 0, 0 failures |
| Dep update | `cd swift && swift package update hummingbird` | Package.resolved moves to latest 2.x |
| Formula lint (if brew present) | `brew style swift/Formula/imessage-max.rb` | no offenses (skip if brew absent) |

## Scope

**In scope** (the only files you should modify):
- `swift/Formula/imessage-max.rb`
- `README.md` (Requirements section)
- `swift/README.md` (Requirements + Core Components tree)
- `AGENTS.md` (the Image Handling snippet only)
- `swift/Package.swift` + `swift/Package.resolved` (hummingbird floor)
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):
- `Version.swift` — do not bump the version; this plan syncs docs TO it.
- Cutting an actual GitHub release / building the tarball — see Step 1's
  honest-formula rule; publishing is the operator's call.
- The MCP swift-sdk dependency (already current; migration is a separate
  known-deferred item).
- Any other AGENTS.md section (the send contract, launchd rules, etc. are
  maintained by their own plans).

## Git workflow

- Branch: `advisor/035-release-and-docs-sync`
- Conventional commits, e.g. `docs: sync macOS floor and content API; build: raise hummingbird floor; chore(formula): point at v1.3.0`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Formula

Update `swift/Formula/imessage-max.rb`:
- `url` → `.../releases/download/v1.3.0/imessage-max-macos.tar.gz`
- `depends_on macos: :sonoma` (matches `.macOS(.v14)`)
- `sha256` — **you cannot invent this.** If a v1.3.0 release asset exists
  (`gh release view v1.3.0 --json assets` or check the GitHub releases
  page), download it and compute `shasum -a 256`. If NO v1.3.0 asset exists,
  set the sha256 line to a clearly-invalid placeholder with a TODO comment:

```ruby
  # TODO(release): replace after publishing the v1.3.0 asset —
  # `shasum -a 256 imessage-max-macos.tar.gz`
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
```

  and flag it in your completion report. A formula that fails loudly beats
  one that installs a 3-versions-old binary silently.

**Verify**: `ruby -c swift/Formula/imessage-max.rb` → "Syntax OK"; `brew
style` if available.

### Step 2: macOS floor in both READMEs

- `README.md:404`: `- macOS 13+ (Ventura or later)` → `- macOS 14+ (Sonoma or later)`
- `swift/README.md:44`: `- macOS 13+ (Ventura)` → `- macOS 14+ (Sonoma)`
- Sweep for stragglers: `grep -rn "macOS 13\|Ventura" README.md swift/README.md AGENTS.md docs/` —
  fix any that state the *requirement* (leave historical/changelog mentions
  alone).

**Verify**: the grep above returns no requirement-statements.

### Step 3: AGENTS.md content-API snippet

Replace the stale snippet in the "### Image Handling" section
(`AGENTS.md:254-257`) with the real convention, modeled on
`GetAttachment.swift:73-76`:

```swift
return [
    .plainText(try FormatUtils.encodeJSON(metadata)),
    .plainImage(data: base64String, mimeType: "image/jpeg")
]
```

Add one sentence noting these are repo helpers defined in
`Server/ServerExtensions.swift` (annotations-free wrappers over the SDK's
content cases). Keep the surrounding prose about avoiding base64-in-JSON
token bloat — it's still accurate.

**Verify**: `grep -n "\.text(\|metadata: nil" AGENTS.md` → no matches in the
Image Handling section.

### Step 4: swift/README architecture tree

Regenerate the "### Core Components" tree from the live filesystem
(`find swift/Sources/iMessageMax -name "*.swift" | sort`). Rules:
- Every existing file appears; no deleted file appears (if plan 032 landed,
  `Enrichment/` has only `ImageProcessor.swift` and `Models/` lacks
  Message/Chat/Attachment).
- Keep the one-line `# comment` style for files whose current comment is
  still accurate; write a short accurate one for new entries (read the
  file's header comment for wording).
- Count the tools directory and make the "N MCP tools" label match the
  actual file count (exclude `*Internals.swift` helpers from the count and
  say so: e.g. "12 tool files + internals").

**Verify**: every path in the tree exists
(`for p in <paths>; do test -f "$p" || echo MISSING $p; done` — or eyeball
against `find` output); no path missing from the tree.

### Step 5: Hummingbird floor

In `swift/Package.swift:13`, raise the floor to the currently-resolved-or-
newer minor: `from: "2.19.0"` (or higher if `swift package update
hummingbird` resolves higher). Then run
`cd swift && swift package update hummingbird`.

**Verify**: `cd swift && swift build && swift test` → exit 0, 0 failures,
174+ tests (count unchanged from baseline). If the newer Hummingbird breaks
the build or any test, STOP — pin back to the last green version, report
the breakage.

## Test plan

No new tests — the full suite run in Step 5 is the gate (this plan is docs +
metadata + one dependency floor).

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `cd swift && swift test` exits 0; 0 failures
- [ ] `grep -n "v1.0.2" swift/Formula/imessage-max.rb` → no matches
- [ ] `grep -n ":ventura" swift/Formula/imessage-max.rb` → no matches
- [ ] `grep -rn "macOS 13" README.md swift/README.md` → no matches
- [ ] `grep -n "metadata: nil" AGENTS.md` → no matches
- [ ] `grep -n "VideoProcessor\|AudioProcessor" swift/README.md` → matches only if those files still exist on disk
- [ ] `grep -n '"2.0.0"' swift/Package.swift` → no hummingbird match
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Hummingbird ≥2.19 introduces a compile error or test failure — report
  version + error; do not patch server code to chase the dependency (that's
  a separate migration decision).
- You are tempted to bump `Version.swift` to "make things consistent" — the
  operator owns version bumps and release cuts; report instead.
- The GitHub releases page shows assets newer than v1.3.0 — the repo moved;
  sync the formula to the newest published release and note it.

## Maintenance notes

- Recurring failure mode this plan fixes: the formula/README/AGENTS drift
  because releases update `Version.swift` but nothing forces the metadata to
  follow. If this recurs, the durable fix is a release checklist (or CI
  check) that greps the formula and READMEs for the current version — a
  candidate future plan, deliberately not included here.
- The architecture tree will rot again; regenerating it from `find` (Step
  4's method) takes two minutes and should be part of any release pass.
