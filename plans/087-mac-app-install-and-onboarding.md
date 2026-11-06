# Plan 087. Install and onboard iMessage Max like a normal Mac app

An everyday Mac user downloads one notarized `iMessage Max.app`, drags it to Applications, and has an AI client reading their messages a few minutes later.
They never open Terminal, never edit JSON, and never hunt for a hidden binary to grant Full Disk Access.
The rule the program enforces is one helper with one identity. The helper ships inside the app, owns every macOS permission, and answers every client through an authenticated channel.
PRs in order are P1 (Developer ID signing), P2 (notarized DMG in CI), P3 (helper inside the app bundle), P4 (token auth and a new port), P5 (stdio bridge and Claude Desktop bundle), P6 (one-click client hookup), P7 (onboarding rewrite), and P8 (ship 2.0 through a cask and retire the formula).

## How to read this

One box is one unit of work. Every box names the evidence that checks it. A nested box is a sub-step of the box above it. Check a box only when its evidence exists, a file, a log line, a screenshot, a test run, or a SHA. The body is a how-to. The appendices explain and record.

The program runs `pstack/skills/poteto-mode/playbooks/autopilot-full.md`. Owners merge their own PRs after the root's clean verdict. P3, P6, and P7 change an interaction, so they stop at merge-ready until Rob reviews them in chat.

Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

Main may break between P4 and P6, because existing clients lose access until P6 can reconfigure them. No release tag is cut between P3 and P8. Nobody runs `make install` on Rob's live service before P8, so his working setup stays on v1.8.0 until the migration lane in P8 moves it.

## Program checklist

### Arm the program

- [ ] State the protocol and this plan to the operator, then stop. Start execution only on the operator's explicit go.
- [ ] Read these from trunk at program start. Re-read them at every tick.
  - [ ] `git show origin/main:pstack/skills/poteto-mode/playbooks/autopilot-full.md`
  - [ ] `git show origin/main:pstack/skills/swarm/SKILL.md`
  - [ ] `git show origin/main:skills/cua-driver/SKILL.md` for the control skill. Fall back to the installed `cua-driver` skill when the repo has no copy.
  - [ ] `git show origin/main:pstack/skills/poteto-mode/playbooks/opening-a-pr.md`
  - [ ] `git show origin/main:pstack/skills/how/SKILL.md` and `git show origin/main:pstack/skills/interrogate/SKILL.md` for P3 and P4.
  - [ ] `git show origin/main:AGENTS.md` for the build, test, and signing rules of this repo.
- [ ] On the operator's go, arm the audit tick as `/loop 1h` with the tick prompt below. Never leave the cadence to memory.
- [ ] Use this tick prompt, verbatim. "Re-read the execution playbook from trunk. Audit the operation against it and fix drift in this tick. Probe every active lane and judge progress by side effects only. Stand down a stuck lane and dispatch its replacement now. Then post a short status message to the operator in chat only when the audit found a tracked change that no earlier status message reported, such as a PR opened, a code-ready head, a round launched or closed, a verdict, a merge, a stuck agent and the action taken, a blocker added or cleared, or a decision only the operator can make. Name every such change and nothing else. Do not repeat a table, the merged list, or an unchanged blocker. If the audit found none, end the turn with no reply text. Either way, log this tick's row in your decision trail. The row names the items reported, or none."
- [ ] On the operator's hold or stand-down, send every owner a zero-writes order at once.
- [ ] Hold the send rule in every brief. No lane, test, or owner sends a real iMessage. Send checks use paths that send nothing, such as an ambiguous or invalid destination, or the Automation probe.
- [ ] Collect the operator items before P2 starts.
  - [ ] Rob names which of the two `Developer ID Application: Robert Dezendorf (HJF7LN64XX)` certificates to use. The one valid until 2031 is the default.
  - [ ] Rob adds `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASS`, `MACOS_SIGNING_IDENTITY`, `MACOS_NOTARY_KEY_P8`, `MACOS_NOTARY_KEY_ID`, `MACOS_NOTARY_ISSUER_ID`, and `HOMEBREW_TAP_TOKEN` to `cyberpapiii/imessage-max`. Plug's values can be reused, and `gh secret list` shows the names when done.

### Spawn owners

- [ ] Spawn one owner per PR with the full lifecycle the execution playbook names.
- [ ] Follow this dependency graph. Start dependent work only after its parent merges.
  - [ ] P1 is first and branches from `main`.
  - [ ] P2 and P3 after P1. They are independent of each other.
  - [ ] P4 after P3.
  - [ ] P5 after P4.
  - [ ] P6 after P4 and P5.
  - [ ] P7 after P3 and P6.
  - [ ] P8 after P2 and P7.
- [ ] Hold the file boundaries.
  - [ ] P1 touches only `swift/Makefile`, `swift/*.entitlements`, `script/`, `macos/`, `AGENTS.md`, and signing docs.
  - [ ] P2 touches only `.github/workflows/`, `scripts/`, and `docs/RELEASING.md`.
  - [ ] P3 touches `macos/`, `contract/`, `swift/launchd/`, `swift/Makefile`, `script/`, and the tests that pin the label and paths.
  - [ ] P4 and P5 touch `swift/Sources/iMessageMax/Server/`, `swift/Sources/iMessageMax/iMessageMaxCommand.swift`, `contract/`, `macos/Sources/MaxCore/`, `mcpb/`, `.mcp.json`, and their tests.
  - [ ] P6 and P7 touch `macos/`, `swift/Sources/iMessageMax/Tools/Diagnose.swift`, `swift/Sources/iMessageMax/Contacts/`, and docs.
  - [ ] P8 touches `README.md`, `swift/README.md`, `macos/README.md`, `docs/RELEASING.md`, `scripts/check-version.sh`, `swift/Formula/`, the version tests, and the tap repo.
