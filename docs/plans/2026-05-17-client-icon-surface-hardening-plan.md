---
title: "feat: client icon surface hardening"
type: feature
status: active
date: 2026-05-17
---

# Client Icon Surface Hardening Plan

## Problem Frame

iMessage Max already emits MCP `serverInfo.icons` for the `2025-11-25` protocol path, and the current metadata is valid: a PNG data URI with `mimeType: "image/png"` and `sizes: ["64x64"]`. That covers the MCP-standard runtime surface, but current desktop clients do not all use the same icon source in visible UI.

The goal is to make iMessage Max icon support robust across the practical surfaces users are likely to see:

- MCP-standard clients that render `serverInfo.icons`
- future MCP clients that render tool/resource/prompt `icons`
- Codex plugin install surfaces, which use `.codex-plugin/plugin.json` `interface.composerIcon` and `interface.logo`
- Claude Desktop extension surfaces, which use MCPB/Desktop Extension `manifest.json` icon fields

## Scope

In scope:

- Generate committed PNG assets at common square sizes from the existing root `icon.png`.
- Prefer committed PNG assets for runtime MCP icon metadata instead of keeping a large embedded literal as the only source.
- Add a richer MCP icon array with PNG sizes clients commonly expect.
- Add per-tool MCP icons where the SDK/tool registration path can support it without destabilizing tool definitions.
- Add Codex plugin packaging metadata and assets for local/plugin-directory presentation.
- Add Claude Desktop MCPB/Desktop Extension manifest metadata and icon assets for extension/settings UI presentation.
- Add tests that verify file format, dimensions, manifest paths, and live initialize icon metadata.
- Document which icon surface each client is expected to use.

Out of scope:

- Publishing a Codex plugin marketplace entry.
- Publishing or signing a Claude Desktop `.mcpb` bundle.
- Replacing iMessage Max's launchd install path or MCP Router/Plug setup.
- Changing iMessage read, attachment, or send behavior.
- Relying on SVG-only icons for compatibility.

## Source References

- MCP `2025-11-25` icon metadata: `Implementation.icons`, `Tool.icons`, `Resource.icons`, `ResourceTemplate.icons`, and `Prompt.icons`.
- MCP icon compatibility requirement: clients that render icons must support PNG and JPEG, and should support SVG/WebP.
- Codex plugin docs: `.codex-plugin/plugin.json` `interface` metadata controls install-surface presentation, including `composerIcon`, `logo`, and `screenshots`.
- Claude Desktop local extension guidance: MCPB/Desktop Extension manifests expose their own `icon` and `icons` fields for extension UI.
- Existing repo modernization plan: `docs/plans/2026-05-16-mcp-2025-11-25-modernization-plan.md`.

## Key Decisions

1. **PNG is the canonical compatibility format.**
   Keep PNG first everywhere. SVG can be added later as an optional extra, but PNG should be the committed, tested baseline because MCP-compatible clients must support it.

2. **MCP metadata and desktop packaging are separate surfaces.**
   `serverInfo.icons` is correct for protocol clients, but Codex plugin cards and Claude Desktop extension settings have their own packaging manifests. The implementation should support all relevant surfaces rather than assuming one icon path feeds every UI.

3. **Use the existing 512x512 root icon as source of truth.**
   Generate smaller PNG assets from `icon.png` so README, MCP metadata, Codex plugin assets, and Claude extension assets stay visually consistent.

4. **Avoid client-specific runtime hacks.**
   Do not special-case Codex or Claude inside the MCP server. Runtime metadata stays spec-shaped; client-specific visibility comes from optional packaging files.

5. **Keep generated assets deterministic and testable.**
   Commit the generated PNGs and add tests for dimensions and manifest references so future icon changes cannot silently drift.

## Implementation Units

### Unit 1: Generate Shared PNG Icon Assets

Files:

- `icon.png`
- `assets/icons/icon-16.png`
- `assets/icons/icon-32.png`
- `assets/icons/icon-64.png`
- `assets/icons/icon-128.png`
- `assets/icons/icon-256.png`
- `assets/icons/icon-512.png`
- `swift/Tests/iMessageMaxTests/IconMetadataTests.swift`

Work:

- Create `assets/icons/` with `16x16`, `32x32`, `64x64`, `128x128`, `256x256`, and `512x512` PNG assets derived from the root icon.
- Preserve `icon.png` as the top-level README asset.
- Extend icon tests to verify all generated assets are valid PNGs and match their filename dimensions.

Test scenarios:

- Each generated PNG has a valid PNG signature.
- Each generated PNG's IHDR width/height matches its filename.
- `assets/icons/icon-512.png` matches the root source dimensions.

### Unit 2: Advertise Multi-Size MCP Server Icons

Files:

- `swift/Sources/iMessageMax/Server/IconMetadata.swift`
- `swift/Tests/iMessageMaxTests/IconMetadataTests.swift`
- `swift/Tests/iMessageMaxTests/HTTPTransportIntegrationTests.swift`

Work:

- Replace the single hardcoded `64x64` metadata entry with a small, deterministic multi-size PNG icon list.
- Prefer PNG data URIs for local stdio/HTTP compatibility because unsafe local `file:` URIs are rejected by the MCP icon security model.
- Keep `64x64` available for existing tests and clients.
- Add tests that decode each advertised icon and confirm the declared size matches the actual PNG dimensions.

Test scenarios:

