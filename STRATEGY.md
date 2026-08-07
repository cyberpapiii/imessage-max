---
name: iMessage Max
last_updated: 2026-05-18
---

# iMessage Max Strategy

## Target problem

AI assistants do not have access to the user's personal communication. For Apple users, much of that lives in iMessage, and Messages offers no local interface an agent can use to track open loops, reason about conversations, or act safely.

## Our approach

Be the local foundation for agent access to Messages. Everything stays on the Mac, and the read side keeps the detail Messages actually carries instead of flattening it to plain text. Agents should reason about iMessage the way a person does, in terms of conversations, people, open loops, and shared context, rather than in terms of database tables or AppleScript quirks.

## Who it's for

Primary: knowledge workers who already run local agents. They want their agent to read and manage iMessage with the same context they have.

## Key metrics

- Successful delegated workflows: rate of real user intents completed end to end. Catch up, find context, draft a reply, send safely, inspect shared media.
- Tool calls per intent: average MCP calls for common workflows, against the 3-5 call baseline.
- Verified send rate: percentage of sends returning `confirmed` rather than `uncertain`, `failed`, or `mismatch`.
- Human correction rate: how often the user has to correct the agent about the person, conversation, context, or action.
- Time to context: how long an agent takes to answer "what's going on with X?" from Messages.

## Tracks

### Trustworthy core

Verified sends, exact targeting, capability contracts, degraded states, safe confirmation, and local runtime reliability.

_Why it serves the approach:_ if an agent cannot tell what happened or what is supported, more capability only adds risk.

### Human-level conversation model

Conversation identity, people, open loops, relationship/context cues, shared media, and agent-friendly summaries.

_Why it serves the approach:_ agents need to navigate Messages by people, conversations, context, and obligations, the way a person does.

### High-fidelity message understanding

Richer read-side understanding of reactions, replies, edits/unsends, attachments, media, unavailable content, and iMessage semantics.

_Why it serves the approach:_ detail matters when it lets an agent reason accurately instead of flattening Messages into plain text.

### Agent-native tool set

Intent-aligned tools, structured outputs, fewer tool calls, better diagnostics.

_Why it serves the approach:_ this is not a database browser. It is a local base agents build on.

### Local runtime reliability

Launchd health, permissions, install flow, logging, service status, reconnect behavior, and Mac-native resilience.

_Why it serves the approach:_ the Mac is the runtime, so the local service staying up is part of the product, not background maintenance.

## Not working on

- A hosted iMessage SaaS, commercial outbound messaging platform, or paid API path.

## Marketing

One-liner: local iMessage access for agents, with verified sends.

Key message: give an agent the same iMessage context you have, without handing Messages to the cloud. Everything runs on your Mac, behind the permissions you already grant.