- [ ] Hold the review gate. P3, P6, and P7 change an interaction. They wait for the operator's review in chat with screenshots and a video before merge.

### PR mechanics, for every PR

- [ ] Resolve the forge once. Default to `gh`; if `command -v origin` succeeds and Origin can resolve the repository, use `origin pr` for every PR operation. Record any fallback to `gh`. Never require `gt`.
- [ ] Open the PR ready, never draft, per **Opening a PR**. Use the run's built-in PR tool when it has one, else `origin pr create --status open --base <base-branch>` or `gh pr create --base <base-branch>` according to the resolved forge.
- [ ] Run the repo's checks once before the PR-facing push. That means `cd swift && CI=true swift build --build-tests`, then the suite one class at a time under a 120 second watchdog, then `cd macos && swift test` and `cd contract && swift test`.
- [ ] Run `/deslop` before each commit and `/no-comments` before review. `deslop` comes from Cursor's team kit and may be missing here. Record that and run `/simplify` instead.
- [ ] Triage every Bugbot and security-reviewer comment per `../references/bugbot-triage.md`.
- [ ] Rebase onto current trunk before the code-ready report and babysit. Keep that merge base in fix rounds. Rebase again only at merge prep, on a `git merge-tree` conflict with trunk, on a CI failure that comes from a change on trunk, or when a known concurrent change to the same files lands.

### Verdict and merge, for every PR

- [ ] A full swarm runs once, at the code-ready head. Another full swarm runs only for new behavior, a redesign, or a large new diff. A rebase, a merge-conflict resolution, or a minor fix gets a single verifier at the new head, and a wording-only change gets none. Run each full swarm per `pstack/skills/swarm/SKILL.md`. One gates lane. The ten live lanes from the PR's **Verify, live** block. The perf lane from its **Verify, perf** block. Two or more audit lanes, each with its own focus, that read the diff and the receipts and distrust the PR body. The root audits the receipts in the merge-ready report before the verdict.
- [ ] Judge every finding by the execution playbook's blocking rule. The verdict is clean when none blocks. A failure on trunk behavior in a lane marked `Regression lane against trunk.` is recorded against trunk and does not block the PR. A new head gets a fresh verdict, except for results that stay valid under the patch-id rule in `playbooks/shipping.md`.
- [ ] The owner merges its own PR with a merge commit titled `Merge #N. <title>` after the root's clean verdict at the exact head SHA. A review-gated PR also needs Rob's approval in chat. Results stay valid across a rebase only when the patch-id is unchanged, per `playbooks/shipping.md`.

### Boot recipe, for every live lane

Live lanes cannot run on cloud VMs, because they need macOS privacy prompts, launchd, and Messages. Each lane runs on Rob's Mac, in a dedicated test user account or a local macOS VM, at the PR head. Drive the app through the `cua-driver` skill and the shell through plain commands.

- [ ] `git fetch origin <head-branch> && git checkout <head SHA>` in a separate worktree, never in Rob's main checkout.
- [ ] Build with the PR's own build command and start the helper on a test port, never on Rob's live service or its port.
- [ ] Deliver input only through `cua-driver` for the app and through the shell for CLI checks. Read state through `diagnose`, `launchctl print`, `codesign -dvvv`, `spctl -a -vv`, and the service log.
- [ ] Save every screenshot to `/tmp/swarm-<pr-id>/worker-<n>/<slug>.png` and return the paths with the report.
- [ ] A lane that needs a human permission click asks Rob in chat, names the exact switch, and records his click in the report.

## Sign every build with Developer ID and hardened runtime (P1)

**Depends on.** None.

**Files.**

- [ ] Create `swift/iMessageMax.entitlements` with `com.apple.security.automation.apple-events` and `com.apple.security.personal-information.addressbook`.
- [ ] Edit `swift/Makefile` so `sign` uses `--options runtime --timestamp --entitlements`, and delete `setup-signing` and the self-signed identity lookup.
- [ ] Create `script/assemble_app.sh`, holding the bundle assembly pulled out of `script/build_and_run.sh`.
- [ ] Edit `script/build_and_run.sh` to call `script/assemble_app.sh`.
- [ ] Edit `AGENTS.md` and `macos/README.md` to name the Developer ID identity and the ad-hoc fallback for contributors.

**Build.**

- [ ] Select the identity by SHA-1 hash, from `SIGN_IDENTITY` or the newest valid Developer ID in the keychain, and fall back to ad hoc with a printed warning. Both certificates share one name, so signing by name is ambiguous.
- [ ] Sign the helper with its entitlements and the app without entitlements, both with hardened runtime and a timestamp.

**You see.**

