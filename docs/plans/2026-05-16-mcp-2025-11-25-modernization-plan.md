---
title: "feat: MCP 2025-11-25 modernization"
type: feature
status: completed
date: 2026-05-16
---

# MCP 2025-11-25 Modernization Plan

## Problem Frame

iMessage Max already speaks Streamable HTTP and can negotiate `2025-11-25`, but its compatibility layer is still partly shaped around the older `2025-03-26` baseline. The latest stable MCP spec and Swift SDK expose newer affordances that are useful for this project: stricter HTTP transport rules, richer tool metadata, structured tool output, server instructions, and elicitation for user-reviewed workflows.

The goal is to bring the server up to the latest stable MCP behavior without changing the product identity: a local, private, intent-aligned iMessage MCP server optimized for agent consumption through Plug and direct local MCP clients.

## Scope

In scope:
- Update the Swift SDK lockfile to the latest compatible patch release.
- Tighten Streamable HTTP request validation for `Accept` and `MCP-Protocol-Version`.
- Advertise server/tool metadata using current SDK fields where available.
- Add structured tool output and output schemas for the primary JSON-returning tools without removing existing text content.
- Add an elicitation-backed confirmation path for risky `send` calls when the client supports elicitation, with conservative fallback for clients that do not.
- Add focused tests for protocol validation, metadata shape, structured output, and send confirmation behavior.
- Update repo docs and user-facing skill guidance so future agents understand the current MCP contract.

Out of scope:
- Replacing the custom HTTP transport with the SDK transport. The per-session `Server` isolation is intentional and still useful for clean reconnects.
- Adding OAuth/resource-server auth directly to iMessage Max. Plug is the public/auth boundary today; iMessage Max remains localhost-only.
- Full task-augmented execution. iMessage Max tools are short local operations, and long-running durable tasks do not fit the current use cases.
- Full SSE replay persistence. We will improve compliance where cheap, but not build a durable event store unless tests show a real client need.

## Source References

- MCP `2025-11-25` changelog: latest stable spec adds icons, tool-name guidance, elicitation updates, sampling tool-calling, OAuth discovery updates, and experimental tasks.
- MCP `2025-06-18` changelog: removes JSON-RPC batching, adds structured tool output, resource links, elicitation, and `MCP-Protocol-Version` on subsequent HTTP requests.
- MCP transport spec: POST bodies must be single JSON-RPC messages; clients must advertise both JSON and SSE response formats; invalid Origin must return 403.
- Swift SDK docs: current SDK supports `Tool.title`, `Tool.outputSchema`, `Tool.Result.structuredContent`, server info metadata, elicitation helpers, and protected-resource auth helpers.
- Existing repo plan: `docs/plans/2026-02-24-refactor-comprehensive-audit-improvements-plan.md` already decided to keep custom HTTP transport and validate protocol-version headers.

## Key Decisions

1. **Keep custom HTTP transport, modernize it in place.**  
   `swift/Sources/iMessageMax/Server/HTTPTransport.swift` exists because each HTTP session owns a dedicated MCP `Server`. Replacing it risks reintroducing “already initialized” reconnect failures.

2. **Use strict current behavior with backward-compatible defaults.**  
   Initialize requests may omit `MCP-Protocol-Version`; non-initialize requests for sessions negotiated at `2025-06-18` or newer should include the header. Absent headers for legacy sessions should continue assuming `2025-03-26`.

3. **Structured output is additive.**  
   Existing tools return text content containing compact JSON strings. New `structuredContent` should mirror the same response object so older clients keep working while newer clients can parse tool results directly.

4. **Elicitation is best used for sending, not reading.**  
   Read-only tools should stay one-call and low-friction. `send` is the tool where human review can prevent accidental messages or ambiguous destinations. If the client lacks elicitation, preserve the existing conservative send behavior rather than blocking all sends.

5. **Do not add direct auth yet.**  
   The server binds to localhost and Plug already provides the public OAuth boundary. Adding another auth layer locally would create setup friction without improving the current threat model materially.

## Implementation Units

### Unit 1: SDK Patch And Server Metadata

Files:
- `swift/Package.resolved`
- `swift/Sources/iMessageMax/Server/MCPServer.swift`
- `swift/Sources/iMessageMax/Server/SessionManager.swift`
- `swift/Tests/iMessageMaxTests/HTTPTransportIntegrationTests.swift`

Work:
- Resolve `modelcontextprotocol/swift-sdk` from `0.12.0` to `0.12.1`.
- Instantiate `Server` with `title`, `instructions`, and explicit `capabilities.tools`.
- Keep server version from `Version.current`.
- Add an initialization test asserting `serverInfo.title`, `instructions`, negotiated `2025-11-25`, and tools capability are present.

Test scenarios:
- Initialize with `2025-11-25` returns `protocolVersion: "2025-11-25"`.
- Initialize result contains human display metadata and concise usage instructions.
- Stdio server creation still compiles with the same metadata path.

### Unit 2: Streamable HTTP Validation

Files:
- `swift/Sources/iMessageMax/Server/HTTPTransport.swift`
- `swift/Tests/iMessageMaxTests/HTTPTransportIntegrationTests.swift`
- `swift/README.md`
- `docs/validation/2026-04-09-release-checklist.md`

Work:
- Require POST `Accept` to include both `application/json` and `text/event-stream`, with `*/*` accepted only as a compatibility fallback for local health checks if needed.
- Track each session's negotiated protocol version in `SessionManager`.
- For non-initialize HTTP requests, reject unsupported `MCP-Protocol-Version` and reject missing version headers when the negotiated session is `2025-06-18` or newer.
- Preserve backward compatibility for sessions negotiated at `2025-03-26` or `2024-11-05`.
- Keep the existing JSON-RPC batch rejection and Origin 403 behavior.

