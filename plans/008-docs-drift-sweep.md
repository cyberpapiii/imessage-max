# Plan 008: Fix documentation drift (SDK version, tool count, protocol version)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 57a2ff3..HEAD -- README.md AGENTS.md swift/README.md`
> If any in-scope file changed since this plan was written, re-verify each
> claimed inaccuracy still exists before editing (the line numbers below may
> shift; the *strings* are the anchor).

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: docs
- **Planned at**: commit `57a2ff3`, 2026-06-11

## Why this matters

AGENTS.md is declared the repo's source of truth (CLAUDE.md defers to it), and coding agents read it before every task — stale facts there propagate into wrong agent behavior. Three confirmed inaccuracies: the documented MCP SDK version is two minor versions behind the resolved one, the README headline undercounts the tools, and the swift/README stdio example pins an MCP protocol version the project has moved past (the repo recently completed a "2025-11-25 modernization").

## Current state

Confirmed inaccuracies (verify each string still exists before editing):

1. `AGENTS.md:66`:
   ```
   - **MCP SDK:** modelcontextprotocol/swift-sdk v0.11.0
   ```
   Reality: `swift/Package.swift` requires `from: "0.12.0"`; `swift/Package.resolved` pins **0.12.1**.

2. `README.md:25`:
   ```
   - **11 Intent-Aligned Tools** - Work the way you naturally ask questions, not raw database queries
   ```
   Reality: there are **12** tools (count the table in `AGENTS.md` "Twelve Core Tools", or `grep -c '\.register(' swift/Sources/iMessageMax/Server/ToolRegistry.swift` minus the `registerToolHandlers` line).

3. `swift/README.md:163` (stdio testing example):
   ```
   echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05",...
   ```
   Reality: the HTTP example in the same file (line 132) and the integration tests use `2025-11-25`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Tool count ground truth | `grep -c 'register(on:' swift/Sources/iMessageMax/Server/ToolRegistry.swift` | 12 |
| Resolved SDK version | `grep -A2 'swift-sdk' swift/Package.resolved \| grep version` | "0.12.1" (or newer — use what you see) |
| Stale-string sweep | `grep -rn '0\.11\.0\|2024-11-05\|11 Intent' README.md AGENTS.md swift/README.md docs/ mcpb/ 2>/dev/null` | no matches when done (except inside docs/plans/ and docs/brainstorms/ history files — leave dated historical docs alone) |

## Scope

**In scope**:
- `AGENTS.md`, `README.md`, `swift/README.md`
- `mcpb/` docs ONLY if the sweep grep finds the same stale strings there
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- `docs/plans/`, `docs/brainstorms/`, `docs/maintainers/`, `docs/ideation/` — dated historical documents; stale facts in them are records, not bugs.
- `CLAUDE.md` — it's just a pointer to AGENTS.md, already correct.
- Any restructuring, rewording, or "while I'm here" doc improvements.

## Git workflow

- Branch: `advisor/008-docs-drift`
- Single commit; style: `docs: fix SDK version, tool count, and protocol version drift`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: AGENTS.md SDK version

Change the line to reference the manifest rather than re-pinning a number that will drift again:

```
- **MCP SDK:** modelcontextprotocol/swift-sdk (version pinned in `swift/Package.swift` / `swift/Package.resolved`)
```

**Verify**: `grep -n '0.11.0' AGENTS.md` → no matches.

### Step 2: README tool count

`README.md:25`: change `**11 Intent-Aligned Tools**` → `**12 Intent-Aligned Tools**`.

**Verify**: `grep -n '11 Intent' README.md` → no matches; `grep -n '12 Intent' README.md` → 1 match.

### Step 3: swift/README protocol version

Replace `"protocolVersion":"2024-11-05"` with `"protocolVersion":"2025-11-25"` in the stdio example.

**Verify**: `grep -n '2024-11-05' swift/README.md` → no matches.

### Step 4: Sweep for further instances

Run the stale-string sweep from the commands table over `README.md AGENTS.md swift/README.md mcpb/`. Fix any hits in those files the same way. Leave `docs/` history files alone.

**Verify**: sweep grep over the in-scope files → no matches.

## Test plan

Docs only — no test changes. Run `cd swift && swift test` once anyway to prove the working tree is untouched functionally.

## Done criteria

- [ ] All four step verifications pass
- [ ] `cd swift && swift test` exits 0 (nothing functional touched)
- [ ] `git status` shows only the in-scope docs modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any of the three strings is already fixed (someone beat you to it — re-verify the rest, fix what remains, and note it).
- The tool-count ground-truth command does not return 12 (the tool surface changed; recount and use reality, and flag that AGENTS.md's "Twelve Core Tools" section needs the same update — updating that section's table rows is in scope in that case).

## Maintenance notes

- AGENTS.md now points at Package.swift for the SDK version instead of duplicating it — keep it that way; duplicate version strings were the root cause here.
- The "N Intent-Aligned Tools" headline will drift again when a 13th tool lands; whoever adds a tool should grep for `Intent-Aligned Tools`.