- [ ] `codesign -dvvv` on both binaries shows `flags=0x10000(runtime)` and `TeamIdentifier=HJF7LN64XX`.
- [ ] `codesign -d --entitlements - ` on the helper lists both entitlements.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Extend `ServiceFilesContractTests` so the entitlements file exists and names both keys. Run `cd swift && CI=true swift test --filter 'iMessageMaxTests.ServiceFilesContractTests/'`.
- [ ] Run the full server, `macos`, and `contract` suites per the PR mechanics.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `inherit-parent` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Run `diagnose` against a trunk build and a head build on test ports. Save `diagnose-compare.png`. Pass when both report `database.accessible` true and the same capability states.
- [ ] Lane 2. Sign with the Developer ID and inspect the helper. Save `helper-codesign.png`. Pass when the output shows hardened runtime, the team id, and both entitlements.
- [ ] Lane 3. Inspect the app bundle signature with `codesign --verify --deep --strict`. Save `app-verify.png`. Pass when it exits 0.
- [ ] Lane 4. Call `diagnose` on the head build after a Contacts grant. Save `contacts.png`. Pass when `contacts.status` is `authorized` and names load.
- [ ] Lane 5. Run the Automation probe with `--request-messages-access` on the head build. Save `automation.png`. Pass when it reports granted without sending a message.
- [ ] Lane 6. Call `send` with an ambiguous destination on the head build. Save `send-ambiguous.png`. Pass when the status is `ambiguous` and Messages shows nothing new.
- [ ] Lane 7. Rebuild twice and restart between builds. Save `fda-persist.png`. Pass when `database.accessible` stays true with no new grant.
- [ ] Lane 8. Build with no Developer ID in the keychain, using a test keychain search list. Save `adhoc-fallback.png`. Pass when the build completes ad hoc and prints the warning.
- [ ] Lane 9. Run `script/build_and_run.sh --verify`. Save `companion-verify.png`. Pass when the companion launches and shows the ready state.
- [ ] Lane 10. Call `get_messages`, `search`, and `list_attachments` on the head build. Save `read-tools.png`. Pass when each returns results with no error.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Warm `get_active_conversations` latency, the `ms=` value on the service log's call line, at trunk and head.
- [ ] Probe. Twenty calls alternating trunk and head instances on two test ports, after three warm-up calls each.
- [ ] Baseline. Record the trunk median first.
- [ ] Rule. Fail when the head median exceeds the trunk median by more than 10 percent.

**Review gate.** None. P1 is not review-gated.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner merges its own PR.

## Build a notarized DMG in CI (P2)

**Depends on.** P1, and the operator items in Arm the program.

**Files.**

- [ ] Create `scripts/sign-notarize-app.sh`, modeled on Plug's `scripts/sign-notarize-macos-app.sh`.
- [ ] Edit `.github/workflows/release.yml` to build the app, sign, notarize, staple, and upload `iMessage-Max-<version>.dmg` next to the tarball.
- [ ] Edit `docs/RELEASING.md` with the new artifact and the dry-run procedure.

**Build.**

- [ ] Import the p12 into a temporary keychain, call `script/assemble_app.sh`, sign, run `notarytool submit --wait` with the API key, and run `stapler staple` on the app and the DMG.
- [ ] Assert the architecture, identifier, version, hardened runtime flag, and team id on both binaries before upload.
- [ ] Keep the tarball until P8 retires it.

**You see.**

- [ ] A `workflow_dispatch` run produces a DMG artifact, and its log shows `status: Accepted` from `notarytool`.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Add a shellcheck run for `scripts/sign-notarize-app.sh` to `build.yml`. Run `shellcheck scripts/sign-notarize-app.sh`.
- [ ] Run `scripts/check-version.sh` and confirm it still passes.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `inherit-parent` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Run `workflow_dispatch` on trunk and head. Trunk has no DMG, so record that and gate the head DMG plus the tarball. Save `release-runs.png`. Pass when the head run uploads both and the tarball checksum step still runs.
- [ ] Lane 2. Download the DMG through a browser so it gets quarantined, then open it. Save `dmg-open.png`. Pass when Finder mounts it with no Gatekeeper warning.
- [ ] Lane 3. Run `spctl -a -t open --context context:primary-signature -vv` on the DMG. Save `dmg-spctl.png`. Pass when it reports accepted and notarized.
- [ ] Lane 4. Drag the app to Applications and run `spctl -a -t exec -vv` on it. Save `app-spctl.png`. Pass when it reports `source=Notarized Developer ID`.
- [ ] Lane 5. Run `stapler validate` on the installed app. Save `stapler.png`. Pass when it validates.
- [ ] Lane 6. Launch the app from the DMG copy while offline. Save `offline-launch.png`. Pass when it opens with no Gatekeeper dialog.
- [ ] Lane 7. Inspect the helper inside the downloaded app with `codesign -dvvv`. Save `helper-sig.png`. Pass when it shows runtime, the team id, and both entitlements.
- [ ] Lane 8. Run the release job with a broken notary key in a fork or a dry-run flag. Save `notary-fail.png`. Pass when the job fails and prints the notary log.
- [ ] Lane 9. Run the app from the DMG on macOS 15 in the test VM. Save `macos15.png`. Pass when it launches and loads its Swift runtime without a missing dylib error.
- [ ] Lane 10. Check the helper's load commands with `otool -L`. Save `otool.png`. Pass when `libswiftCompatibilitySpan.dylib` is weak or absent.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Release job wall time and artifact size. Trunk has only the tarball job, so also budget the added DMG work.
- [ ] Probe. Two `workflow_dispatch` runs each on trunk and head, interleaved, reading job durations from `gh run view`.
- [ ] Baseline. Record the trunk job duration first.
- [ ] Rule. Fail when the head job exceeds the trunk job by more than 20 minutes, or the DMG exceeds 40 MB.

**Review gate.** None. P2 is not review-gated.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner merges its own PR.

## Run the helper from inside the app with SMAppService (P3)

**Depends on.** P1.

**Files.**