Test scenarios:
- POST with only `Accept: application/json` is rejected for real MCP requests.
- POST with both content types succeeds.
- A `2025-11-25` session rejects subsequent requests missing `MCP-Protocol-Version`.
- A `2025-11-25` session rejects unsupported protocol-version headers.
- Batch request still returns 400.
- Invalid Origin still returns 403.

### Unit 3: Tool Metadata And Output Schemas

Files:
- `swift/Sources/iMessageMax/Server/ServerExtensions.swift`
- `swift/Sources/iMessageMax/Tools/*.swift`
- `swift/Tests/iMessageMaxTests/PlaceholderTests.swift`
- `swift/Tests/iMessageMaxTests/ResponseContractTests.swift`

Work:
- Extend `Server.registerTool` to accept top-level `title`, optional `outputSchema`, and optional `icons`.
- Move display titles from annotations-only into top-level `Tool.title` while preserving existing annotations for read-only/destructive hints.
- Add `outputSchema` for the primary structured-response tools: `find_chat`, `get_chat_details`, `list_chats`, `get_active_conversations`, `get_messages`, `get_context`, `search`, `get_unread`, `list_attachments`, `send`, and `diagnose`.
- Keep `get_attachment` focused on content because it can return image content.

Test scenarios:
- `tools/list` includes top-level `title` for every tool.
- JSON-returning tools include non-null `outputSchema`.
- Annotations remain present so clients keep read-only/destructive hints.
- Tool names remain spec-safe ASCII names under 128 chars.

### Unit 4: Structured Tool Results

Files:
- `swift/Sources/iMessageMax/Server/ServerExtensions.swift`
- `swift/Sources/iMessageMax/Tools/*.swift`
- `swift/Tests/iMessageMaxTests/ResponseContractTests.swift`

Work:
- Introduce a helper for tools that already encode JSON text to return both:
  - `content: [.text(...)]`
  - `structuredContent: <same object as MCP Value>`
- Update `ToolHandlerRegistry` and handlers so successful tools can return full `CallTool.Result`, not only `[Tool.Content]`.
- Use structured output for JSON-shaped read tools and `send`.
- Keep `isError: true` behavior for tool execution errors.

Test scenarios:
- Calling a JSON-shaped tool returns non-null `structuredContent`.
- The text content remains present for legacy clients.
- Tool errors continue to set `isError: true` and do not masquerade as protocol errors.
- Image attachment retrieval still returns image content without forced structured output.

### Unit 5: Send Elicitation Confirmation

Files:
- `swift/Sources/iMessageMax/Tools/Send.swift`
- `swift/Sources/iMessageMax/Tools/SendResolution.swift`
- `swift/Sources/iMessageMax/Server/ServerExtensions.swift`
- `swift/Tests/iMessageMaxTests/SendResponseTests.swift`
- `swift/Tests/iMessageMaxTests/SendToolExecutionTests.swift`

Work:
- Add an optional confirmation input such as `confirm: true` for clients that cannot support elicitation.
- When the client supports form elicitation and a send looks risky, request confirmation before executing:
  - group chat sends,
  - file sends,
  - ambiguous human destination resolved from `to`,
  - messages above a conservative length threshold.
- If the user declines or cancels, return a normal tool result with a cancelled/not-sent status.
- If the client lacks elicitation, require explicit confirmation for the risky cases instead of sending silently.
- Do not ask for sensitive credentials via elicitation.

Test scenarios:
- Risky send without elicitation support returns a pending-confirmation/not-sent result.
- Risky send with explicit confirmation follows existing send path.
- Low-risk direct text sends preserve existing behavior.
- Declined/cancelled elicitation returns a not-sent result.
- Existing file validation still happens before automation.

### Unit 6: Documentation And Runtime Validation

Files:
- `README.md`
- `swift/README.md`
- `using-imessage-max/SKILL.md`
- `using-imessage-max/references/workflows.md`
- `docs/validation/2026-04-09-release-checklist.md`

Work:
- Update MCP spec references from older baselines to `2025-11-25`.
- Document required HTTP headers for manual validation.
- Document structured output behavior and the legacy text-content fallback.
- Document send confirmation behavior for agents.
- Run `swift test`, `make install`, HTTP initialize/tools-list checks, and `plug status`.

Test scenarios:
- Docs examples use `Accept: application/json, text/event-stream`.
- Docs examples include `MCP-Protocol-Version` on post-initialize requests.
- Runtime health remains green after `make install`.
- Plug still reports `imessage` healthy.

## Risks And Mitigations

- **Client compatibility risk from stricter `Accept` validation:** preserve a narrow `*/*` compatibility fallback only if existing launchd health checks depend on it, and cover behavior with tests.
- **SDK API drift:** compile after `0.12.1` resolution before deeper edits; if APIs changed, adapt the wrapper rather than changing tool behavior.
- **Structured output duplication:** keep one encode path so text JSON and structured output cannot diverge.
- **Elicitation client support variance:** make elicitation opportunistic and keep explicit confirmation fallback for unsupported clients.
- **Accidental send behavior changes:** all send confirmation work must be tested through fake send runners; do not run live sends as part of automation.

## Verification Plan

- `cd swift && swift test`
- `cd swift && make install`
- HTTP initialize with `2025-11-25`
- HTTP `tools/list` with valid session and `MCP-Protocol-Version`
- Negative HTTP header tests through XCTest
- `plug status` confirms `imessage` healthy
