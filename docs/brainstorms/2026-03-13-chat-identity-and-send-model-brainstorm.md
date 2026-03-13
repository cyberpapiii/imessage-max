---
date: 2026-03-13
topic: chat-identity-and-send-model
---

# Chat Identity And Send Model

## What We're Building
Refactor iMessage Max so the LLM navigates conversations the way a human does in Messages, while preserving deterministic send behavior. The core change is to make `chat` the canonical identity for both read and write flows, instead of treating reads as chat-centric and writes as handle-centric.

This keeps the current UX mental model intact for named group chats, unnamed multi-person chats, one-to-one chats, and mixed groups with both contacts and raw phone numbers. Discovery remains fuzzy and human-oriented. Sending becomes exact and conversation-oriented.

## Why This Approach
There are two plausible approaches:

1. Make `send` smarter with more heuristics at send time.
2. Make chat identity canonical and require send to operate on the resolved conversation.

The second approach is the right one. It is simpler, safer, and more ergonomic for an LLM. It removes the current mismatch where discovery returns a conversation-like object but sending degrades to a participant handle. That mismatch is the root cause of reliability problems for group chats and mixed-identity threads.

## Key Decisions
- Canonical write target is `chat`, not `participant`.
  Rationale: Humans think in conversations, and the MCP already exposes conversation-oriented discovery.

- `chat_id` is the exact outbound target.
  Rationale: The LLM can search fuzzily, but sending must be deterministic.

- `to` remains as a convenience resolver only.
  Rationale: It preserves current ergonomics for simple cases without making send ambiguous.

- Discovery tools stay fuzzy; send tools must refuse ambiguity.
  Rationale: Search should feel natural, sending should feel safe.

- Named and unnamed groups both resolve to the same internal `ChatIdentity`.
  Rationale: The app should not need different mental models for these cases.

- Mixed participant groups must preserve both human labels and exact handles.
  Rationale: A group containing `Nick`, `Sarah`, and `+1 702...` must remain understandable to the LLM and exact to the transport.

- Outbound attachments are part of the solid core feature set.
  Rationale: The Messages scripting dictionary supports `send file to chat|participant`, and save-the-date style workflows need it.

- Advanced message-state actions remain out of scope for the solid core.
  Rationale: Inline reply send, Tapbacks, edit/unsend, typing, and similar features are not cleanly exposed in the current public scripting model and would harm reliability.

## Chat Identity Model
Every conversation exposed to the LLM should be representable as a single canonical object with:

- MCP `chat_id`
- Messages `chat_guid`
- display label
- participant count
- named/unnamed flag
- exact participant handles
- participant display names
- generated aliases for ranking and disambiguation

The display label should follow this order:

1. explicit Messages chat name
2. deterministic participant-derived label

The participant-derived label should:

1. prefer contact-backed names
2. fall back to normalized phone/email display strings
3. preserve stable ordering so the same chat renders consistently

## Discovery And Send Semantics
Discovery tools should return ranked conversations and enough metadata for the LLM to reason about them naturally.

The LLM may search with:
- a person name
- a group name
- a participant set
- recent content

But send should only occur after one conversation has been resolved exactly.

The safe rule is:
- fuzzy in
- exact out

That means:
- `find_chat` returns one or more candidate chats
- `list_chats` shows the same identity model
- `get_messages` reads by chat identity
- `send(chat_id=...)` writes to that exact chat identity

## Solid Core Feature Set
The refactor should deliver this minimal reliable set:

1. send text to a single-person chat
2. send text to an existing group chat
3. send file/image to a single-person chat
4. send file/image to an existing group chat
5. deterministic ordering when both files and text are present
6. capability reporting so the LLM knows what is and is not supported

## Failure Model
The MCP must return stable, explainable errors instead of guessing:

- `ambiguous_chat`
- `chat_not_found`
- `participant_not_found`
- `file_not_found`
- `automation_permission_required`
- `messages_app_unavailable`
- `unsupported_payload`
- `send_failed`
- `timeout`

The MCP should never silently convert an ambiguous group target into a DM.

## Open Questions
- Whether the AppleScript chat-targeting path can resolve directly by Messages `chat.guid` on all supported macOS versions, or whether a small lookup script is needed first.
- Whether sending text and files in one `send` call should always be file-first then text, or whether the tool should expose an explicit ordering field.
- Whether `to` should continue to auto-send on a single clear match, or whether it should become resolve-only for stricter safety.

## Next Steps
→ `/ce:plan` for implementation details