- [ ] Create `macos/Resources/LaunchAgents/com.cyberpapiii.imessage-max.helper.plist` with `BundleProgram` pointing at `Contents/MacOS/imessage-max` and `AssociatedBundleIdentifiers` naming the app.
- [ ] Edit `script/assemble_app.sh` to place the helper in `Contents/MacOS/` and the plist in `Contents/Library/LaunchAgents/`.
- [ ] Edit `macos/Sources/MaxCore/ServiceController.swift` to register, unregister, and inspect through `SMAppService.agent(plistName:)`.
- [ ] Edit `macos/Sources/MaxCore/ServiceConfiguration.swift` to drop plist rendering and adoption.
- [ ] Edit `contract/Sources/IMessageMaxContract/Service.swift` with the new label and without `launchAgentPath` and `helperInstallPath`.
- [ ] Edit `swift/Makefile` so `install` builds the app, installs it to `~/Applications`, and restarts the agent.
- [ ] Delete `swift/launchd/local.imessage-max.plist`, the `install-agent` target, and the helper copy in `ServiceController.install()`.
- [ ] Edit `ServiceFilesContractTests`, `macos/Tests/MaxCoreTests/BoundaryTests.swift`, and the docs that name the old label or paths.

**Build.**

- [ ] Prototype gate first, on a throwaway branch. Register a minimal Developer ID signed agent from a bundle, then have Rob grant Full Disk Access once. Record which name appears in Full Disk Access, Contacts, and Automation, and whether the agent reads `chat.db` after the grant.
  - [ ] If macOS charges the app, keep the plan. If it charges the helper, keep the plan and point the Full Disk Access step at the helper path inside the bundle.
- [ ] Model the service state as one enum read from `SMAppService.Status` plus `launchctl print gui/<uid>/com.cyberpapiii.imessage-max.helper`. Cover not registered, requires approval, enabled and running, enabled and stopped, and conflict.
- [ ] Migrate an old install once, with consent. Boot out `local.imessage-max`, remove its plist and the copied helper in Application Support, then register the new agent. Make the migration idempotent.
- [ ] Remove the quarantine attribute question by never copying the helper. It runs from the signed bundle.

**You see.**

