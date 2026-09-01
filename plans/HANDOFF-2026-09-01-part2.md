# Handoff prompt: finish plans 048, 053, 054, 055 and the round's open findings

Repository: `/Users/robdezendorf/Documents/GitHub/imessage-max` (Swift 6 MCP server for iMessage).
Read `AGENTS.md`, then `plans/HANDOFF-2026-09-01.md`, then the "Current round (2026-09-01)" section of
`plans/README.md`, then each plan you execute, fully, before touching code.

## Where things stand

- `main` is `e320a49`. `cd swift && swift test` on `main`: `Executed 347 tests, with 0 failures`.
- Twelve plans are merged (040, 041, 042, 043, 044, 045, 046, 047, 049, 050, 051, 052).
- Four remain: 048 and 054 stopped mid-plan; 053 and 055 never started because they depend on 048.
- Nothing has been pushed and no PRs exist. Keep it that way. `plans/` is still untracked in the main checkout.
- Worktrees left under `.claude/worktrees/`: `048-deps-and-floor` (branch `advisor/048-deps-and-floor`
  at `5ab59df`, dirty `swift/Package.swift` and `swift/Package.resolved`) and `054-consolidate-internals`
  (branch `advisor/054-consolidate-internals`, commit `a5a5e60` for Step 1, Step 2 uncommitted in eight
  source files).

## Ground rules (same as before, with two explicit exceptions below)

1. Drift check before each plan. Drift from merged plans is expected; anything that contradicts a plan's
   "Current state" excerpt for the code you are about to edit is a STOP.
2. Scope and STOP conditions are literal, except where this prompt explicitly overrides them.
3. Never `Task.sleep` in `swift/Sources`. Never commit secrets. Never modify `.mcp.json`.
4. Verification for every plan: `cd swift && swift build && swift test` with 0 failures from the worktree
   root, plus every "Verify" and "Done criteria" command in the plan.
5. One branch per plan, cut from current `main`; conventional commits as the plan specifies; merge into
   `main` with `git merge --no-ff`; re-run the full suite on `main` after each merge; update the plan's
   row in `plans/README.md` to `DONE 2026-09-01, merged to main (<sha>, branch <name>; <passed>/<failures>
   re-verified)`.
6. Worktrees created by the harness have been cut from stale commits before. Run
   `git log --oneline -1 main` first and branch from `main`.
7. Do not push and do not open PRs.

## Part A: unblock 048 (dependency bump, macOS 15 floor, tools-version 6.3, `main.swift` rename, `Mutex`)

The previous team stopped because `swift package update` exited 1 with:

```
error: Disabled default traits on package 'swift-async-algorithms' (swift-async-algorithms) that declares no traits.
```

That diagnostic is emitted after the lockfile is written, and it is not a resolution failure. Verified on
the existing `048-deps-and-floor` worktree: `swift package resolve` exits 0 and `swift build` prints
`Build complete!` with the updated pins (hummingbird 2.26.0, swift-nio 2.102.0, swift-log 1.15.0,
swift-argument-parser 1.8.2, async-http-client 1.36.1, swift-collections 1.6.0, swift-sdk 0.12.1). The
trait mismatch comes from hummingbird 2.26.0 depending on `swift-configuration` with `traits: []`; it does
not affect this package.

**Override of the plan's Step 2 STOP**: treat the `swift package update` diagnostic as informational.
The gate for Step 2 is `swift package resolve` exit 0 followed by `swift build` and `swift test` passing.
Record the diagnostic verbatim in the Step 2 commit body so the next person does not re-investigate it.

Do this:

1. Rebase or recreate `advisor/048-deps-and-floor` on current `main` (`e320a49`). The dirty
   `Package.swift`/`Package.resolved` in the worktree are the plan's Step 1-2 output; carry them over.
