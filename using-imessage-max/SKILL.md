---
name: using-imessage-max
description: Use when working with the iMessage Max MCP server to review recent chats, catch up on missed conversation activity, inspect a known thread, browse shared items, or send into the correct thread. Especially useful when choosing between list_chats, get_unread, get_active_conversations, find_chat, get_chat_details, get_messages, search, list_attachments, get_attachment, and send.
---

# Using iMessage Max

## Overview

Use this skill to choose the right iMessage Max tool sequence for the user's intent.

The main rule is simple: start broad when completeness matters, then narrow. Do not let unread-only or activity-only views stand in for the full recent conversation landscape unless the user explicitly asks for that narrower slice.

When reporting results back to the user, use human chat names and participant names. Treat `chat_id` values such as `chat123` as internal handles for follow-up tool calls and exact sends; do not refer to conversations as "Chat 123" in user-facing prose when `chat.name`, `name`, or participant labels are available.

## Workflow Guide

### Broad catch-up or daily sweep

Use this when the user says things like:
- "catch me up on everything I missed"
- "morning sweep"
- "what happened in the last day or two"
- "show me what I should know from my texts"

Default flow:
1. Start with `list_chats` using a recent window such as `since="1d"` or `since="2d"` and `sort="recent"`.
2. Use `get_unread` as a cross-check for still-unread threads and message-level unread review when needed.
3. Use `get_active_conversations` only to prioritize which recent threads may deserve attention first.
4. Use `get_messages` to drill into the chats surfaced by the overview.

Why:
- `list_chats` gives the safest broad preview across recent conversations.
- `get_unread` is narrower and can miss important chats that were already opened.
- `get_active_conversations` is also narrower and can miss quiet but important threads.

### Targeted lookup

Use this when the user already knows the person, thread, or topic.

- If they know the person or chat identity, start with `find_chat`.
- If they already know the exact thread, use `get_chat_details` before opening message history.
- If they know the topic but not the chat, start with `search`.
- Then use `get_messages` or `get_context` to read the relevant section in detail.

### Attachment review

Use this when the user wants files, photos, screenshots, or documents.

Default flow:
1. Start with `list_attachments` to discover the message where items were shared.
2. Use `get_attachment` only after you have the exact attachment id.

Do not guess attachment ids or fetch attachments before discovery unless the user already supplied the exact id.

### Sending safely

Use this when the user wants to reply, send an update, or share a file.

- Prefer `chat_id` when the exact thread matters.
- Use `to` only when starting from a person is acceptable.
- If there is any ambiguity about the destination, resolve the chat first with `find_chat`.
- Risky sends can require confirmation. If the tool returns `pending_confirmation` asking for confirmation, review the destination/content and call `send` again with `confirm: true` only when the user intent is clear.
- In your response to the user, name the destination using the returned `chat.name` or participant labels, not the `chat_id`.

## Tool Selection

Use the right tool for the user's actual question:

- `list_chats`: broad recent overview, previews, first-pass catch-up
- `get_unread`: unread-only follow-up or cross-check
- `get_active_conversations`: prioritization hint for recent back-and-forth
- `find_chat`: richer details-layer lookup for a specific conversation by people, name, or recent content
- `get_chat_details`: factual details-layer view for a known thread
- `get_messages`: drill into one known chat
- `get_context`: inspect messages around one known message
- `search`: topic-first lookup when the chat is unknown
- `list_attachments`: discover shared items by message before fetching a specific file
- `get_attachment`: fetch one known attachment
- `send`: deliver a message or file to the correct place
- `diagnose`: troubleshoot permissions or configuration

For a compact decision matrix and example requests, read `references/workflows.md`.

## Common Mistakes

- Starting broad catch-up with `get_unread` alone.
- Starting broad catch-up with `get_active_conversations` alone.
- Using `find_chat` when the user does not have a targeted conversation in mind.
- Calling `get_messages` before establishing which chat should be reviewed.
- Using `to` for a sensitive send when the exact thread matters more than the person match.
- Saying "Chat 123" to the user instead of the returned chat name or participant-derived label.

## Quick Prompt Pattern

When the user asks for a catch-up, think:

1. broad overview first
2. narrower checks second
3. deep read last

When the user asks about one person or one topic, think:

1. locate the right conversation or message
2. then read the relevant part closely