- [ ] System Settings lists "iMessage Max" under Login Items, Allow in the Background, with the app icon.
- [ ] `launchctl print gui/<uid>/com.cyberpapiii.imessage-max.helper` shows the program path inside `/Applications/iMessage Max.app`.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Add `macos/Tests/MaxCoreTests/ServiceStatusTests.swift` covering each enum case from a faked status source. Run `cd macos && swift test`.
- [ ] Add migration tests with a temporary home directory that hold an old plist and an old helper. Run `cd macos && swift test --filter MigrationTests`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `inherit-parent` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Set up a fresh test account with trunk's companion, then with head's app. Save `fresh-setup.png`. Pass when head reaches the ready state with no file in `~/Library/LaunchAgents` and no copied helper.
- [ ] Lane 2. Open Login Items in System Settings after setup. Save `login-items.png`. Pass when "iMessage Max" appears with its icon under Allow in the Background.
- [ ] Lane 3. Turn the background item off in Login Items. Save `blocked.png`. Pass when the panel says the helper is blocked and offers Open Login Items.
- [ ] Lane 4. Grant Full Disk Access through the panel's step. Save `fda-grant.png`. Pass when `database.accessible` turns true after one switch.
- [ ] Lane 5. Install a v1.8.0 setup with `local.imessage-max`, then open the head app. Save `migration.png`. Pass when the old job is gone, the old plist and helper are removed, and the new agent runs.
- [ ] Lane 6. Run the migration twice. Save `migration-twice.png`. Pass when the second run changes nothing and reports ready.
- [ ] Lane 7. Replace the app with a newer head build in place. Save `update.png`. Pass when the agent restarts on the new binary and every grant still holds.
- [ ] Lane 8. Quit the menu bar app. Save `quit.png`. Pass when the helper keeps answering `diagnose`.
- [ ] Lane 9. Delete the app to the Trash and log out and back in. Save `uninstall.png`. Pass when no helper process runs and Login Items no longer lists it.
- [ ] Lane 10. Run `make install` in the head worktree on the test account. Save `make-install.png`. Pass when it installs the app and `make verify-db` passes.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Seconds from the Set up click to `diagnose` answering, with permissions already granted, at trunk and head.
- [ ] Probe. Five fresh setups each on trunk and head in the test account, interleaved, timed from the click to the first healthy `diagnose`.
- [ ] Baseline. Record the trunk median first.
- [ ] Rule. Fail when the head median exceeds the trunk median by more than 2 seconds, or exceeds 5 seconds in absolute terms.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane 1, 2, 3, and 5 screenshots into `docs/design/087/p3-review-<slug>.png`.
- [ ] Record a 30 to 60 second video of a fresh setup and a migration in the test account. Save it as `docs/design/087/p3-review.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at merge-ready. Wait for the operator's click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner merges its own PR after Rob approves in chat.

## Require a token on the HTTP endpoint and leave port 8080 (P4)

**Depends on.** P3.

**Files.**

- [ ] Create `swift/Sources/iMessageMax/Server/BearerAuthMiddleware.swift`.
- [ ] Edit `swift/Sources/iMessageMax/Server/HTTPTransport.swift` to add the middleware next to `OriginValidationMiddleware`.
- [ ] Create `swift/Sources/iMessageMax/Server/AccessToken.swift` for generating and reading the token file.
- [ ] Edit `contract/Sources/IMessageMaxContract/Service.swift` with the new default port and the token file path.
- [ ] Edit `macos/Sources/MaxCore/ServiceClient.swift`, `swift/Makefile` (`verify`, `verify-db`, `status`), and `swift/Tests/iMessageMaxTests/HTTPTestSupport.swift` to send the token.

**Build.**

- [ ] The helper creates a 32-byte random token at first start in `~/Library/Application Support/iMessage Max/token`, mode 0600, and never rewrites an existing one.
- [ ] Every HTTP route, including `/setup/permissions`, requires `Authorization: Bearer <token>`, compared in constant time. A missing or wrong token gets 401 with a JSON-RPC error body that names the companion app as the fix.
- [ ] Move the default port from 8080 to 47821 in the agent plist and `ServiceDefaults`.

**You see.**

- [ ] `curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:47821/` prints `401`.
- [ ] The service log shows one `auth=rejected` line per refused request, without the token.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Add `BearerAuthTests` for a missing, wrong, and correct token on both eras and on the setup route. Run `cd swift && CI=true swift test --filter 'iMessageMaxTests.BearerAuthTests/'`.
- [ ] Add `AccessTokenTests` for creation, mode 0600, and reuse. Run the same way.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `inherit-parent` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Call `diagnose` without a token on trunk and head. Save `no-token.png`. Pass when trunk answers and head returns 401.
- [ ] Lane 2. Call `diagnose` with the token on head, modern lane. Save `modern-token.png`. Pass when it answers with capabilities.
- [ ] Lane 3. Run legacy `initialize` and `tools/list` with the token on head. Save `legacy-token.png`. Pass when both succeed.
- [ ] Lane 4. Call the setup route without a token. Save `setup-401.png`. Pass when it returns 401 and no permission prompt appears.
- [ ] Lane 5. Read the token file mode and owner. Save `token-mode.png`. Pass when it is `-rw-------` and owned by the test user.
- [ ] Lane 6. From a second macOS user account, call the port with no token. Save `other-user.png`. Pass when it returns 401.
- [ ] Lane 7. Restart the helper. Save `token-stable.png`. Pass when the token file is unchanged and clients keep working.
- [ ] Lane 8. Open the companion panel after the change. Save `companion-ready.png`. Pass when it shows ready, which proves `ServiceClient` sends the token.
- [ ] Lane 9. Run `make verify-db` in the head worktree. Save `verify-db.png`. Pass when it passes.
- [ ] Lane 10. Start a listener on 8080 first, then start the helper. Save `port-free.png`. Pass when the helper starts on 47821 with no conflict.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Warm `get_active_conversations` latency from the call line, at trunk without auth and head with auth.
- [ ] Probe. Twenty calls alternating trunk and head on test ports after three warm-up calls each.
- [ ] Baseline. Record the trunk median first.
- [ ] Rule. Fail when the head median exceeds the trunk median by more than 5 percent.

**Review gate.** None. P4 is not review-gated.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner merges its own PR.

## Serve stdio clients through a bridge to the helper (P5)

**Depends on.** P4.

**Files.**

- [ ] Create `swift/Sources/iMessageMax/Server/SocketListener.swift` for a Unix socket at `~/Library/Application Support/iMessage Max/mcp.sock`, mode 0600.
- [ ] Create `swift/Sources/iMessageMax/Server/StdioBridge.swift` for the `--bridge` mode.
- [ ] Edit `swift/Sources/iMessageMax/iMessageMaxCommand.swift` so stdio launch runs the bridge by default and keeps in-process stdio behind `--direct` for development.
- [ ] Edit `mcpb/manifest.json` to run the bundled binary with `${__dirname}/server/imessage-max`, and `.mcp.json` to run the bridge.
- [ ] Edit `scripts/sign-notarize-app.sh` to also produce a signed `iMessage-Max.mcpb`.

**Build.**

- [ ] Each socket connection gets its own `serveStdio(base:catalog:)` over a `StdioTransport` built on the accepted file descriptor.
- [ ] The bridge copies stdin to the socket and the socket to stdout. It never opens `chat.db`, Contacts, or Messages itself.
- [ ] When the helper is not running, the bridge answers `initialize` with an error that names the app and how to start it.

**You see.**

- [ ] Claude Desktop shows iMessage Max as an installed extension, and `diagnose` reports `database.accessible` true with no Full Disk Access grant for Claude.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Add `StdioBridgeTests` that run a bridge against an in-process socket listener and complete `initialize`, `tools/list`, and `tools/call diagnose`. Run `cd swift && CI=true swift test --filter 'iMessageMaxTests.StdioBridgeTests/'`.
- [ ] Add `SocketListenerTests` for mode 0600 and for two concurrent clients. Run the same way.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `inherit-parent` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Pipe `initialize` and `tools/list` into trunk's stdio binary and head's bridge. Save `stdio-compare.png`. Pass when both list the same thirteen tools.
- [ ] Lane 2. Install the `.mcpb` in Claude Desktop in the test account. Save `claude-desktop.png`. Pass when the extension installs with no path prompt.
- [ ] Lane 3. Ask Claude Desktop to list recent chats. Save `claude-list.png`. Pass when it returns chats and Claude has no Full Disk Access entry.
- [ ] Lane 4. Stop the helper, then start the bridge. Save `helper-down.png`. Pass when the client shows the error that names the app.
- [ ] Lane 5. Read the socket file mode. Save `socket-mode.png`. Pass when it is `srw-------`.
- [ ] Lane 6. Connect to the socket from a second user account. Save `socket-other-user.png`. Pass when the connection is refused.
- [ ] Lane 7. Run two bridge clients at once and call `search` from both. Save `two-clients.png`. Pass when both get results.
- [ ] Lane 8. Cancel a long `search` from the client. Save `cancel.png`. Pass when the call line logs `outcome=cancelled`.
- [ ] Lane 9. Run Codex with the `.mcp.json` command. Save `codex-stdio.png`. Pass when Codex lists the tools.
- [ ] Lane 10. Run `--direct` from Terminal. Save `direct.png`. Pass when it serves in process as before.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. `tools/call get_active_conversations` round trip through trunk's in-process stdio and through head's bridge.
- [ ] Probe. Twenty calls alternating trunk and head after three warm-up calls each, timed at the client side of the pipe.
- [ ] Baseline. Record the trunk median first.
- [ ] Rule. Fail when the head median exceeds the trunk median by more than 5 milliseconds.

**Review gate.** None. P5 is not review-gated.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner merges its own PR.

## Connect AI clients in one click (P6)

**Depends on.** P4 and P5.

**Files.**

- [ ] Create `macos/Sources/MaxCore/ClientConnector.swift` with one entry per client.
- [ ] Edit `macos/Sources/iMessageMaxMenu/DetailViews.swift` and `AppModel.swift` to replace the Copy setup menu with a list of detected clients.
- [ ] Create `macos/Tests/MaxCoreTests/ClientConnectorTests.swift`.

**Build.**

- [ ] Model each client as a table row with its detection rule, its connect action, and its connected check.
  - [ ] Claude Desktop opens the bundled `.mcpb`.
  - [ ] Claude Code runs `claude mcp add --transport http imessage <url> --header "Authorization: Bearer <token>"`.
  - [ ] Codex writes an `[mcp_servers.imessage]` table with `url` and `http_headers` to `~/.codex/config.toml`.
  - [ ] Plug writes `auth_token` and the new URL into Plug's `[servers.imessage]` table.
  - [ ] Cursor opens its `mcp/install` deeplink with the URL and header.
- [ ] Show only clients the app detects on this Mac. Each row shows Connect or Connected.
- [ ] Every file write backs up the original next to it, edits only the iMessage entry, and shows what it changed.

**You see.**

- [ ] The Connection page lists each detected client with one Connect button, and the row turns to Connected after the click.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Add `ClientConnectorTests` for each writer against fixture config files, covering a missing file, an existing entry, and unrelated entries left byte-identical. Run `cd macos && swift test --filter ClientConnectorTests`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `inherit-parent` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Connect Codex on trunk by copy and paste and on head by one click. Save `codex-connect.png`. Pass when head needs one click and Codex lists the tools in both.
- [ ] Lane 2. Connect Claude Desktop. Save `claude-desktop-connect.png`. Pass when the extension installs and lists chats.
- [ ] Lane 3. Connect Claude Code. Save `claude-code-connect.png`. Pass when `claude mcp list` shows `imessage` as connected.
- [ ] Lane 4. Connect Plug in the test account. Save `plug-connect.png`. Pass when `plug status` shows the iMessage server healthy.
- [ ] Lane 5. Connect Cursor. Save `cursor-connect.png`. Pass when Cursor's MCP settings show iMessage with its tools.
- [ ] Lane 6. Open the page on an account with no clients installed. Save `no-clients.png`. Pass when the page explains how to connect any MCP client and offers Copy address.
- [ ] Lane 7. Connect Codex when its config already has other servers. Save `codex-preserve.png`. Pass when every other table is byte-identical and a backup exists.
- [ ] Lane 8. Click Connect twice for the same client. Save `idempotent.png`. Pass when the config holds one entry.
- [ ] Lane 9. Make the Codex config read-only and click Connect. Save `write-fail.png`. Pass when the row shows a clear error and the file is unchanged.
- [ ] Lane 10. Navigate the page with VoiceOver and the keyboard. Save `voiceover.png`. Pass when every row and button is reachable and labeled.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. User actions and seconds to connect Codex, at trunk with copy and paste and at head with one click.
- [ ] Probe. Three timed connections each on trunk and head in the test account, interleaved, counting clicks and keystrokes.
- [ ] Baseline. Record the trunk action count and median time first.
- [ ] Rule. Fail when head needs more than one action, or its write and recheck take longer than 2 seconds.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane 1, 2, 6, and 7 screenshots into `docs/design/087/p6-review-<slug>.png`.
- [ ] Record a 30 to 60 second video connecting Claude Desktop and Codex. Save it as `docs/design/087/p6-review.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at merge-ready. Wait for the operator's click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner merges its own PR after Rob approves in chat.