- `IconMetadata.icons` contains PNG data URIs for all generated sizes.
- Every advertised `sizes` entry matches the decoded PNG dimensions.
- HTTP initialize for `2025-11-25` includes the same icon array.
- Legacy initialize responses still omit injected icon metadata as currently intended.

### Unit 3: Add Tool-Level Icon Support Where Safe

Files:

- `swift/Sources/iMessageMax/Server/ServerExtensions.swift`
- `swift/Sources/iMessageMax/Server/ToolRegistry.swift`
- `swift/Sources/iMessageMax/Tools/*.swift`
- `swift/Tests/iMessageMaxTests/HTTPTransportIntegrationTests.swift`

Work:

- Verify the current Swift MCP SDK `Tool` initializer supports top-level `icons`.
- If supported, plumb optional icons through the local `registerTool` helper.
- Add a default iMessage Max icon to action/tool definitions unless that creates noisy `tools/list` output or compatibility risk.
- Keep this unit minimal; do not redesign tool descriptions or output schemas.

Test scenarios:

- `tools/list` still includes all expected tools.
- Tools with icon metadata use valid PNG data URIs and declared sizes.
- Existing tool annotations remain unchanged.

### Unit 4: Add Codex Plugin Packaging Metadata

Files:

- `.codex-plugin/plugin.json`
- `.mcp.json`
- `assets/codex/icon.png`
- `assets/codex/logo.png`
- `README.md`
- `swift/Tests/iMessageMaxTests/IconMetadataTests.swift`

Work:

- Add a Codex plugin manifest that describes iMessage Max and points `mcpServers` to a repo-local `.mcp.json`.
- Include `interface.composerIcon` and `interface.logo` using PNG assets.
- Use a `360x360` composer icon and `512x512` logo to match observed Codex first-party plugin asset patterns.
- Keep paths relative and under `./assets/`.
- Do not create or update a user marketplace entry unless explicitly requested later.

Test scenarios:

- `.codex-plugin/plugin.json` parses as JSON.
- `interface.composerIcon` and `interface.logo` point to existing PNG files.
- Codex icon assets have expected dimensions.
- `.mcp.json` points at a valid local server command or documents the intended command shape without breaking current repo usage.

### Unit 5: Add Claude Desktop MCPB Manifest Skeleton

Files:

- `mcpb/manifest.json`
- `mcpb/assets/icon-16.png`
- `mcpb/assets/icon-32.png`
- `mcpb/assets/icon-64.png`
- `mcpb/assets/icon-128.png`
- `mcpb/assets/icon-256.png`
- `mcpb/assets/icon-512.png`
- `README.md`
- `docs/validation/2026-04-09-release-checklist.md`
- `swift/Tests/iMessageMaxTests/IconMetadataTests.swift`

Work:

- Add a Claude Desktop/Desktop Extension manifest skeleton with `icon` and `icons` fields backed by PNG assets.
- Keep it as packaging metadata, not the default install path, unless the repo already has an MCPB packaging command.
- Document that the manifest is for future `.mcpb` packaging and visible Claude extension UI, while runtime local MCP can continue using launchd/Plug.

Test scenarios:

- `mcpb/manifest.json` parses as JSON.
- Manifest `icon` points to a PNG file.
- Manifest `icons` entries point to existing PNG files with matching declared sizes.

### Unit 6: Documentation And Validation

Files:

- `README.md`
- `swift/README.md`
- `docs/validation/2026-04-09-release-checklist.md`
- `using-imessage-max/SKILL.md`

Work:

- Document the three icon surfaces:
  - MCP runtime metadata
  - Codex plugin metadata
  - Claude Desktop MCPB/Desktop Extension metadata
- Document that visible client icon behavior is client-dependent and not guaranteed by the MCP protocol alone.
- Add validation commands for:
  - focused icon tests,
  - full Swift tests,
  - live HTTP initialize icon metadata,
  - optional Codex plugin manifest inspection,
  - optional Claude MCPB manifest inspection.

Test scenarios:

- Docs mention PNG as the canonical committed compatibility asset.
- Validation checklist includes icon format/dimension checks.
- Existing install/send/read guidance remains intact.

## Risks And Mitigations

- **Client UI behavior may change or remain undocumented.**
  Mitigation: implement standard MCP metadata and separate packaging manifests instead of relying on one client-specific behavior.

- **Committed image assets can drift from the source icon.**
  Mitigation: add dimension/format tests and keep generation documented.

- **MCP tool icons may increase `tools/list` payload size.**
  Mitigation: use compact `16x16` or `32x32` data URIs for tool icons, or skip tool icons if payload impact is too high.

- **Plugin/MCPB metadata may imply install support that is not fully packaged yet.**
  Mitigation: label package manifests as local/skeleton metadata unless full publishing/bundling is added.

- **Dirty worktree risk.**
  Mitigation: keep changes scoped to icon assets, icon metadata, packaging manifests, docs, and tests. Do not touch unrelated untracked ideation work.

## Verification Plan

- `cd swift && swift test --filter IconMetadataTests`
- `cd swift && swift test`
- Live HTTP initialize check for `2025-11-25` icon metadata against `127.0.0.1:8080`
- JSON parse checks for `.codex-plugin/plugin.json`, `.mcp.json`, and `mcpb/manifest.json`
- PNG dimension checks for `assets/icons/`, `assets/codex/`, and `mcpb/assets/`
- Optional: inspect Codex plugin directory behavior after adding a marketplace entry in a separate follow-up
- Optional: package and install Claude MCPB extension in a separate follow-up
