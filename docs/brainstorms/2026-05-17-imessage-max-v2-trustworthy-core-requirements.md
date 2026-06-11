---
date: 2026-05-17
topic: imessage-max-v2-trustworthy-core
---

# iMessage Max v2 Trustworthy Core

## Summary

iMessage Max v2 will make the existing local Mac-native MCP server clean, reliable, and capable enough to serve as a serious personal message intelligence layer for agents. The first release proves the trustworthy core: safer sends, explicit capability reporting, human-readable conversation identity, and honest degraded states.

---

## Problem Frame

iMessage Max already gives agents useful local access to iMessage through read-only `chat.db` queries, Contacts resolution, and Messages.app automation. That safe baseline is the product's advantage: it avoids paid messaging APIs, cloud relays, direct database writes, private frameworks by default, and reverse-engineered protocol risk.

The current gap is not basic read/send. The gap is trust. An agent needs to know whether a send actually landed in the intended conversation, what this install can and cannot do, when data is stale or permission-gated, and how to talk about conversations in human terms instead of leaking implementation IDs. Without that, richer features would compound uncertainty rather than improve the product.

The first v2 slice should therefore make the safest path feel serious and dependable before expanding into richer reads or live inbox behavior.

---

## Actors

- A1. Rob: Primary user, running iMessage Max locally on his Mac for personal agent workflows.
- A2. AI agent: Uses iMessage Max through MCP to inspect context, summarize activity, and carefully take messaging actions.
- A3. Technical power user: Secondary user who may install iMessage Max locally and needs clean docs, predictable behavior, and understandable capability boundaries.
- A4. Future rich backend maintainer: Adds optional BlueBubbles, imsg, or private-helper integrations later without changing the core product promise.

---

## Key Flows

- F1. Safe reply
  - **Trigger:** Rob asks an agent to reply in an existing iMessage conversation.
  - **Actors:** A1, A2
  - **Steps:** The agent resolves the human conversation, confirms the exact target when risk is elevated, sends through the safe local path, then re-reads the target conversation to establish a proof state.
  - **Outcome:** Rob gets an honest result: confirmed, pending, uncertain, mismatch, failed, or cancelled.
  - **Covered by:** R1, R2, R3, R5

- F2. Capability-aware action
  - **Trigger:** An agent wants to use a feature such as reply threading, tapbacks, attachments, or rich/private behavior.
  - **Actors:** A2
  - **Steps:** The agent checks the capability contract, sees whether the feature is supported, unsupported, permission-gated, degraded, risky/private, experimental, or unavailable, and chooses behavior that matches the current install.
  - **Outcome:** The agent does not attempt unavailable or risky actions silently.
  - **Covered by:** R4, R6, R10

- F3. Human-readable conversation work
  - **Trigger:** Rob asks about a conversation, unread thread, or recent message activity.
  - **Actors:** A1, A2
  - **Steps:** The agent receives stable internal identifiers for follow-up calls, but also gets human labels, participant summaries, ambiguity notes, and safe target descriptions.
  - **Outcome:** The agent can speak in normal human terms while preserving exact routing internally.
  - **Covered by:** R7, R8, R9

---

## Requirements

**Trustworthy sends**
- R1. Send results must be expressed as proof states, not just transport success.
- R2. The first v2 release must verify sends by re-reading the intended target conversation when possible.
- R3. If verification cannot prove the send landed in the intended conversation, the result must be honestly reported as pending, uncertain, mismatch, failed, or cancelled rather than presented as confirmed.
- R4. Risky sends must remain gated by review or explicit confirmation, especially group sends, file sends, ambiguous targets, and any action where the agent cannot clearly explain the destination.
- R5. The product must never silently convert an ambiguous group target into a direct-message target.

**Capability contract**
- R6. Diagnose-style output must become a user- and agent-readable capability contract, not only a health check.
- R7. Capability states must distinguish supported, unsupported, degraded, permission-gated, risky/private, experimental, unavailable, and unverified behavior.
- R8. The capability contract must cover send modes, attachment handling, reply/tapback/edit/unsend availability, live/freshness availability, permissions, and any rich/private backend state.
- R9. Capability reporting must prefer honest limitation over optimistic affordance; unsupported features should be easy for agents to avoid.

**Conversation identity**
- R10. Chat-returning responses must include human conversation labels and participant summaries alongside internal IDs.
- R11. Internal IDs must remain available for exact follow-up tool calls, but they should not be the easiest field for an agent to quote to Rob.
- R12. Ambiguous or similar-looking conversations must surface enough context for the agent to ask or confirm rather than guess.
- R13. Send-safe target descriptions must make clear who or which group will receive a message.

**Local trust model**
- R14. The default v2 product must remain local-first and Mac-native: read-only Messages data, Contacts enrichment, and Messages.app automation for sends.
- R15. The first v2 release must not require paid iMessage APIs, cloud relay, direct iMessage protocol access, private framework injection, or disabling SIP.
- R16. Any future rich backend must be opt-in, capability-gated, and clearly labeled as outside the default safety posture.
- R17. The product must expose degraded local states such as missing Full Disk Access, missing Contacts permission, missing Automation permission, unavailable attachments, stale data, or Messages.app unavailability.