## Rewrite onboarding for someone who never opens Terminal (P7)

**Depends on.** P3 and P6.

**Files.**

- [ ] Edit `macos/Sources/iMessageMaxMenu/PanelState.swift`, `DetailViews.swift`, and `PanelView.swift` for one first-run sequence.
- [ ] Edit `swift/Sources/iMessageMax/Tools/Diagnose.swift` so every fix string names a step in the app, not a terminal command.
- [ ] Delete `swift/Sources/iMessageMax/Contacts/ResponsibilityDisclaim.swift` and the `--request-contacts-access` and `--request-messages-access` flags if the P3 prototype showed the app's agent is the responsible process.
- [ ] Edit `macos/Tests/CompanionTests/PanelStateTests.swift` for the new steps.

**Build.**

- [ ] Model first run as one ordered list of steps, each with its done check from `diagnose`. The steps are allow in the background, read messages, show names, send messages, connect an assistant, and try it.
- [ ] The try-it step shows a sample prompt the user can paste into their assistant and turns green when the helper logs a `tools/call`.
- [ ] Every fix string in `diagnose` points at the app's panel, for example "Open iMessage Max and choose Read messages".

**You see.**

- [ ] On a fresh account, opening the app shows step one, and finishing every step ends on the ready state with a green try-it step.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Extend `PanelStateTests` for each step and its done check. Run `cd macos && swift test --filter PanelStateTests`.
- [ ] Extend `DiagnoseToolTests` so no fix string contains `make`, `swift build`, or `Terminal`. Run `cd swift && CI=true swift test --filter 'iMessageMaxTests.DiagnoseToolTests/'`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `inherit-parent` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Run the full first run on trunk and head in fresh accounts. Save `first-run.png`. Pass when head needs no terminal command and reaches ready.
- [ ] Lane 2. Deny Contacts at the prompt. Save `contacts-denied.png`. Pass when the step explains the switch to turn on and opens the right pane.
- [ ] Lane 3. Skip connecting an assistant. Save `skip-connect.png`. Pass when the app reaches ready and keeps the connect step one click away.
- [ ] Lane 4. Close and reopen the app halfway through. Save `resume.png`. Pass when it resumes at the first unfinished step.
- [ ] Lane 5. Revoke Full Disk Access after setup. Save `revoked.png`. Pass when the panel returns to the read messages step within one check.
- [ ] Lane 6. Use Dark Mode and Reduce Motion. Save `appearance.png`. Pass when every step renders with correct contrast and no animation.
- [ ] Lane 7. Navigate first run with VoiceOver only. Save `voiceover-first-run.png`. Pass when every step can be completed.
- [ ] Lane 8. Read the `diagnose` output through an assistant with Full Disk Access missing. Save `diagnose-fix.png`. Pass when the fix names the app step, not a command.
- [ ] Lane 9. Complete the try-it step with a connected assistant. Save `try-it.png`. Pass when the step turns green after the assistant's first call.
- [ ] Lane 10. Run first run on macOS 15 in the test VM. Save `macos15-first-run.png`. Pass when it reaches ready.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. User actions and machine seconds from first launch to ready, excluding time spent reading prompts, at trunk and head.
- [ ] Probe. Three first runs each on trunk and head in fresh accounts, interleaved, counting clicks, terminal commands, and machine wait.
- [ ] Baseline. Record trunk's action count, terminal command count, and machine wait first.
- [ ] Rule. Fail when head needs any terminal command, more than 12 clicks, or more than 10 seconds of machine wait.