2. Continue from Step 3 of the plan: tools-version 6.3, `.macOS(.v15)`, `git mv main.swift
   iMessageMaxCommand.swift` with the `unsafeFlags` removal, `Synchronization.Mutex` at the four sites the
   plan lists (carry 044's fixed `ResumeGate` logic: `if !already, cont != nil`), conformance pin
   `@0.2.0-alpha.11`, docs to macOS 15, Formula `:sonoma` to `:sequoia`.
3. Every commit the plan lists, in order, each followed by build and test. Merge, re-verify on `main`,
   update the README row.

If `swift package resolve` itself exits non-zero, or the build fails on the new pins with an error you
cannot attribute to a specific plan step, that is a real STOP: report the command and output.

## Part B: unblock 054 (consolidate duplicated tool internals)

Step 2 stopped because routing every participant query through `ChatSummaryQueries.participantsByChat`
(which selects `h.service`) breaks `SendResolverTests.testResolveChatIdReturnsExactChatTarget`: the
fixture in `swift/Tests/iMessageMaxTests/SendResolverTests.swift:172` creates
`handle (ROWID INTEGER PRIMARY KEY, id TEXT)` without a `service` column, and SQLite reports
`no such column: h.service`.

**Override of the plan's "no pre-existing test edits" STOP, narrowly**: you may change the schema string
in `makeResolverTestDatabase()` to add `service TEXT` to the `handle` table (the real chat.db has it and
`ToolTestSupport` already declares it). No assertion, expected value, or test name may change. If any
other pre-existing test needs any other edit to pass, that remains a STOP.

Do this:

1. Rebase `advisor/054-consolidate-internals` (commit `a5a5e60` plus the uncommitted Step 2 edits in the
   worktree) onto current `main`. If the uncommitted edits do not rebase cleanly, discard them and redo
   Step 2 from the plan; Step 1 is committed and sound.
2. Apply the fixture column, finish Step 2, then Steps 3-5 (`ToolErrorMapping.map` with no `default`,
   `TimelineCursor` for every message cursor with byte-identical formats per `CursorCodecTests`,
   `UnansweredHeuristics` with the guard-order fix). One commit per step as the plan specifies.
3. The plan requires the diff to be net-negative in lines. Report `git diff --shortstat main..HEAD`.
4. Merge last, after 048, 053, and 055, because it consolidates code they touch.

## Part C: 053 and 055, after 048 merges

Run them in parallel worktrees, merge one at a time.

- **053** (`Log` helper, honest Makefile `verify`, shipped launchd plist, docs drift). Before writing the
  plist template, run `launchctl list | grep imessage` and match the live label. 052 already added
  `docs/RELEASING.md` and a `release-check` target to the Makefile; do not duplicate them, and preserve
  052's `grep -o '[0-9.]*$'` in the `verify` target when you restructure it.
- **055** (word-boundary contact search, pinned date formatter, transport before contacts enumeration).
  Edits `iMessageMaxCommand.swift`, the file 048 renames; 051's `send`-by-name batching is already on
  `main`.

## Part D: the round's open findings, as one follow-up branch

Branch `advisor/056-round-followups`, cut from `main` after Part C merges and before 054. One commit per
item, conventional messages, tests for every behaviour change. Skip an item only if its change would
touch a file 054's uncommitted diff also touches; list any skipped item in the report.

1. **`swift/Tests/iMessageMaxTests/AsyncTimeoutTests.swift:18-26`.** The pre-arm cancellation test hangs
   forever if 044's bug regresses, because `withTaskGroup` waits for an un-cancellable child. Rewrite it
   to fail within 2 s: run the sleep in a detached `Task`, wait on an `XCTestExpectation` with
   `wait(for:timeout: 2)`, and assert. Verify by temporarily reverting `AsyncTimeout.swift:96` to
   `if !already {` and confirming the test fails (not hangs) in under 5 s; restore the fix.
   Commit: `test: bound the pre-arm cancellation test so a regression fails instead of hanging`.
2. **`swift/Sources/iMessageMax/Tools/SendResolution.swift:97-110`.** After 043, `isPhoneNumber` accepts
   5-8 digit short codes, so a bare `to` like `"55555"` enters `resolvePhoneNumber`, `normalizeToE164`
   returns nil, and the user gets `Invalid phone number format` instead of the contact-name lookup that
   ran before. Restore the fallthrough: when `normalizeToE164` returns nil and `to` does not start with
   `+`, continue to `resolveContactName(to)`. Add a `SendResolverTests` case for a 5-digit `to` that
   matches nothing and asserts the "no contact found" style result, and one for a contact whose display
   name is digits-only if the fixture allows it.
   Commit: `fix: fall back to contact lookup when a short numeric destination is not a phone number`.
3. **`swift/Sources/iMessageMax/Utilities/IdentityDisplayFormatter.swift:39-47`.** `disambiguatedNames`
   counts a duplicated handle twice and renders "Alice Smith (0001)" against herself. Dedupe participants
   by handle (first occurrence wins) at the top of the formatter's entry point so every caller is covered
   regardless of whether its query has `DISTINCT`. Add a test in `ChatSummaryQueriesTests` (the
   `makeIdentityFromRawJoinRows` helper at `:130` builds the duplicated input) asserting the small-chat
   name has no `(0001)` suffix. Coordinate with 054: if 054's Step 2 routes every site through
   `participantsByChat`, keep this dedupe anyway as defence in depth; it is three lines.
   Commit: `fix: dedupe handles before disambiguating display names`.
4. **`swift/Sources/iMessageMax/Tools/Search.swift` (clamp inside `registerTool`).** 042's
   `unanswered_hours` clamp lives in the registration closure, so callers of the static
   `SearchTool.execute` bypass it. Move the clamp into the static `execute` (keep the closure passing the
   raw value) and add one `ArgumentClampTests` case that calls the static function directly with
   `unanswered_hours: Int.max`. Do the same check for `GetMessages.swift:223`; if its clamp is also
   closure-only, move it too.
   Commit: `fix: clamp unanswered_hours in the static execute so every caller is covered`.
5. **`swift/Sources/iMessageMax/Tools/SearchInternals.swift:133`.** The constant `m.text LIKE ?` with
   `%http%` has no `ESCAPE`. Add `ESCAPE '\'` for consistency so a future "every LIKE has ESCAPE" grep
   passes with no allowlist. No behaviour change; existing link-search tests cover it.
   Commit: `refactor: give the constant link LIKE an ESCAPE clause for consistency`.
6. **`QueryBuilder.where` is variadic-only.** 045 bound its search terms with a `switch` over
   `terms.prefix(8)` because there is no array overload. Add `where(_ clause: String, params: [Any])`
   (or whatever name matches the file's convention) next to the variadic one, make the variadic one
   forward to it, and replace 045's `switch` in `SearchInternals.buildQuery` with a loop. `SearchRecallTests`
   and `SearchToolTests` are the oracle; the generated SQL must be identical (add an assertion on the SQL
   string if a test already exposes it).
   Commit: `refactor: add an array-params overload to QueryBuilder.where and use it for search terms`.
7. **`swift/Sources/iMessageMax/Tools/FindChat.swift` `contains_recent`.** With 045's disjunct
   `(m.text IS NULL AND m.attributedBody IS NOT NULL)`, a chat whose recent 200 rows are all
   attributedBody-only can still push an older text match out of the LIMIT. Raise the per-chat bound to
   500 only when the prefilter's row count hits the limit, or document the bound in the tool description.
   Choose the documentation route unless the extra query is trivial; either way add one line to the
   `contains_recent` parameter description saying it scans the most recent N rows.
   Commit: `docs: state the contains_recent scan bound in the tool description` (or `fix:` if you raised it).
8. **`.github/workflows/build.yml:47`.** 052's version check runs before the build. That is deliberate
   (fail fast). Add a one-line YAML comment above the step saying so. No commit needed if you fold it into
   another docs commit.

Merge `advisor/056-round-followups` into `main`, re-verify, then add a row for 056 to the README table:
`| 056 | Round follow-ups: bounded gate test, short-code send fallback, formatter dedupe, static clamps, LIKE ESCAPE, QueryBuilder array params, contains_recent bound | P3 | S | 048, 053, 055 | DONE ... |`.

## Part E: cleanup and close

1. Merge 054 last (Part B), re-verify on `main`.
2. Remove every worktree under `.claude/worktrees/` whose branch is merged (`git worktree remove <path>`),
   then delete those branches (`git branch -d advisor/0NN-...`). Leave nothing dirty.
3. Commit `plans/` on `main` as one commit: `docs: record the 2026-09-01 plans round and its execution`
   (the sixteen plan files, both handoff files, and the updated `plans/README.md`). Plans 001-039 are
   already tracked, so this matches the repo's convention.
4. Do not push. Tell me the branch is ready; I will push and watch CI (plan 040 Step 5, still unobserved).

## Final report

One message with:

1. The full sixteen-row table (plus 056) of plan, status, merge sha, and test count on `main` after that merge.
2. For any plan or follow-up item still BLOCKED: the condition that fired, verbatim command and output, and what is left on its branch.
3. `git diff --shortstat` for 054 (must be net-negative).
4. Any new finding no plan covered, with `file:line`.
5. The final `cd swift && swift test` summary line on `main`, and confirmation that `git worktree list` shows only the main checkout, `git status` is clean, and nothing was pushed.
