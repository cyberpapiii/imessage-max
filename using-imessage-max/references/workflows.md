# iMessage Max Workflow Reference

## Catch-Up Patterns

Use `chat_id` values only as internal handles for follow-up tool calls and exact sends. In summaries to the user, refer to conversations by returned chat names, explicit group names, or participant-derived labels.

### Broad catch-up

User request examples:
- "Catch me up on everything from the last two days"
- "Do a morning sweep of my texts"
- "What did I miss since yesterday?"

Preferred sequence:
1. `list_chats(since="2d", sort="recent")`
2. `get_unread(since="2d")`
3. `get_active_conversations(hours=48)`
4. `get_messages(chat_id="...", since="2d")` for the chats that matter

Reasoning:
- `list_chats` is the broadest recent preview
- `get_unread` defaults to unread thread summaries and catches still-unread items
- `get_active_conversations` helps prioritize
- `get_messages` is the deep read step

### Focus on one person or one thread

User request examples:
- "What did Contact A say yesterday?"
- "Show me the latest from the project group"

Preferred sequence:
1. `find_chat(...)`
2. `get_chat_details(chat_id="...")`
3. `get_messages(chat_id="...", since="...")`

Reasoning:
- `find_chat` is the richer details-layer tool when you already have a targeted thread in mind
- `get_chat_details` gives thread facts without forcing a deep read
- `get_messages` opens the thread and reads the conversation itself

### Topic-first lookup

User request examples:
- "Find where we talked about the budget"
- "Where did the launch timeline come up?"

Preferred sequence:
1. `search(query="...")`
2. `get_context(message_id="...")` or `get_messages(chat_id="...")`

## Attachment Pattern

User request examples:
- "Show me the screenshots from this week"
- "Find the PDF they sent"

Preferred sequence:
1. `list_attachments(...)`
2. `get_attachment(attachment_id="...")`

Reasoning:
- `list_attachments` is grouped by message, which matches how shared content is usually remembered
- `get_attachment` is still the exact fetch step for one known file

## Sending Pattern

User request examples:
- "Reply in that group"
- "Send this file to the exact thread"

Preferred sequence:
1. Resolve the thread if needed with `find_chat(...)`
2. Use `send(chat_id="...")` when exact placement matters

Use `send(to="...")` only when the user is comfortable starting from a person rather than a specific thread.
If `send` returns `pending_confirmation` for a risky destination, file, or long message, do not treat it as sent. Review the destination/content and call `send(..., confirm=true)` only when the user intent is clear.