**Review gate.** The operator reviews before merge.

- [ ] Copy lane 1, 2, 5, and 9 screenshots into `docs/design/087/p7-review-<slug>.png`.
- [ ] Record a 30 to 60 second video of the whole first run on a fresh account. Save it as `docs/design/087/p7-review.mp4`.
- [ ] Post the screenshots and the video in chat. Stop at merge-ready. Wait for the operator's click.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner merges its own PR after Rob approves in chat.

## Ship 2.0 through a cask and retire the formula (P8)

**Depends on.** P2 and P7.

**Files.**

- [ ] Edit `.github/workflows/release.yml` to generate `Casks/imessage-max.rb`, push it to `cyberpapiii/homebrew-tap`, and stop building the tarball.
- [ ] Delete `swift/Formula/imessage-max.rb`, its checks in `scripts/check-version.sh`, `VersionConsistencyTests`, and the `ruby -c` line in `swift/Makefile`.
- [ ] Edit `README.md`, `swift/README.md`, `macos/README.md`, and `docs/RELEASING.md` so the DMG and `brew install --cask imessage-max` are the only install paths.
- [ ] Edit the tap's `imessage-max.rb` formula with a `disable!` message that points at the cask.
- [ ] Edit `swift/Sources/iMessageMax/Server/Version.swift` and the version sites to 2.0.0, and add the 2.0.0 entry to `CHANGELOG.md`.

**Build.**

- [ ] Base the cask on the tap's `Casks/plug-app.rb`, with `depends_on arch: :arm64`, `depends_on macos: ">= :sequoia"`, `uninstall launchctl:` for the new label, and `zap trash:` for the token, socket, logs, and Application Support folder.
- [ ] Tag v2.0.0 only after the dry run passes on a clean account.

**You see.**

- [ ] `brew install --cask cyberpapiii/tap/imessage-max` installs the app, and the README's install section is two lines long.

**Verify, unit.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Run `brew style --fix` and `brew audit --cask` on the generated cask in CI. Run `scripts/check-version.sh` and `VersionConsistencyTests`.

**Verify, live.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked. Ten lanes on `inherit-parent` at the PR head, per the boot recipe.

- [ ] Lane 1. Regression lane against trunk. Install v1.8.0 with the formula, then the head build with the cask. Save `brew-install.png`. Pass when the cask install reaches ready through first run.
- [ ] Lane 2. Run `brew upgrade --cask` from a head build to a newer head build. Save `brew-upgrade.png`. Pass when every grant survives and the helper restarts on the new version.
- [ ] Lane 3. Run `brew uninstall --zap --cask imessage-max`. Save `zap.png`. Pass when the helper, token, socket, logs, and Login Items entry are gone.
- [ ] Lane 4. Run `brew install imessage-max` against the tap after the formula is disabled. Save `formula-disabled.png`. Pass when Homebrew prints the message that points at the cask.
- [ ] Lane 5. Install from the DMG on a clean macOS 15 account. Save `dmg-clean.png`. Pass when first run reaches ready.
- [ ] Lane 6. Migrate Rob's own Mac from v1.8.0, with Rob's consent and his eyes on it. Save `rob-migration.png`. Pass when Plug, Codex, and Claude Code reconnect through P6 and `diagnose` is ready.
- [ ] Lane 7. Follow the README install section exactly, word for word. Save `readme-follow.png`. Pass when it reaches ready with no other step.
- [ ] Lane 8. Open the GitHub release page. Save `release-page.png`. Pass when it lists the DMG and the `.mcpb` and no tarball.
- [ ] Lane 9. Run the release workflow on a test tag in a fork. Save `release-fork.png`. Pass when it pushes a cask that passes `brew audit`.
- [ ] Lane 10. Search the repo for `Cellar`, `setup-signing`, `install-agent`, and `local.imessage-max`. Save `grep-clean.png`. Pass when only `CHANGELOG.md` and dated plans mention them.