**Roadmap alignment**
- R18. High-fidelity reads are the next major v2 track after the safer-send core.
- R19. Live inbox or delta surfaces are important but must follow the trustworthy core and high-fidelity read foundations.
- R20. Optional private/rich backends should be evaluated only after the native-safe capability contract is strong enough to describe them without ambiguity.

---

## Acceptance Examples

- AE1. **Covers R1, R2, R3.** Given an agent sends a message to a known group chat, when iMessage Max can re-read the target conversation and find the matching outbound row, the result is confirmed.
- AE2. **Covers R1, R3.** Given Messages.app reports a send attempt succeeded, when iMessage Max cannot find matching evidence in the intended conversation, the result is uncertain rather than confirmed.
- AE3. **Covers R4, R5, R12.** Given a contact name matches both a direct chat and a group chat, when the agent attempts to send without an exact target, iMessage Max refuses or asks for confirmation instead of guessing.
- AE4. **Covers R6, R7, R8, R9.** Given reply threading is not supported by the current safe backend, when an agent checks capabilities, the response marks it unsupported or unavailable and gives the agent a safe alternative path.
- AE5. **Covers R10, R11, R13.** Given a tool returns a conversation, when an agent summarizes it to Rob, the response shape makes the human label and participant summary more salient than the internal `chat_id`.
- AE6. **Covers R14, R15, R16.** Given a new local install with no rich backend configured, when the agent runs iMessage Max v2, all trustworthy-core behavior works without requiring SIP changes, paid APIs, or private frameworks.

---

## Success Criteria

- Common personal workflows feel cleaner: catch up, identify a thread, inspect context, and send a safe reply without unnecessary tool churn.
- Sends no longer create false confidence; every result communicates what iMessage Max actually proved.
- Agents can tell what the install supports before attempting unsupported actions.
- Rob sees human conversation names and clear status language, not database-shaped implementation details.
- The first v2 slice is strong enough to hand to another technical power user without fragile tribal knowledge.
- A later planning agent can plan implementation without inventing product behavior, safety posture, or release boundaries.

---

## Scope Boundaries

### Deferred for later

- High-fidelity read expansion for richer reactions, replies, edits/unsends, attachments, unsupported-content markers, and Tahoe-era message metadata.
- Live inbox, watch, or delta surfaces for active monitoring and lower tool-call churn.
- Optional BlueBubbles, imsg, private helper, or protocol-native adapters behind explicit capability reporting.
- Rich message actions such as tapbacks, typing indicators, read receipts, edit/unsend, reply-send, or group management.
- Broader installation packaging and onboarding for a larger power-user audience.

### Outside this product's identity

- A hosted iMessage SaaS or commercial outbound messaging platform.
- A full Messages.app replacement client.
- A default SIP-disabled/private-framework product.
- Direct writes to `chat.db`.
- Silent private API use or security bypasses.
- A promise of Apple-supported cloud iMessage access.
- Paid iMessage API dependency for the default local product.

---

## Key Decisions

- Primary user is Rob, with technical power users as a secondary audience: this keeps the product practical and local while still requiring clean docs and setup quality.
- The first v2 release proves trustworthy core before richer capability: this follows the priority order of cleanest, most reliable, most capable.
- Safer sends are the smallest meaningful first slice: they address the highest-risk user-visible action without forcing the whole v2 roadmap into one release.
- Rich/private behavior is optional future capability, not the default product promise: this preserves the local trust model and avoids turning v2 into a brittle Messages clone.
- Live inbox is intentionally third in priority: it is valuable, but it should not create false freshness confidence before proof and capability semantics are reliable.

---

## Dependencies / Assumptions

- The local Mac remains the primary runtime for v2.
- The safe backend continues to have read-only access to local Messages data and permissioned access to Contacts and Messages.app automation.
- Post-send verification can be implemented well enough to produce useful confirmed, pending, uncertain, mismatch, failed, and cancelled states.
- Some sends will remain honestly uncertain because local observation cannot prove every Messages.app behavior.
- Power-user documentation matters, but commercial onboarding, hosting, and scale are not first-release drivers.
- Future rich/private backends can be described through a capability contract before they are implemented.

---

## Outstanding Questions

### Resolve Before Planning

- [Affects R1, R2, R3][Product] What exact proof-state vocabulary should be exposed publicly for send results?
- [Affects R4][Product] Which sends are always risky enough to require confirmation in the first v2 release?
- [Affects R6, R7, R8][Product] Which capability categories are mandatory for the first capability contract, and which can be added with later tracks?

### Deferred to Planning

- [Affects R2, R3][Technical] How should send verification correlate outbound rows with a specific safe-send attempt?
- [Affects R6, R7, R8][Technical] Which runtime probes are needed so the capability contract reflects actual behavior rather than static claims?
- [Affects R10, R11, R12, R13][Technical] Which response contracts need adjustment so human labels become the natural agent-facing path?
