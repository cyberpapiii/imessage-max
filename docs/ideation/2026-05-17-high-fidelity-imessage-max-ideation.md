---
date: 2026-05-17
topic: high-fidelity-imessage-max
focus: Tahoe-era iMessage fidelity, safe default architecture, prior-art comparison
mode: repo-grounded
---

# Ideation: High-Fidelity iMessage Max

## Grounding Context

iMessage Max is a Swift-native MCP server for local iMessage access. Its safe default architecture is still the right baseline: read `~/Library/Messages/chat.db` in read-only mode, resolve names through Contacts, send through Messages.app AppleScript/JXA automation, and avoid direct database writes or private framework injection.

The repo already has several agent-oriented hardening choices: custom HTTP transport with per-session isolation, structured tool output, native MCP image content for image attachments, exact `chat_id` routing for sends, risky-send confirmation, and explicit guidance that agents should use human chat names in user-facing prose.

The highest-value gaps are not basic read/send. They are freshness, fidelity, and trust: no live update surface, weak post-send proof, partial attachment coverage, intentionally unsupported native `reply_to`, possible `chat_id` leakage into agent prose, and incomplete runtime capability reporting.

Prior research and comparable projects support the same boundary. `imsg`, BlueBubbles, and other iMessage MCP servers converge on `chat.db` reads plus Messages.app automation as the safe lane. Private IMCore/ChatKit-style helpers unlock richer features like tapbacks, typing indicators, read receipts, edit/unsend, and group management, but carry SIP, injection, OS-drift, and Messages.app stability risk.

Tahoe-era Messages features add new read-side fidelity targets: polls, conversation backgrounds, unknown-sender screening, shared-content organization, live translation metadata, richer search semantics, and potential RCS/SMS categorization signals. These should be treated first as read-only parse/enrichment targets, not as evidence of a new official Messages control API.

## Topic Axes

- Live updates
- Message fidelity
- Send safety and routing
- Agent-facing context/resources
- Trust and capability boundaries

## Ranked Ideas

### 1. Verified Send Receipts

**Description:** Treat `send` as unresolved until iMessage Max re-reads the intended target chat and finds a matching outbound row. Verification should match target `chat.guid`, body or staged attachment metadata, timestamp window, sender direction, and possibly participant set. Return explicit states such as `confirmed`, `pending`, `uncertain`, and `mismatch`.

**Axis:** Send safety and routing

**Basis:** direct: repo learnings say send correctness means exact thread landing, not just MCP return shape; external: `imsg` documents Tahoe-era AppleScript success modes that can still require database verification.

**Rationale:** Sending is the highest-risk action because a false success claim or wrong-thread send is user-visible and hard to undo. This gives every future send workflow a concrete proof state without adopting private APIs.

**Downsides:** Requires careful matching windows, attachment heuristics, and live/manual validation against real Messages behavior. Some sends may remain honestly `uncertain`.

**Confidence:** 92%

**Complexity:** Medium

**Status:** Unexplored

### 2. Live Conversation Pulse

**Description:** Add a safe `watch_conversations` or `get_changes_since` surface that returns message, unread, reaction, and attachment deltas since a cursor. Start with bounded polling over `chat.db`, then optionally add filesystem events as an optimization. Label it as best-effort local observation, not guaranteed push.

**Axis:** Live updates

**Basis:** external: `imsg` demonstrates FSEvents plus polling fallback as an agent-friendly pattern; reasoned: agents currently have to repeatedly query broad tools to infer freshness.

**Rationale:** This would make iMessage Max feel current during active agent sessions while preserving the safe read-only architecture. It also reduces tool-call churn for catch-ups and monitoring.

**Downsides:** Durable replay, missed offline events, WAL behavior, and cursor semantics need careful design. It should not pretend to be server-side push from Apple.

**Confidence:** 88%

**Complexity:** Medium

**Status:** Unexplored

### 3. Message Semantics Ledger

**Description:** Centralize message parsing into one typed event layer that preserves text source, attributedBody extraction status, reactions/removals, reply relationships where inferable, edits/unsends where represented, attachment provenance, Tahoe poll/translation/background markers, and unsupported-content markers.

**Axis:** Message fidelity

**Basis:** direct: prior repo plans require one `MessageTextExtractor` and fixture SQLite tests; external: `imessage-exporter` is the strongest reference for typedstream, Tahoe, and message-payload parsing behavior.

**Rationale:** High-fidelity read support should not be scattered across `get_messages`, `search`, `list_chats`, and attachment tools. A shared ledger lets every tool benefit from the same parser and confidence model.

**Downsides:** Schema mining is tedious and private/unstable. Some Tahoe features may only be detectable as markers at first, not fully renderable content.

**Confidence:** 86%

**Complexity:** High

**Status:** Unexplored

### 4. Human-Named Conversation Handles

**Description:** Make every chat-returning response include a first-class human label, participant summary, ambiguity note, and send-safe target description alongside the internal `chat_id`. Keep `chat_id` available for exact follow-up tool calls, but make the human label the obvious field for agent prose.