**Verify, perf.** Tests alone are not sufficient verification. A PR is verified only when its unit, live, and perf boxes are all checked.

- [ ] Metric. Machine seconds from `brew install` start to the app's first run screen, at trunk with the formula and head with the cask.
- [ ] Probe. Three installs each on trunk and head in fresh accounts, interleaved, timed with `time brew install`.
- [ ] Baseline. Record the trunk median first.
- [ ] Rule. Fail when the head median exceeds 120 seconds, or exceeds trunk by more than 60 seconds.

**Review gate.** None. P8 is not review-gated, because P7 already reviewed the interaction.

**Merge.**

- [ ] Root's clean verdict at the exact head SHA.
- [ ] Bugbot triage done.
- [ ] Rebased onto current trunk after the verdict, patch-id unchanged.
- [ ] The owner merges its own PR, then pushes the v2.0.0 tag after lane 5 passes.

## Close the program

- [ ] Every box above is checked with its evidence.
- [ ] Reply to the operator with the report the execution playbook names.
- [ ] Update `plans/README.md` with this plan's status row.

## Appendix A. Prototype evidence

No prototype ran before this plan. The facts below come from reading code and docs on 2026-11-06.

- Rob already has two `Developer ID Application (HJF7LN64XX)` certificates in his keychain, and Plug's release workflow signs, notarizes, staples, and publishes a DMG and a cask on the same `macos-26` runner. Plug's `scripts/sign-notarize-macos-app.sh` is the template for P2.
- Plug sends a bearer token to HTTP servers through `auth_token` (`plug-core/src/config/mod.rs:400`). Plug has no Unix socket transport.
- Codex accepts `http_headers`, `env_http_headers`, and `bearer_token_env_var`, and rejects an inline `bearer_token`. This was read from the 0.167.0 binary's strings.
- Claude Code accepts `headers` and `headersHelper` for HTTP servers. Claude Desktop runs `.mcpb` bundles over stdio only and can ship a binary through `${__dirname}`.
- The CI-built v1.8.0 helper links `libswiftCompatibilitySpan.dylib` weakly. A local Xcode 27 build links it strongly.

These questions stay unproven, and the PR named settles each one.

- Which name macOS shows in Full Disk Access, Contacts, and Automation for a helper registered with `SMAppService.agent` from inside the app. P3's prototype gate settles it with one grant from Rob.
- Whether Cursor's `mcp.json` accepts `headers` on a `url` entry. P6 lane 5 settles it.
- Whether a cask and a disabled formula with the same name in one tap leave `brew install imessage-max` clear. P8 lane 4 settles it.
- Whether a grant survives a Developer ID signed helper being replaced by an update. P3 lane 7 and P8 lane 2 settle it.

## Appendix B. Alternatives rejected

- The Mac App Store. Its sandbox rules out reading `chat.db` with Full Disk Access and driving Messages through Apple Events.
- Keeping the formula next to the cask. Two install models keep two permission identities alive, which is the problem this program removes.
- Storing the token in the Keychain. The helper and the app would need a shared access group, and every client config already holds the token in plain text. A 0600 file gives the same protection against other users with less code.
- A Unix socket for every client. Plug has no socket transport, so HTTP with a token stays.
- An HTTP-only stdio bridge. It would re-implement a streamable HTTP client, sessions, and SSE. A socket bridge copies bytes.
- Sparkle auto-update in 2.0. It needs signing keys and a hosted appcast. Cask users get `brew upgrade` now, and Sparkle can follow 2.0.
- A universal binary in 2.0. Intel testing has no hardware here, and the current release is arm64 only.

## Appendix C. Risks

- macOS may charge permissions to the helper, not the app (P3). The prototype gate decides the Full Disk Access step before any UI work.
- Live lanes need human permission clicks and a separate macOS account or VM (all PRs). `cua-driver` drives the UI, and a lane that needs a click asks Rob and records it.
- No lane may send a real iMessage (all PRs). Send checks use paths that send nothing.
- Existing clients break when P4 lands (P4 to P6). No release ships in between, and Rob's live service stays on v1.8.0 until P8 lane 6.
- The two Developer ID certificates share a name (P1, P2). Sign by SHA-1 hash.
- Hardened runtime without the right entitlements silently blocks Contacts or Apple Events (P1). Lanes 4 and 5 catch it.
- A move to Xcode 27 on CI could make the helper fail to launch on macOS 15 (P2). Lane 10 checks the dylib link.
- The app name contains Apple's trademark "iMessage" (P8). Notarization does not check names, but Apple can object later. Rob owns this call.

## Appendix D. Links and reading list

- `AGENTS.md`, for build, test, and signing rules.
- `macos/README.md`, for the companion's current setup flow.
- Plug's `scripts/sign-notarize-macos-app.sh` and the tap's `Casks/plug-app.rb`, for P2 and P8.
- Apple's `SMAppService` documentation, for P3.
- `mcpb/README.md`, for P5.
- P3 and P4 run `pstack/skills/how/SKILL.md` before code and `pstack/skills/interrogate/SKILL.md` before merge.
- The decision trail follows `pstack/skills/show-me-your-work/SKILL.md` and lives in `docs/design/087/trail.md`.