**Axis:** Agent-facing context/resources

**Basis:** direct: the repo skill and README already state that agents should not say "Chat 123" to users; reasoned: if the response shape makes IDs easier to copy than names, models will leak IDs despite instructions.

**Rationale:** This turns a prompt/instruction problem into an API design problem. Better response shape can make agent output naturally human without losing exact routing.

**Downsides:** Requires consistent response contract changes across all chat-returning tools and tests for similar names, unnamed groups, and duplicate participant sets.

**Confidence:** 84%

**Complexity:** Medium

**Status:** Unexplored

### 5. Agent Inbox Resource Graph

**Description:** Expose MCP resources or compact resource-like tools such as `messages://inbox`, `messages://conversation/{chat_id}`, `messages://shared/{chat_id}`, and `messages://capabilities`. These should provide linked, agent-optimized context: active chats, unread deltas, participant maps, shared-content highlights, open questions, and safe reply affordances.

**Axis:** Agent-facing context/resources

**Basis:** external: other MCP iMessage servers use resource-style surfaces; reasoned: agents repeatedly stitch together list/search/details/messages calls to build one conversation workspace.

**Rationale:** This directly serves the project goal of reducing tool calls per user intent. It also gives clients a low-friction way to load context without learning every tool combination.

**Downsides:** MCP resources/subscriptions need to fit the custom HTTP transport and current SDK behavior. Resource contracts can become stale if they duplicate tool outputs.

**Confidence:** 80%

**Complexity:** Medium

**Status:** Unexplored

### 6. Capability Contract Diagnose

**Description:** Expand `diagnose` from health/status into a machine-readable capability contract: supported, unsupported, degraded, risky/private, permission-gated, Tahoe-dependent, and unverified. Include send modes, reply/tapback/edit/unsend status, attachment type coverage, live pulse availability, private API disabled status, and exact permission state.

**Axis:** Trust and capability boundaries

**Basis:** direct: repo learnings already call for explicit capability reporting; external: read-only MCP competitors emphasize trust metadata and safety posture.

**Rationale:** Agents should know what not to attempt before they attempt it. This is especially important as iMessage Max adds richer read-side fidelity while still rejecting unsafe private control by default.

**Downsides:** Needs maintenance discipline so the capability contract stays synchronized with actual tool behavior. Some capability states may require runtime probes.

**Confidence:** 89%

**Complexity:** Low

**Status:** Unexplored

### 7. Attachment Fidelity Ladder

**Description:** Replace image-first attachment handling with a declared ladder of supported representations: image thumbnail/vision/full, video metadata and thumbnails, audio metadata/transcript hooks, PDF/document metadata or text extraction where safe, sticker/shared-link/contact/location markers, and explicit iCloud-unavailable states.

**Axis:** Message fidelity

**Basis:** direct: current scan found image-first attachment support and existing audio/video processors that appear under-surfaced; external: `imsg` and `imessage-exporter` both treat attachment metadata/conversion as core fidelity.

**Rationale:** iMessage context is media-heavy. Agents often need to know what was shared and whether it is available more than they need a raw file path.

**Downsides:** Some conversions require extra dependencies or careful sandbox behavior. Large files and iCloud-offloaded assets need conservative limits.

**Confidence:** 78%

**Complexity:** Medium

**Status:** Unexplored

## Rejection Summary

| # | Idea | Reason Rejected |
|---|------|-----------------|
| 1 | Safe Private-Mode Capability Envelope | Useful but strategically later; private API work should not compete with safe read/watch/send verification foundations yet. |
| 2 | Reply-To Shadow Model | Valuable as a sub-feature of Message Semantics Ledger and send UX, but weaker than the larger parser and send-verification ideas. |
| 3 | Unknown-Sender Boundary Mode | Good Tahoe-specific safety feature, but best handled inside capability reporting plus message enrichment rather than as a standalone track. |
| 4 | Routing Diagnostics for Ambiguous Sends | Strong implementation detail, but mostly folds into Verified Send Receipts and Human-Named Conversation Handles. |
| 5 | Tahoe-Aware Unsupported Content Markers | Important, but should be the first milestone of Message Semantics Ledger rather than its own separate initiative. |
| 6 | Fixture Corpus For iMessage Edge Cases | Essential engineering support, but not a user-facing improvement by itself; include it as acceptance criteria for parser/send work. |
| 7 | Docs Drift Sentinel | Valid cleanup, but below the ambition floor for this topic. It can be a quick maintenance task outside the high-fidelity roadmap. |
| 8 | Optional Companion App Intents | Interesting future wrapper, but App Intents do not deepen Messages access and should wait until the core MCP surface is stronger. |
| 9 | Private IMCore/ChatKit backend | Too much operational and crash risk for the default roadmap; keep as explicit future research only. |

## Suggested Next Step

Start with **Verified Send Receipts** or **Live Conversation Pulse**. Verified Send Receipts is the best reliability-first move; Live Conversation Pulse is the most transformative agent-experience move. Either one should go through `ce-brainstorm` before implementation planning.
