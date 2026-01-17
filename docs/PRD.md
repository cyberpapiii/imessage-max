# Product Requirements Document: Claude-Native iMessage MCP

**Document Version:** 1.4
**Date:** January 16, 2026
**Author:** Rob Dezendorf & Claude
**Status:** Ready for Implementation

---

## Executive Summary

This PRD defines the requirements for a new iMessage MCP (Model Context Protocol) server designed specifically for AI assistant consumption. The current iMessage MCP implementations expose raw database structures that require extensive interpretation, multiple tool calls, and manual cross-referencing to accomplish simple tasks. This new MCP will provide intent-aligned tools that map directly to how humans think about and interact with their messages.

### The Core Problem

When a user asks "What did Nick say about the budget yesterday?", the current tools require:

1. Search contacts for "Nick" → returns multiple matches with phone numbers
2. Disambiguate which Nick (guess or ask user)
3. Search messages by phone number and date range
4. Receive results from ALL chats Nick is in, not filtered
5. Manually scan for "budget" mentions
6. Hope the right Nick was selected

**This should be one tool call.**

### Success Metric

Reduce the average number of tool calls per user intent from 3-5 to 1-2, while improving result relevance and eliminating the need for the AI to perform manual data correlation.

---

## Problem Analysis

### Current State Assessment

Several iMessage MCPs currently exist in the ecosystem:

**1. Deno MCP (`@wyattjoh/imessage-mcp`)**

| Capability | Assessment |
|------------|------------|
| Read chat history chronologically | ✅ Strong - pagination support |
| Resolve contact names | ❌ Returns raw phone numbers only |
| Find chat by participants | ❌ No support - must know GUID |
| Filter by content + person + time | ❌ No compound queries |
| Handle reactions/tapbacks | ❌ Returns as separate messages |

**2. Python MCP (`mac-messages-mcp` / `carterlasalle/mac_messages_mcp`)**

| Capability | Assessment |
|------------|------------|
| Send messages | ✅ Works well |
| Resolve contact names | ✅ Integrates Contacts framework |
| Find chat by participants | ❌ No support |
| Get chronological history | ❌ Cannot retrieve by chat ID |
| Search content | ⚠️ Basic - no compound filters |

**3. Native Swift MCP (`mattt/iMCP`)**

| Capability | Assessment |
|------------|------------|
| Sandboxed operation | ✅ Enhanced security |
| Send messages | ❌ No support |
| Read messages | ✅ Basic support |
| macOS requirement | ⚠️ macOS 15.3+ only |

### Root Cause Analysis

All existing MCPs expose the iMessage SQLite database structure rather than abstracting it into intent-based operations. The database schema separates:

- `chat` table (conversation metadata)
- `message` table (individual messages)
- `handle` table (phone numbers/emails)
- `chat_handle_join` table (which handles belong to which chats)
- `chat_message_join` table (which messages belong to which chats)

This normalized structure is efficient for storage but hostile to intent-based queries. The AI must mentally JOIN these tables across multiple tool calls, which is exactly what the MCP should be doing internally.

### Impact on User Experience

| User Intent | Current Experience | Ideal Experience |
|-------------|-------------------|------------------|
| "Find my chat with Nick and Andrew" | 3-5 tool calls, may fail to find unnamed group chats | 1 tool call |
| "What did we discuss about the budget?" | 2-3 tool calls, results mixed across chats | 1 tool call with relevant context |
| "Send Andrew the link I sent Nick last week" | 4+ tool calls, manual URL extraction | 2 tool calls with structured data |
| "Who was I texting at 2am?" | 2-5 tool calls to resolve contact names | 1 tool call with names resolved |
| "Did she reply to my dinner question?" | 2-3 tool calls, confusing reaction noise | 1 tool call with threaded context |

### Group Chat Complexity

Group chats represent the hardest failure mode for current tools. They exist on a spectrum of complexity:

| Type | Example | Current Tool Behavior | Failure Mode |
|------|---------|----------------------|--------------|
| Named group, all contacts | "brunch boys" | Can find by name, but returns phone numbers | Manual contact resolution needed |
| Unnamed group, all contacts | Shows as "Nick & Andrew" in UI | Cannot find - no display_name in DB | Complete failure |
| Unnamed group, mixed contacts/unknown | "Mike, +1 (702) 555-1234" | Cannot find, cannot identify unknowns | Complete failure |
| Renamed group | Was "Ski Trip", now "Tahoe 2026" | Finds by current name only | User can't find by remembered name |
| Large group with name collisions | "Loop" chat with two Mikes | Returns ambiguous results | AI guesses or asks unhelpfully |

**Why Group Chats Fail:**

1. **No participant-based lookup**: The database has `chat_handle_join` linking chats to handles, but no MCP exposes a "find chat containing these people" operation.

2. **Auto-generated names not replicated**: Messages.app generates display names like "Nick & Andrew" from contact names when no explicit name is set. Current MCPs return `null` or empty string, providing no identification.

3. **Unknown numbers are opaque**: When a group includes phone numbers not in contacts, current tools just return the raw E.164 format with no formatting or indication that the person is unknown.

4. **No join-date awareness**: Users often ask about messages "before I was added" but no tool tracks when the user joined each chat (approximated by first sent message).

5. **Name changes are invisible**: Chat names can change, but there's no history. Users remember old names that no longer match.

---

## Design Principles

### 1. Intent-Aligned Tool Design

Tools should map to how humans think about messages, not how databases store them. Users think in terms of:

- **People**: "my chat with Sarah", "messages from Mom"
- **Topics**: "the budget discussion", "that link about fish audio"
- **Time**: "yesterday", "last week", "at 2am"
- **Actions**: "send", "find", "summarize"

Tools should accept these natural parameters directly.

### 2. Resolved Data by Default

Every response should include human-readable information:

- Contact names instead of phone numbers
- Chat names or participant lists instead of GUIDs
- Timestamps in readable formats with relative descriptions
- Extracted metadata (links, attachment types) as structured fields

### 3. Noise Reduction

The MCP should filter out or restructure:

- Tapback reactions (fold into original message as metadata)
- Delivery receipts and read receipts (exclude unless requested)
- System messages (exclude unless requested)
- Duplicate content from message effects

### 4. Graceful Disambiguation

When queries are ambiguous, return structured options rather than failing:

```json
{
  "ambiguous": true,
  "candidates": [
    {"name": "Nick Gallo", "last_contact": "2 hours ago", "preview": "can we have a quick chat?"},
    {"name": "Nick DePalma", "last_contact": "3 months ago", "preview": "happy birthday!"}
  ]
}
```

This enables the AI to ask smart clarifying questions.

### 5. Composable Filters

All retrieval tools should support optional filters that can be combined:

- `from`: person(s) who sent messages
- `in_chat`: specific chat or chat with specific participants
- `contains`: text content search
- `has`: attachment type (link, image, video, file)
- `since`/`before`: time bounds
- `exclude`: negative filters (not from, not in chat)

---

## Tool Specifications

### Overview

The MCP exposes nine tools, each designed around a specific user intent:

| Tool | Purpose | Primary Use Case |
|------|---------|------------------|
| `find_chat` | Locate chat by participants, name, or content | "Find my chat with Nick and Andrew" |
| `get_messages` | Retrieve messages with flexible filtering | "Show messages from yesterday" |
| `get_context` | Get messages surrounding a specific message | "What led up to that decision?" |
| `search` | Full-text search with compound filters | "What did Nick say about budget?" |
| `list_chats` | Browse recent/active chats with previews | "What chats have been active today?" |
| `send` | Send a message to person or group | "Send Andrew that link" |
| `get_active_conversations` | Find chats with recent back-and-forth | "What conversations need my attention?" |
| `list_attachments` | Retrieve attachments by type, person, chat | "Find that PDF Nick sent" |
| `get_unread` | Get unread messages or summary | "Do I have any unread messages?" |

**Cross-cutting Enhancements:**

- `from: "me"` supported across all retrieval tools
- `unanswered: true` filter for messages awaiting reply
- Conversation session detection with natural break boundaries
- Smart error suggestions when queries return no results
- Pagination with cursor-based navigation

---

### Tool 1: `find_chat`

**Purpose:** Locate a chat by participants, name, or recent content.

**Why this tool exists:** The most common failure mode is not being able to identify which chat to read. Group chats often have no display name, and users refer to them by who's in them ("my chat with Nick and Andrew"). This tool bridges that gap.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `participants` | string[] | No | List of participant names (fuzzy matched) |
| `name` | string | No | Chat display name (fuzzy matched) |
| `contains_recent` | string | No | Text that appears in recent messages |
| `is_group` | boolean | No | Filter to group chats only (default: null = both) |
| `limit` | integer | No | Max results to return (default: 5) |
| `cursor` | string | No | Pagination cursor from previous response |

**At least one of `participants`, `name`, or `contains_recent` must be provided.**

**Response Schema:**

```json
{
  "chats": [
    {
      "chat_id": "chat855623491322171828",
      "display_name": null,
      "display_name_generated": "Nick & Andrew",
      "match_reason": "participants_match",
      "match_details": "Contains all specified participants: Nick Gallo, Andrew Watts",
      "participants": [
        {
          "name": "Nick Gallo",
          "handle": "+19176122942",
          "in_contacts": true,
          "message_count_in_chat": 234,
          "last_message_in_chat": "2 hours ago"
        },
        {
          "name": "Andrew Watts",
          "handle": "+15626886330",
          "in_contacts": true,
          "message_count_in_chat": 189,
          "last_message_in_chat": "10 hours ago"
        },
        {
          "name": null,
          "handle": "+17025551234",
          "handle_formatted": "+1 (702) 555-1234",
          "in_contacts": false,
          "message_count_in_chat": 12,
          "last_message_in_chat": "3 days ago"
        }
      ],
      "last_message": {
        "timestamp": "2026-01-16T02:30:38Z",
        "preview": "Ok so entertain this for me...",
        "from": "Nick Gallo"
      },
      "message_count_24h": 15,
      "is_group": true,
      "participant_count": 4,
      "user_joined_at": "2025-06-15T10:30:00Z",
      "user_joined_relative": "7 months ago",
      "messages_before_user_joined": 1247
    }
  ],
  "ambiguous": false,
  "has_more": false,
  "next_cursor": null
}
```

**Cascading Match Strategy:**

When searching by `name`, the tool cascades through match strategies until it finds results:

1. **Exact name match**: `display_name = 'brunch boys'`
2. **Fuzzy name match**: `display_name LIKE '%brunch%'` or Levenshtein distance < 3
3. **Content-based match**: Search recent messages for the term, return parent chats
4. **Participant name match**: If name looks like a person's name, try participant matching

Each result includes `match_reason` explaining why it was returned:
- `exact_name_match`: Display name matched exactly
- `fuzzy_name_match`: Display name was similar
- `content_match`: Chat contains messages with the search term
- `participants_match`: Chat contains specified participants
- `participant_name_match`: Name matched a participant in the chat

**Generated Display Names:**

When `display_name` is null, the MCP generates `display_name_generated` using the same logic as Messages.app:

1. If all participants are in contacts: comma-separated names (e.g., "Nick, Andrew, Mike")
2. If some participants unknown: names + formatted numbers (e.g., "Nick, +1 (702) 555-1234")
3. If more than 4 participants: first 3 names + "and 2 others"

**Participant Activity Context:**

Each participant includes activity metrics to help with disambiguation:
- `message_count_in_chat`: Total messages from this person in the chat
- `last_message_in_chat`: Relative time of their most recent message

This enables smart suggestions like "Mike Cantwell (234 messages) vs Mike Chen (12 messages)".

**User Join Date Tracking:**

For group chats, the response includes:
- `user_joined_at`: Approximated from user's first sent message in the chat
- `user_joined_relative`: Human-readable relative time
- `messages_before_user_joined`: Count of messages before user's first message

This enables queries like "show me what they discussed before I joined."

**Edge Cases:**

- Multiple people with same first name → return all matching chats with full names and activity context for disambiguation
- No matches → return empty array with `suggestions` field containing similar names/chats
- Participant not in contacts → attempt phone number/email matching, format nicely
- Chat was renamed → content-based fallback finds by old name mentions

---

### Tool 2: `get_messages`

**Purpose:** Retrieve messages from a chat with flexible filtering and formatting.

**Why this tool exists:** This is the core retrieval operation. It replaces the current pattern of "get chat by ID" + "search messages" + "resolve contacts" with a single unified call.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `chat_id` | string | No* | Chat identifier from `find_chat` |
| `participants` | string[] | No* | Alternative to chat_id - find chat by participants |
| `since` | string | No | Time bound: ISO timestamp, relative ("24h", "7d"), or natural ("yesterday") |
| `before` | string | No | Upper time bound (same formats as `since`) |
| `before_user_joined` | boolean | No | Only messages before user was added to chat (default: false) |
| `limit` | integer | No | Max messages to return (default: 50, max: 200) |
| `from` | string | No | Filter to messages from specific person |
| `contains` | string | No | Text search within messages |
| `has` | string | No | Filter by content type: "link", "image", "video", "attachment" |
| `format` | string | No | Response format: "chronological" (default), "grouped_by_sender" |
| `include_reactions` | boolean | No | Include reaction data (default: true, as metadata not separate messages) |
| `cursor` | string | No | Pagination cursor from previous response |

***Either `chat_id` or `participants` must be provided.**

**Response Schema (chronological format):**

```json
{
  "chat": {
    "chat_id": "chat855623491322171828",
    "display_name": null,
    "display_name_generated": "Nick & Andrew",
    "participants": [
      {"name": "Nick Gallo", "handle": "+19176122942", "in_contacts": true},
      {"name": "Andrew Watts", "handle": "+15626886330", "in_contacts": true}
    ],
    "user_joined_at": "2025-06-15T10:30:00Z"
  },
  "messages": [
    {
      "id": "msg_abc123",
      "timestamp": "2026-01-16T02:30:38Z",
      "timestamp_relative": "10 hours ago",
      "from": {
        "name": "Nick Gallo",
        "handle": "+19176122942",
        "in_contacts": true,
        "is_me": false
      },
      "text": "Ok so entertain this for me and tell me if you see this as a viable path forward...",
      "reactions": [
        {"type": "loved", "from": "Andrew Watts", "timestamp": "2026-01-16T02:31:00Z"}
      ],
      "reply_to": null,
      "attachments": [],
      "extracted_links": []
    }
  ],
  "has_more": true,
  "next_cursor": "cursor_xyz789",
  "messages_before_user_joined_available": 1247
}
```

**Response Schema (grouped_by_sender format):**

Useful for summarizing who said what in a group conversation:

```json
{
  "chat": {...},
  "grouped_by_sender": [
    {
      "sender": {"name": "Nick Gallo", "handle": "+19176122942", "in_contacts": true},
      "message_count": 12,
      "messages": [
        {"id": "msg_abc123", "timestamp": "...", "text": "...", "preview": true},
        {"id": "msg_def456", "timestamp": "...", "text": "...", "preview": true}
      ]
    },
    {
      "sender": {"name": "Andrew Watts", ...},
      "message_count": 8,
      "messages": [...]
    }
  ],
  "time_range": {"from": "2026-01-15T22:00:00Z", "to": "2026-01-16T02:30:38Z"}
}
```

**Disambiguation Response:**

When `from` parameter matches multiple participants in the chat:

```json
{
  "ambiguous": true,
  "ambiguous_field": "from",
  "chat": {
    "chat_id": "chat22260148430139505",
    "display_name": "Loop"
  },
  "candidates": [
    {
      "name": "Mike Cantwell",
      "handle": "+15162507668",
      "in_contacts": true,
      "message_count_in_chat": 234,
      "last_message_preview": "Tell me why I found this on the chair",
      "last_message_time": "2 hours ago"
    },
    {
      "name": "Mike Chen",
      "handle": "+14085551234",
      "in_contacts": true,
      "message_count_in_chat": 12,
      "last_message_preview": "Can someone send me the deck?",
      "last_message_time": "3 days ago"
    }
  ],
  "suggestion": "Mike Cantwell is more active in this chat (234 vs 12 messages). Did you mean Mike Cantwell or Mike Chen?"
}
```

**Implementation Notes:**

- Reactions are identified by `associated_message_type != 0` in the message table
- Reactions should be attached to their parent message, not returned as separate entries
- Link extraction uses regex on message text: `https?://[^\s]+`
- "is_me" determination uses `is_from_me` column
- Unknown participants (not in contacts) should have `name: null` and `handle_formatted` with pretty phone number
- **Text extraction:** Check `text` column first; if NULL, parse `attributedBody` blob (see Appendix E)

---

### Tool 3: `get_context`

**Purpose:** Retrieve messages surrounding a specific message or search match.

**Why this tool exists:** Users often want to understand the context around something - "what led to that?" or "did they respond?". This tool provides a window of messages before and after a reference point.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `message_id` | string | No* | Specific message to get context around |
| `chat_id` | string | No* | Chat to search in (required if using `contains`) |
| `contains` | string | No* | Find message containing this text, then get context |
| `before` | integer | No | Number of messages before the target (default: 5) |
| `after` | integer | No | Number of messages after the target (default: 10) |

***Either `message_id` OR (`chat_id` + `contains`) must be provided.**

**Response Schema:**

```json
{
  "target_message": {
    "id": "msg_abc123",
    "timestamp": "2026-01-15T22:52:59Z",
    "from": {"name": "Rob Dezendorf", "is_me": true},
    "text": "what's the actual total cost we have to get it down to?"
  },
  "before": [
    {
      "id": "msg_prev1",
      "timestamp": "2026-01-15T22:48:00Z",
      "from": {"name": "Nick Gallo", "is_me": false},
      "text": "but we can run a model local"
    }
  ],
  "after": [
    {
      "id": "msg_next1",
      "timestamp": "2026-01-15T22:53:38Z",
      "from": {"name": "Nick Gallo", "is_me": false},
      "text": "30 max"
    },
    {
      "id": "msg_next2",
      "timestamp": "2026-01-15T22:53:51Z",
      "from": {"name": "Nick Gallo", "is_me": false},
      "text": "for 1m"
    }
  ],
  "chat": {
    "chat_id": "chat855623491322171828",
    "display_name": "Nick & Andrew"
  }
}
```

**Use Cases:**

- "Did she respond to my question about dinner?" → find the dinner question, show messages after
- "What were we talking about before the budget came up?" → find budget mention, show messages before
- "Show me the context around that link I sent" → find link, show surrounding conversation

---

### Tool 4: `search`

**Purpose:** Full-text search across messages with advanced filtering.

**Why this tool exists:** The existing search tools either search all messages without filters, or filter by person without content search. This tool enables compound queries that match how users actually think.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `query` | string | Yes | Text to search for |
| `from` | string | No | Filter to messages from this person |
| `in_chat` | string | No | Chat ID or participant list to search within |
| `is_group` | boolean | No | Filter by chat type: true = groups only, false = DMs only, null = both |
| `has` | string | No | Content type filter: "link", "image", "video", "attachment" |
| `since` | string | No | Time bound (ISO, relative, or natural) |
| `before` | string | No | Upper time bound |
| `not_from` | string | No | Exclude messages from this person |
| `not_in_chat` | string | No | Exclude messages from this chat |
| `limit` | integer | No | Max results (default: 20) |
| `sort` | string | No | "recent_first" (default), "oldest_first", "relevance" |
| `format` | string | No | "flat" (default) or "grouped_by_chat" |
| `include_context` | boolean | No | Include 2 messages before/after each result (default: false) |
| `cursor` | string | No | Pagination cursor from previous response |

**Response Schema (flat format):**

```json
{
  "results": [
    {
      "message": {
        "id": "msg_abc123",
        "timestamp": "2026-01-15T22:57:02Z",
        "timestamp_relative": "15 hours ago",
        "from": {"name": "Nick Gallo", "in_contacts": true, "is_me": false},
        "text": "for engineering + 1m calls we should hit: $30k",
        "extracted_links": [],
        "attachments": []
      },
      "chat": {
        "chat_id": "chat855623491322171828",
        "display_name": null,
        "display_name_generated": "Nick & Andrew",
        "participants": [
          {"name": "Nick Gallo", "in_contacts": true},
          {"name": "Andrew Watts", "in_contacts": true}
        ],
        "is_group": true
      },
      "match_highlights": ["$30k"]
    }
  ],
  "total_matches": 7,
  "has_more": false,
  "next_cursor": null
}
```

**Response Schema (grouped_by_chat format):**

Essential for queries like "Find all group chats where we discussed the Anthropic project":

```json
{
  "results_by_chat": [
    {
      "chat": {
        "chat_id": "chat22260148430139505",
        "display_name": "Loop",
        "display_name_generated": null,
        "is_group": true,
        "participant_count": 8
      },
      "match_count": 34,
      "date_range": {
        "first_mention": "2025-11-15T14:22:00Z",
        "last_mention": "2026-01-14T18:45:00Z"
      },
      "sample_messages": [
        {
          "id": "msg_xyz789",
          "text": "The Anthropic video series is looking great",
          "from": {"name": "Nick Gallo"},
          "timestamp": "2026-01-14T18:45:00Z",
          "timestamp_relative": "2 days ago"
        },
        {
          "id": "msg_xyz790",
          "text": "Can we schedule the Anthropic review for Thursday?",
          "from": {"name": "Andrew Watts"},
          "timestamp": "2026-01-10T09:30:00Z",
          "timestamp_relative": "6 days ago"
        }
      ],
      "participants_who_mentioned": [
        {"name": "Nick Gallo", "mention_count": 18},
        {"name": "Andrew Watts", "mention_count": 12},
        {"name": "Rob Dezendorf", "mention_count": 4}
      ]
    },
    {
      "chat": {
        "chat_id": "chat855623491322171828",
        "display_name": null,
        "display_name_generated": "Nick & Andrew",
        "is_group": true,
        "participant_count": 3
      },
      "match_count": 12,
      "date_range": {...},
      "sample_messages": [...],
      "participants_who_mentioned": [...]
    }
  ],
  "total_matches": 54,
  "total_chats_with_matches": 3,
  "query": "Anthropic",
  "has_more": false,
  "next_cursor": null
}
```

**Search Behavior:**

- Default sort is recency-weighted: recent matches rank higher than old ones
- Exact phrase matching when query is in quotes
- Partial word matching by default (e.g., "budget" matches "budgeting")
- `match_highlights` shows which parts of the message matched
- `grouped_by_chat` format includes sample messages and participation breakdown

**Common Query Patterns:**

| User Request | Tool Parameters |
|--------------|-----------------|
| "What did Nick say about the budget?" | `query: "budget", from: "Nick"` |
| "Find links I sent last week" | `query: "*", from: "me", has: "link", since: "7d"` |
| "Search for ElevenLabs but not in the Loop chat" | `query: "ElevenLabs", not_in_chat: "Loop"` |
| "Find all group chats discussing Anthropic" | `query: "Anthropic", is_group: true, format: "grouped_by_chat"` |

---

### Tool 5: `list_chats`

**Purpose:** Browse recent or active chats with previews.

**Why this tool exists:** Sometimes the user wants to see what conversations exist before diving into one. This provides an overview without the noise of individual messages.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `limit` | integer | No | Max chats to return (default: 20) |
| `since` | string | No | Only chats with activity since this time |
| `is_group` | boolean | No | true = groups only, false = DMs only, null = both |
| `min_participants` | integer | No | Filter to chats with at least N participants |
| `max_participants` | integer | No | Filter to chats with at most N participants |
| `has_unknown_participants` | boolean | No | Filter to chats with numbers not in contacts |
| `sort` | string | No | "recent" (default), "most_active", "alphabetical" |
| `cursor` | string | No | Pagination cursor from previous response |

**Response Schema:**

```json
{
  "chats": [
    {
      "chat_id": "chat855623491322171828",
      "display_name": null,
      "display_name_generated": "Nick & Andrew",
      "participants": [
        {"name": "Nick Gallo", "handle": "+19176122942", "in_contacts": true},
        {"name": "Andrew Watts", "handle": "+15626886330", "in_contacts": true}
      ],
      "is_group": true,
      "participant_count": 3,
      "unknown_participant_count": 0,
      "last_message": {
        "timestamp": "2026-01-16T02:30:38Z",
        "timestamp_relative": "10 hours ago",
        "preview": "Ok so entertain this for me...",
        "from": "Nick Gallo"
      },
      "unread_count": 0,
      "message_count_24h": 15,
      "message_count_7d": 89,
      "user_joined_at": "2025-06-15T10:30:00Z"
    },
    {
      "chat_id": "chat_sukhmani",
      "display_name": null,
      "display_name_generated": "Sukhmani Kular",
      "participants": [
        {"name": "Sukhmani Kular", "handle": "+1xxxxxxxxxx", "in_contacts": true}
      ],
      "is_group": false,
      "participant_count": 2,
      "unknown_participant_count": 0,
      "last_message": {
        "timestamp": "2026-01-15T22:41:08Z",
        "timestamp_relative": "14 hours ago",
        "preview": "Why don't I make us soup dumplings",
        "from": "Sukhmani Kular"
      },
      "unread_count": 0,
      "message_count_24h": 8,
      "message_count_7d": 156,
      "user_joined_at": null
    },
    {
      "chat_id": "chat765432109876543210",
      "display_name": null,
      "display_name_generated": "Mike, +1 (702) 555-1234, +1 (415) 555-9876",
      "participants": [
        {"name": "Mike Cantwell", "handle": "+15162507668", "in_contacts": true},
        {"name": null, "handle": "+17025551234", "handle_formatted": "+1 (702) 555-1234", "in_contacts": false},
        {"name": null, "handle": "+14155559876", "handle_formatted": "+1 (415) 555-9876", "in_contacts": false}
      ],
      "is_group": true,
      "participant_count": 4,
      "unknown_participant_count": 2,
      "last_message": {
        "timestamp": "2026-01-10T18:30:00Z",
        "timestamp_relative": "6 days ago",
        "preview": "Flight lands at 3pm",
        "from": "+1 (702) 555-1234"
      },
      "unread_count": 0,
      "message_count_24h": 0,
      "message_count_7d": 23,
      "user_joined_at": "2025-12-20T09:00:00Z"
    }
  ],
  "total_chats": 156,
  "total_group_chats": 34,
  "total_dms": 122,
  "has_more": true,
  "next_cursor": "cursor_abc123"
}
```

**Filtering Use Cases:**

- `is_group: true` → Show only group chats
- `min_participants: 5` → Show large group chats
- `has_unknown_participants: true` → Show chats with phone numbers not in contacts (useful for identifying who unknown numbers are)

---

### Tool 6: `send`

**Purpose:** Send a message to a person or group chat.

**Why this tool exists:** The existing Python MCP handles this well. We preserve the functionality with minor improvements.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `to` | string | Yes* | Contact name, phone number, or email |
| `chat_id` | string | Yes* | Existing chat ID (for group chats or when `to` is ambiguous) |
| `text` | string | Yes | Message content |
| `reply_to` | string | No | Message ID to reply to (creates threaded reply on supported platforms) |

***Either `to` or `chat_id` must be provided.**

**Response Schema:**

```json
{
  "success": true,
  "message_id": "msg_new123",
  "chat_id": "chat855623491322171828",
  "timestamp": "2026-01-16T12:45:00Z",
  "delivered_to": ["Nick Gallo", "Andrew Watts"]
}
```

**Disambiguation:**

If `to` matches multiple contacts:

```json
{
  "success": false,
  "error": "ambiguous_recipient",
  "candidates": [
    {"name": "Nick Gallo", "handle": "+19176122942", "last_contact": "2 hours ago"},
    {"name": "Nick DePalma", "handle": "+15551234567", "last_contact": "3 months ago"}
  ]
}
```

**Security Note:** All inputs to AppleScript must be sanitized to prevent injection attacks. Special characters, quotes, and backslashes must be properly escaped.

---

### Tool 7: `get_active_conversations`

**Purpose:** Find conversations with recent bidirectional activity (actual back-and-forth, not just received messages).

**Why this tool exists:** Users often want to know "what conversations am I actively in?" or "continue where we left off." This is different from list_chats sorted by recency—it specifically identifies conversations with engaged dialogue.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `hours` | integer | No | Time window to consider (default: 24) |
| `min_exchanges` | integer | No | Minimum back-and-forth exchanges to qualify (default: 2) |
| `is_group` | boolean | No | true = groups only, false = DMs only, null = both |
| `cursor` | string | No | Pagination cursor from previous response |

**Response Schema:**

```json
{
  "active_conversations": [
    {
      "chat_id": "chat855623491322171828",
      "display_name": null,
      "display_name_generated": "Nick & Andrew",
      "participants": [...],
      "activity_summary": {
        "exchanges_in_window": 8,
        "my_messages": 5,
        "their_messages": 12,
        "last_message_from_me": "2026-01-16T02:15:00Z",
        "last_message_from_them": "2026-01-16T02:30:38Z",
        "conversation_started": "2026-01-15T22:00:00Z"
      },
      "awaiting_my_reply": true
    }
  ],
  "total_active": 3,
  "window_hours": 24,
  "has_more": false,
  "next_cursor": null
}
```

**Key Fields:**

- `exchanges_in_window`: Number of back-and-forth message pairs
- `awaiting_my_reply`: True if the last message was from them (I should respond)

**Use Cases:**

- "What conversations need my attention?" → `get_active_conversations(hours=24)` + filter `awaiting_my_reply: true`
- "Continue where we left off with Nick" → Find Nick's chat in active conversations, get recent messages

---

### Tool 8: `list_attachments`

**Purpose:** Retrieve attachments with metadata, optionally filtered by chat, type, or time.

**Why this tool exists:** Users often think attachment-first: "find that PDF Nick sent" or "show me photos from the Vegas chat." Filtering messages by `has: "attachment"` works but returns full message objects when users just want the attachment list.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `chat_id` | string | No | Filter to specific chat |
| `from` | string | No | Filter to attachments from specific person |
| `type` | string | No | Filter by type: "image", "video", "audio", "pdf", "document", "link", "any" |
| `since` | string | No | Time bound (ISO, relative, or natural) |
| `before` | string | No | Upper time bound |
| `limit` | integer | No | Max results (default: 50) |
| `sort` | string | No | "recent_first" (default), "oldest_first", "largest_first" |
| `cursor` | string | No | Pagination cursor from previous response |

**Response Schema:**

```json
{
  "attachments": [
    {
      "attachment_id": "att_abc123",
      "type": "image",
      "mime_type": "image/jpeg",
      "filename": "IMG_4523.jpg",
      "file_size_bytes": 2458624,
      "file_size_human": "2.3 MB",
      "timestamp": "2026-01-10T18:30:00Z",
      "timestamp_relative": "6 days ago",
      "from": {
        "name": "Mike Cantwell",
        "handle": "+15162507668",
        "is_me": false
      },
      "chat": {
        "chat_id": "chat765432109876543210",
        "display_name_generated": "Vegas Trip"
      },
      "parent_message": {
        "id": "msg_xyz789",
        "text": "Check out this view from the hotel!",
        "preview": true
      }
    },
    {
      "attachment_id": "att_def456",
      "type": "link",
      "url": "https://fish.audio/pricing",
      "domain": "fish.audio",
      "title": "Fish Audio - Pricing",
      "timestamp": "2026-01-14T16:45:00Z",
      "timestamp_relative": "2 days ago",
      "from": {
        "name": "Nick Gallo",
        "is_me": false
      },
      "chat": {
        "chat_id": "chat855623491322171828",
        "display_name_generated": "Nick & Andrew"
      },
      "parent_message": {
        "id": "msg_abc999",
        "text": "Check out Fish Audio - way cheaper than ElevenLabs",
        "preview": true
      }
    }
  ],
  "total_count": 127,
  "has_more": true,
  "next_cursor": "cursor_att_789"
}
```

**Note:** The `local_path` field has been removed for security reasons. Use `attachment_id` as an opaque identifier.

**Link Handling:**

Links are treated as a type of attachment with additional metadata:
- `url`: Full URL
- `domain`: Extracted domain for easy identification
- `title`: Page title if available (from link preview)

**Use Cases:**

- "Find that PDF Nick sent" → `list_attachments(from="Nick", type="pdf")`
- "Show me photos from Vegas chat" → `list_attachments(chat_id="...", type="image")`
- "What links did I share last week?" → `list_attachments(from="me", type="link", since="7d")`

---

### Tool 9: `get_unread`

**Purpose:** Get all unread messages across chats, or unread count summary.

**Why this tool exists:** Users ask "do I have any unread messages?" or "what did I miss?" This is faster than scanning list_chats for unread_count > 0.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `chat_id` | string | No | Filter to specific chat (omit for all chats) |
| `format` | string | No | "messages" (default) or "summary" |
| `limit` | integer | No | Max messages to return in "messages" format (default: 50) |
| `cursor` | string | No | Pagination cursor from previous response |

**Response Schema (messages format):**

```json
{
  "unread_messages": [
    {
      "message": {
        "id": "msg_unread1",
        "timestamp": "2026-01-16T10:30:00Z",
        "timestamp_relative": "2 hours ago",
        "from": {"name": "Sukhmani Kular", "is_me": false},
        "text": "Don't forget we have dinner reservations at 7!"
      },
      "chat": {
        "chat_id": "chat_sukhmani",
        "display_name_generated": "Sukhmani Kular",
        "is_group": false
      }
    }
  ],
  "total_unread": 3,
  "chats_with_unread": 2,
  "has_more": false,
  "next_cursor": null
}
```

**Response Schema (summary format):**

```json
{
  "summary": {
    "total_unread": 15,
    "chats_with_unread": 4,
    "breakdown": [
      {"chat_display": "Loop", "unread_count": 8, "oldest_unread": "3 hours ago"},
      {"chat_display": "Sukhmani Kular", "unread_count": 3, "oldest_unread": "2 hours ago"},
      {"chat_display": "Nick & Andrew", "unread_count": 3, "oldest_unread": "1 hour ago"},
      {"chat_display": "Mom", "unread_count": 1, "oldest_unread": "30 minutes ago"}
    ]
  }
}
```

---

### Enhanced Filter: `from: "me"` and Unanswered Messages

Across all retrieval tools (`get_messages`, `search`, `list_attachments`), the `from` parameter accepts the special value `"me"` to filter to messages sent by the current user.

**Additional parameter for get_messages and search:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `unanswered` | boolean | No | Only return messages from me that didn't receive a reply within 24h |

**Use Cases:**

- "What did I tell Nick about the deadline?" → `get_messages(chat_id="...", from="me", contains="deadline")`
- "Find promises I made last week" → `search(query="I will|I'll|I promise", from="me", since="7d")`
- "What questions did I ask that weren't answered?" → `search(query="?", from="me", unanswered=true)`

**Unanswered Logic:**

A message is considered "unanswered" if:
1. It's from me (`is_from_me = 1`)
2. No message from another participant follows within 24 hours
3. The message appears to expect a response (contains question mark, or ends with a question pattern)

---

### Enhanced Response: Conversation Sessions

When `get_messages` returns a sequence of messages, it now includes **session boundaries** to help identify natural conversation breaks.

**Session Detection Logic:**

A new session starts when there's a gap of 4+ hours between messages.

**Enhanced Message Response:**

```json
{
  "messages": [
    {
      "id": "msg_1",
      "timestamp": "2026-01-16T02:30:38Z",
      "session_id": "session_3",
      "session_start": false,
      "text": "..."
    },
    {
      "id": "msg_2",
      "timestamp": "2026-01-15T18:00:00Z",
      "session_id": "session_2",
      "session_start": true,
      "session_gap_hours": 6.5,
      "text": "..."
    }
  ],
  "sessions": [
    {"session_id": "session_3", "started": "2026-01-16T01:00:00Z", "message_count": 15},
    {"session_id": "session_2", "started": "2026-01-15T18:00:00Z", "message_count": 8},
    {"session_id": "session_1", "started": "2026-01-15T10:00:00Z", "message_count": 23}
  ]
}
```

**Use Cases:**

- "What were we talking about in our last conversation?" → Get messages, filter to most recent session_id
- "The conversation before that" → Filter to session_id - 1

**Additional parameter for get_messages:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `session` | string | No | Filter to specific session ID |

---

### Enhanced Error Responses: Smart Suggestions

When queries return no results, the response includes contextual suggestions:

**No chat found:**
```json
{
  "chats": [],
  "suggestions": {
    "similar_names": [
      {"name": "Tahoe 2026", "similarity": "high", "note": "Renamed from 'Ski Trip' 3 weeks ago"}
    ],
    "by_participants": [
      {"display_name_generated": "Nick & Andrew", "note": "Contains Nick Gallo - did you mean this chat?"}
    ],
    "by_content": [
      {"display_name": "Loop", "note": "Found 12 messages mentioning 'ski trip'"}
    ]
  }
}
```

**No messages found:**
```json
{
  "messages": [],
  "suggestions": {
    "expanded_time": {
      "original": "last 24 hours",
      "expanded": "last 7 days",
      "would_find": 15
    },
    "similar_query": {
      "original": "Michael",
      "suggestion": "Mike",
      "would_find": 47,
      "note": "No 'Michael' in contacts, but found 'Mike Cantwell'"
    },
    "other_chats": [
      {"chat": "Loop", "match_count": 8, "note": "Found matches in different chat"}
    ]
  }
}
```

**Suggestion Types:**

1. `expanded_time`: What you'd find with a wider time range
2. `similar_query`: Spelling corrections or nickname matches
3. `similar_names`: Fuzzy name matches for chat/contact lookup
4. `other_chats`: Results exist but in different chats
5. `renamed_chat`: Chat was renamed, suggesting old→new name mapping

---

## Token Efficiency

### Design Principles

All response schemas are optimized for token efficiency without sacrificing usefulness:

1. **Deduplicate** - Participants defined once per response, referenced by short ID
2. **Smart timestamps** - ISO for messages (AI needs to reason about time), relative for summaries (human readability)
3. **Short keys** - `ts` not `timestamp`, `ago` not `timestamp_relative`, `msg` not `message_count`
4. **Omit obvious fields** - Don't include `is_group: false` on 2-person chats, don't include `in_contacts: true` on resolved names
5. **Inline context** - Reactions as `["❤️ andrew"]` not nested objects

### Efficient Response Schemas

**find_chat:**
```json
{
  "chats": [
    {
      "id": "chat855623491322171828",
      "name": "Nick & Andrew",
      "participants": [
        {"name": "Nick Gallo", "msgs": 234, "last": "2h ago"},
        {"name": "Andrew Watts", "msgs": 189, "last": "10h ago"},
        {"+1 (702) 555-1234": {"msgs": 12, "last": "3d ago"}}
      ],
      "group": true,
      "last": {"from": "Nick Gallo", "text": "Ok so entertain this for me...", "ago": "2h"},
      "unread": 0,
      "joined": "2025-06-15T10:30:00Z",
      "msgs_before_join": 1247,
      "match": "participants"
    }
  ],
  "more": false,
  "cursor": null
}
```

Notes:
- `name` is always the resolved/generated display name (no separate fields)
- Unknown numbers use formatted number as the key (self-documenting)
- `match` explains why this chat was returned
- `joined` + `msgs_before_join` only included for group chats user was added to

**get_messages:**
```json
{
  "chat": {"id": "chat855623491322171828", "name": "Nick & Andrew"},
  "people": {
    "nick": "Nick Gallo",
    "andrew": "Andrew Watts",
    "me": "Rob Dezendorf",
    "unknown1": "+1 (702) 555-1234"
  },
  "messages": [
    {"id": "msg_abc", "from": "nick", "ts": "2026-01-16T02:30:38Z", "text": "Ok so entertain this for me...", "reactions": ["❤️ andrew"]},
    {"id": "msg_def", "from": "nick", "ts": "2026-01-16T02:28:00Z", "text": "for engineering + 1m calls: $30k"},
    {"id": "msg_ghi", "from": "me", "ts": "2026-01-16T02:25:00Z", "text": "that works within budget"}
  ],
  "sessions": [
    {"id": "s1", "start": "2026-01-16T01:00:00Z", "msgs": 15}
  ],
  "more": true,
  "cursor": "abc123"
}
```

Notes:
- `people` map defined once, messages reference by short key
- `"me"` is always the current user (no `is_me` field needed)
- Unknown participants keyed as `unknown1`, `unknown2` with formatted number as value
- ISO timestamps on messages for AI temporal reasoning
- Sessions included when relevant (gaps > 4h)
- Reactions as compact strings: `["❤️ andrew", "😂 nick"]`

### Token Estimates

| Response Type | Estimated Tokens |
|---------------|------------------|
| find_chat (1 result, 3 participants) | ~150 |
| get_messages (25 messages) | ~600 |
| list_chats (10 chats) | ~400 |
| search flat (10 results) | ~350 |
| search grouped (5 chats) | ~250 |
| get_active_conversations (5 chats) | ~200 |
| list_attachments (10 items) | ~300 |
| get_unread summary (5 chats) | ~100 |

### Timestamp Rules

| Context | Format | Reasoning |
|---------|--------|-----------|
| Individual messages | ISO (`ts`) | AI needs to reason about sequences, gaps, ranges |
| Session boundaries | ISO (`start`) | AI needs to identify conversation breaks |
| Attachments | ISO (`ts`) | AI might correlate with messages |
| Chat list previews | Relative (`ago`) | Human readability, display only |
| Unread summaries | Relative (`oldest`) | Human readability, display only |
| Active conversation last | ISO (`last_ts`) | AI might need to compare recency |

---

## Technical Architecture

### Data Flow

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│                 │     │                 │     │                 │
│  Claude/AI      │◄───►│  iMessage MCP   │◄───►│  chat.db        │
│  Assistant      │     │  Server         │     │  (SQLite)       │
│                 │     │                 │     │                 │
└─────────────────┘     └────────┬────────┘     └─────────────────┘
                                 │
                                 ▼
                        ┌─────────────────┐
                        │                 │
                        │  CNContactStore │
                        │  (Contacts.app) │
                        │                 │
                        └─────────────────┘
```

### Database Schema Reference

**Key Tables:**

```sql
-- Chats (conversations)
chat (
  ROWID,
  guid,              -- e.g., "iMessage;+;chat855623491322171828"
  display_name,      -- nullable, often empty for group chats
  service_name       -- "iMessage", "SMS", "RCS"
)

-- Messages
message (
  ROWID,
  guid,
  text,                       -- May be NULL if content is in attributedBody
  attributedBody,             -- BLOB: typedstream format (see Appendix E)
  handle_id,                  -- FK to handle.ROWID
  date,                       -- Apple epoch (nanoseconds since 2001-01-01)
  date_read,                  -- When message was read
  date_delivered,             -- When message was delivered
  date_edited,                -- When message was edited (macOS 13+)
  date_retracted,             -- When message was unsent (macOS 13+)
  is_from_me,
  associated_message_type,    -- 0 = normal, 2000+ = reactions (see Appendix A)
  associated_message_guid,    -- for reactions, points to original
  associated_message_emoji,   -- Custom emoji for types 2006/2007 (iOS 18+)
  cache_has_attachments,
  thread_originator_guid,     -- For threaded replies
  schedule_type,              -- Scheduled message type (iOS 18+)
  schedule_state              -- Scheduled message state (iOS 18+)
)

-- Handles (phone numbers, emails)
handle (
  ROWID,
  id,                -- e.g., "+19176122942" (E.164 format)
  service            -- "iMessage", "SMS", "RCS"
)

-- Join tables
chat_handle_join (chat_id, handle_id)
chat_message_join (chat_id, message_id)

-- Attachments
attachment (
  ROWID,
  guid,
  filename,
  mime_type,
  total_bytes,
  transfer_name
)

message_attachment_join (message_id, attachment_id)
```

**Service Types:**

| Service | Description |
|---------|-------------|
| `iMessage` | Apple's encrypted messaging |
| `SMS` | Traditional SMS/MMS |
| `RCS` | Rich Communication Services (iOS 18+) |

### Critical SQL Queries

**Find chat by participants:**

```sql
SELECT c.ROWID, c.guid, c.display_name,
       GROUP_CONCAT(h.id) as participants
FROM chat c
JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
JOIN handle h ON chj.handle_id = h.ROWID
WHERE c.ROWID IN (
  -- Subquery: chats that contain ALL specified handles
  SELECT chat_id FROM chat_handle_join chj2
  JOIN handle h2 ON chj2.handle_id = h2.ROWID
  WHERE h2.id IN ('+19176122942', '+15626886330')
  GROUP BY chat_id
  HAVING COUNT(DISTINCT h2.id) = 2
)
GROUP BY c.ROWID;
```

**Get messages with resolved names and reactions:**

```sql
WITH reactions AS (
  SELECT
    associated_message_guid,
    GROUP_CONCAT(
      CASE associated_message_type
        WHEN 2000 THEN 'loved'
        WHEN 2001 THEN 'liked'
        WHEN 2002 THEN 'disliked'
        WHEN 2003 THEN 'laughed'
        WHEN 2004 THEN 'emphasized'
        WHEN 2005 THEN 'questioned'
        WHEN 2006 THEN 'custom:' || COALESCE(associated_message_emoji, '?')
        WHEN 2007 THEN 'custom:' || COALESCE(associated_message_emoji, '?')
      END || ':' || handle_id
    ) as reaction_data
  FROM message
  WHERE associated_message_type >= 2000 AND associated_message_type < 3000
  GROUP BY associated_message_guid
)
SELECT
  m.ROWID,
  m.guid,
  m.text,
  m.attributedBody,
  m.date,
  m.is_from_me,
  h.id as sender_handle,
  r.reaction_data
FROM message m
JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
LEFT JOIN handle h ON m.handle_id = h.ROWID
LEFT JOIN reactions r ON m.guid = r.associated_message_guid
WHERE cmj.chat_id = ?
  AND m.associated_message_type = 0  -- Exclude reactions as separate rows
ORDER BY m.date DESC
LIMIT ?;
```

**Get user join date for a chat:**

```sql
-- Method 1: First message sent by user in chat (approximate join date)
SELECT MIN(m.date) as user_first_message
FROM message m
JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
WHERE cmj.chat_id = ?
  AND m.is_from_me = 1;

-- Method 2: Count messages before user's first message (messages user missed)
SELECT COUNT(*) as messages_before_join
FROM message m
JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
WHERE cmj.chat_id = ?
  AND m.date < (
    SELECT MIN(m2.date)
    FROM message m2
    JOIN chat_message_join cmj2 ON m2.ROWID = cmj2.message_id
    WHERE cmj2.chat_id = ? AND m2.is_from_me = 1
  )
  AND m.associated_message_type = 0;
```

**Generate display name for unnamed chats:**

```sql
-- Get all participants for a chat, ordered by message count (most active first)
SELECT
  h.id as handle,
  COUNT(m.ROWID) as message_count
FROM chat_handle_join chj
JOIN handle h ON chj.handle_id = h.ROWID
LEFT JOIN message m ON m.handle_id = h.ROWID
WHERE chj.chat_id = ?
GROUP BY h.id
ORDER BY message_count DESC;
```

Then in Python, resolve handles to contact names and format:
```python
def generate_display_name(participants: list[dict], max_names: int = 3) -> str:
    """Generate display name like Messages.app does for unnamed chats."""
    names = []
    for p in participants[:max_names]:
        if p.get('name'):
            names.append(p['name'].split()[0])  # First name only
        else:
            names.append(format_phone(p['handle']))  # +1 (702) 555-1234

    if len(participants) > max_names:
        remaining = len(participants) - max_names
        return f"{', '.join(names)} and {remaining} others"
    return ', '.join(names)
```

### Contact Resolution

Integrate with macOS Contacts via **CNContactStore** (the only reliable approach):

```python
from Contacts import (
    CNContactStore, CNContactFetchRequest,
    CNContactGivenNameKey, CNContactFamilyNameKey,
    CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
    CNContactIdentifierKey, CNEntityTypeContacts
)

def build_contact_lookup() -> dict[str, str]:
    """Build phone/email -> name lookup table from Contacts."""
    store = CNContactStore.new()

    # Check authorization
    auth_status = CNContactStore.authorizationStatusForEntityType_(CNEntityTypeContacts)
    if auth_status != 3:  # CNAuthorizationStatusAuthorized
        # Request access - NOTE: prompt won't appear in VS Code terminal
        # User must run from Terminal.app for first authorization
        store.requestAccessForEntityType_completionHandler_(
            CNEntityTypeContacts, lambda granted, error: None
        )
        return {}

    keys_to_fetch = [
        CNContactIdentifierKey,
        CNContactGivenNameKey,
        CNContactFamilyNameKey,
        CNContactPhoneNumbersKey,
        CNContactEmailAddressesKey
    ]

    fetch_request = CNContactFetchRequest.alloc().initWithKeysToFetch_(keys_to_fetch)
    lookup = {}

    def process_contact(contact, stop):
        name = f"{contact.givenName()} {contact.familyName()}".strip()
        if not name:
            return

        # Index by phone numbers (normalized to E.164)
        for phone in contact.phoneNumbers():
            number = phone.value().stringValue()
            normalized = normalize_to_e164(number)
            if normalized:
                lookup[normalized] = name

        # Index by email addresses
        for email in contact.emailAddresses():
            addr = email.value().lower()
            lookup[addr] = name

    store.enumerateContactsWithFetchRequest_error_usingBlock_(
        fetch_request, None, process_contact
    )

    return lookup
```

**Important:** The AddressBook SQLite database (`~/Library/Application Support/AddressBook/AddressBook-v22.abcddb`) is NOT reliable for contact resolution - iCloud contacts are not stored locally in this database. Always use CNContactStore.

### Phone Number Normalization

iMessage stores handles in E.164 format. Use the `phonenumbers` library for normalization:

```python
import phonenumbers
from phonenumbers import PhoneNumberFormat

def normalize_to_e164(raw_number: str, region: str = "US") -> str | None:
    """Normalize phone number to E.164 format for handle matching."""
    try:
        parsed = phonenumbers.parse(raw_number, region)
        if phonenumbers.is_valid_number(parsed):
            return phonenumbers.format_number(parsed, PhoneNumberFormat.E164)
    except phonenumbers.NumberParseException:
        pass
    return None

def format_phone_display(e164: str) -> str:
    """Format E.164 number for human-readable display."""
    try:
        parsed = phonenumbers.parse(e164)
        return phonenumbers.format_number(parsed, PhoneNumberFormat.NATIONAL)
    except:
        return e164
```

### Connection Management

**Best Practice:** Open connections briefly, execute query, close immediately. Use read-only mode and appropriate timeouts:

```python
import sqlite3
import os
from contextlib import contextmanager

DB_PATH = os.path.expanduser("~/Library/Messages/chat.db")

@contextmanager
def get_db_connection():
    """
    Open connection in read-only mode, execute query, close immediately.
    Uses URI mode for read-only access and appropriate timeouts.
    """
    # Use URI mode with read-only flag
    conn = sqlite3.connect(
        f"file:{DB_PATH}?mode=ro",
        uri=True,
        timeout=5.0  # 5 second timeout
    )
    conn.row_factory = sqlite3.Row

    # Additional safety pragmas
    conn.execute("PRAGMA query_only = ON")
    conn.execute("PRAGMA busy_timeout = 1000")  # 1 second lock timeout

    try:
        yield conn
    finally:
        conn.close()  # Always close after each query

# Usage:
def get_messages(chat_id: str, limit: int = 50):
    with get_db_connection() as conn:
        cursor = conn.execute(MESSAGES_QUERY, (chat_id, limit))
        return [dict(row) for row in cursor.fetchall()]
```

**Additional Mitigations:**

- Use `mode=ro` (read-only) in connection URI
- Set `timeout=5.0` to fail fast if database is locked
- Implement retry logic with exponential backoff for lock contention
- Close connections immediately after each query batch

### Schema Version Detection

The database schema has evolved across macOS versions. Detect available columns at startup:

```python
def detect_schema_capabilities(conn) -> dict:
    """Detect which columns/features are available in this database."""
    capabilities = {
        'has_date_edited': False,
        'has_date_retracted': False,
        'has_thread_originator': False,
        'has_associated_emoji': False,
        'has_schedule_fields': False,
    }

    cursor = conn.execute("PRAGMA table_info(message)")
    columns = {row['name'] for row in cursor.fetchall()}

    capabilities['has_date_edited'] = 'date_edited' in columns
    capabilities['has_date_retracted'] = 'date_retracted' in columns
    capabilities['has_thread_originator'] = 'thread_originator_guid' in columns
    capabilities['has_associated_emoji'] = 'associated_message_emoji' in columns
    capabilities['has_schedule_fields'] = 'schedule_type' in columns

    return capabilities
```

---

## Implementation Plan

### Phase 1: Core Infrastructure (Week 1)

- [ ] Set up FastMCP Python project structure
- [ ] Pin dependencies: `fastmcp<3`, `pyobjc-framework-Contacts>=12.1`, `phonenumbers>=8.13`
- [ ] Implement database connection manager with safe patterns
- [ ] Implement CNContactStore integration for contact resolution
- [ ] Create phone → name cache with TTL
- [ ] Build core SQL query library
- [ ] Implement phone number normalization (E.164)
- [ ] Implement schema version detection
- [ ] Implement attributedBody parsing (see Appendix E)

### Phase 2: Core Read Tools (Week 2)

- [ ] Implement `find_chat` with cascading match strategies
- [ ] Implement `get_messages` with all filters and disambiguation
- [ ] Implement `list_chats` with sorting and filtering options
- [ ] Add reaction collapsing logic (including custom emoji types)
- [ ] Add link/attachment extraction
- [ ] Implement display_name_generated logic
- [ ] Add user join date tracking (approximation)

### Phase 3a: Search Tool (Week 3)

- [ ] Implement `search` with compound filters
- [ ] Implement flat format
- [ ] Implement grouped_by_chat format
- [ ] Add include_context option
- [ ] Performance optimization (query planning)

### Phase 3b: Advanced Read Tools (Week 4)

- [ ] Implement `get_context` for surrounding messages
- [ ] Implement `get_active_conversations` with bidirectional activity detection
- [ ] Implement `list_attachments` with type filtering
- [ ] Implement `get_unread` with summary format
- [ ] Add conversation session detection

### Phase 4a: Write & Filter Enhancements (Week 5)

- [ ] Implement `send` with AppleScript/JXA backend
- [ ] Add input sanitization for AppleScript injection prevention
- [ ] Implement `from: "me"` filter across all tools
- [ ] Implement `unanswered: true` detection logic
- [ ] Implement session parameter for get_messages

### Phase 4b: Polish & Testing (Week 6)

- [ ] Implement smart error suggestions system
- [ ] Add comprehensive error handling and error response schema
- [ ] Write unit tests with mock database
- [ ] Write integration tests against real chat.db
- [ ] Documentation and example usage
- [ ] Package for distribution

---

## Testing Strategy

### Unit Tests

- SQL query correctness with mock database
- Contact resolution edge cases (international numbers, emails)
- Time parsing ("yesterday", "2 hours ago", ISO formats)
- Reaction type mapping (including custom emoji)
- attributedBody parsing edge cases
- Phone number normalization

### Integration Tests

- End-to-end tool calls against real (or sanitized copy of) chat.db
- Participant matching accuracy
- Message retrieval completeness
- Connection lifecycle (no leaked handles)
- CNContactStore authorization flow

### Stress Tests

- Large result sets (chats with 10,000+ messages)
- Rapid sequential queries (connection management)
- Full contact list resolution performance

### Compatibility Tests

- macOS Ventura (13.x)
- macOS Sonoma (14.x)
- macOS Sequoia (15.x)
- macOS Tahoe (26.x)

---

## Security & Privacy Considerations

### Data Access

- MCP operates locally; no data leaves the machine
- Read-only database access by default
- Send functionality requires explicit user intent through AI interaction

### Permissions Required

- Full Disk Access (for `~/Library/Messages/chat.db`)
- Contacts access (for CNContactStore resolution)
- Automation permission for Messages.app (send functionality)

**Note:** VS Code's integrated terminal may not display permission prompts. Users should grant permissions via Terminal.app or System Preferences.

### Data Handling

- No message content is cached beyond request lifecycle
- Contact name cache stores only name ↔ handle mappings
- No telemetry or external network calls
- Attachment file paths not exposed (opaque IDs only)

### Input Sanitization

AppleScript inputs must be sanitized to prevent injection:

```python
def sanitize_for_applescript(text: str) -> str:
    """Escape special characters for AppleScript string literals."""
    return text.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
```

---

## Dependencies

```
# requirements.txt
fastmcp<3
pyobjc-framework-Contacts>=12.1
phonenumbers>=8.13
python-dateutil>=2.8
```

**Minimum Python Version:** 3.10 (PyObjC 12.x dropped Python 3.9 support)

---

## Open Questions

1. **Attachment Handling:** Should we support retrieving actual attachment files, or just metadata? Full files add complexity and storage concerns. *Current decision: Metadata only, with opaque IDs.*

2. **Message Effects:** iMessage supports effects like "slam", "loud", etc. Should these be preserved in output?

3. **Edit History:** iOS 16+ supports message editing. Should we surface edit history?

4. **Unsent Messages:** iOS 16+ allows unsending. How do we handle messages that were unsent?

5. **Focus/DND Status:** Should the MCP surface whether the user has Do Not Disturb enabled?

6. **Scheduled Messages:** iOS 18 adds scheduled sending. Should we support creating scheduled messages?

---

## Appendix A: Reaction Type Mapping

| `associated_message_type` | Reaction | Emoji |
|---------------------------|----------|-------|
| 2000 | Loved | ❤️ |
| 2001 | Liked | 👍 |
| 2002 | Disliked | 👎 |
| 2003 | Laughed | 😂 |
| 2004 | Emphasized | ‼️ |
| 2005 | Questioned | ❓ |
| 2006 | Custom Emoji Add | (see `associated_message_emoji` column) |
| 2007 | Custom Emoji Add | (see `associated_message_emoji` column) |
| 3000 | Removed love | (undo) |
| 3001 | Removed like | (undo) |
| 3002 | Removed dislike | (undo) |
| 3003 | Removed laugh | (undo) |
| 3004 | Removed emphasis | (undo) |
| 3005 | Removed question | (undo) |
| 3006 | Removed custom emoji | (undo) |
| 3007 | Removed custom emoji | (undo) |

**Custom Emoji (iOS 18+):** Types 2006/2007 use the `associated_message_emoji` column to store the actual emoji used. The distinction between 2006 and 2007 is not documented but both represent custom emoji additions.

---

## Appendix B: Apple Epoch Time Conversion

iMessage stores timestamps as nanoseconds since 2001-01-01 (Apple's "Cocoa epoch").

```python
from datetime import datetime, timezone, timedelta

APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)

def apple_to_datetime(apple_timestamp: int) -> datetime:
    """Convert Apple epoch nanoseconds to Python datetime."""
    seconds = apple_timestamp / 1_000_000_000
    return APPLE_EPOCH + timedelta(seconds=seconds)

def datetime_to_apple(dt: datetime) -> int:
    """Convert Python datetime to Apple epoch nanoseconds."""
    delta = dt - APPLE_EPOCH
    return int(delta.total_seconds() * 1_000_000_000)
```

---

## Appendix C: Example Tool Call Sequences

### Scenario: "What did Nick say about the budget yesterday?"

**Old approach (current MCPs):**
```
1. search_contacts("Nick") → 4 results
2. [AI decides which Nick based on context]
3. search_messages(handle="+19176122942", startDate="...") → 50 messages
4. [AI manually scans for "budget"]
```

**New approach:**
```
1. search(query="budget", from="Nick Gallo", since="yesterday") → 3 targeted results
```

### Scenario: "Find my group chat with Nick and Andrew" (Unnamed Group)

**Old approach:**
```
1. get_chats(limit=200) → no display_name match
2. search_contacts("Nick") → +19176122942
3. search_contacts("Andrew") → +15626886330
4. [No way to find chat containing BOTH handles]
5. search_messages across each handle, try to correlate
6. [Likely failure or wrong chat]
```

**New approach:**
```
1. find_chat(participants=["Nick Gallo", "Andrew Watts"]) → exact match with generated name
```

### Scenario: "What did Mike say in the Loop chat?" (Name Collision)

**New approach:**
```
1. get_messages(chat_id="Loop", from="Mike")
```

**Response (disambiguation):**
```json
{
  "ambiguous": true,
  "candidates": [
    {"name": "Mike Cantwell", "message_count_in_chat": 234, "last_message_time": "2 hours ago"},
    {"name": "Mike Chen", "message_count_in_chat": 12, "last_message_time": "3 days ago"}
  ],
  "suggestion": "Mike Cantwell is more active (234 vs 12 messages). Which Mike?"
}
```

---

## Appendix D: Competition Analysis

| Implementation | Send | Read | Contacts | Stars | Notes |
|---------------|------|------|----------|-------|-------|
| carterlasalle/mac_messages_mcp | ✅ | ✅ | ✅ | 220+ | Most complete, actively maintained |
| wyattjoh/imessage-mcp | ❌ | ✅ | ✅ | - | Deno/TypeScript |
| mattt/iMCP | ❌ | ✅ | ✅ | - | Native Swift, sandboxed, macOS 15.3+ |
| hannesrudolph/imessage-query-fastmcp | ❌ | ✅ | Basic | - | FastMCP example |

**Key Differentiator:** This MCP focuses on intent-aligned tools that reduce tool calls from 3-5 to 1-2 for common queries, with smart disambiguation, participant-based chat lookup, and token-efficient responses.

---

## Appendix E: attributedBody Parsing

Since macOS Ventura, message text is increasingly stored in the `attributedBody` blob rather than the `text` column. This blob uses Apple's proprietary `typedstream` binary serialization format.

**When to parse attributedBody:**
- `text` column is NULL or empty
- Message contains styled text, mentions, or rich formatting

**Basic extraction algorithm:**

```python
def extract_text_from_attributed_body(blob: bytes) -> str | None:
    """
    Extract plain text from attributedBody blob.
    This is a simplified parser for the most common cases.
    """
    if not blob:
        return None

    # Find NSString marker in typedstream
    marker = b"NSString"
    idx = blob.find(marker)
    if idx == -1:
        return None

    # Skip past marker and type info
    idx += len(marker) + 5

    # Read string length
    if idx >= len(blob):
        return None

    if blob[idx] == 0x81:
        # Multi-byte length encoding
        if idx + 3 > len(blob):
            return None
        length = int.from_bytes(blob[idx+1:idx+3], 'little')
        idx += 3
    else:
        # Single-byte length
        length = blob[idx]
        idx += 1

    # Extract string content
    if idx + length > len(blob):
        return None

    try:
        return blob[idx:idx+length].decode('utf-8')
    except UnicodeDecodeError:
        return None


def get_message_text(row: dict) -> str | None:
    """Get message text, falling back to attributedBody if needed."""
    if row.get('text'):
        return row['text']

    if row.get('attributedBody'):
        return extract_text_from_attributed_body(row['attributedBody'])

    return None
```

**Alternative libraries:**
- `imessage-exporter` (Rust) - comprehensive typedstream parser
- `imessage-parser` (Python) - pure Python implementation
- `node-typedstream` (JavaScript) - for TypeScript implementations

**Edge cases to handle:**
- Messages with only emoji (may be stored differently)
- Messages with mentions (@username)
- Messages with rich link previews
- Edited messages (text may be in different location)

---

## Appendix F: Fuzzy Matching Specification

For name and chat matching, use these fuzzy matching strategies:

**Levenshtein Distance Thresholds:**
- Exact match: distance = 0
- High confidence: distance ≤ 2 for names ≤ 10 chars
- Medium confidence: distance ≤ 3 for names > 10 chars

**Case-Insensitive Matching:**
- All comparisons lowercase
- Accent-insensitive (é → e)

**Nickname/Alias Handling:**
- Common nicknames: Mike/Michael, Nick/Nicholas, Bob/Robert, etc.
- Consider building configurable alias map

**Phone Number Matching:**
- Normalize all numbers to E.164 before comparison
- Match with or without country code for local numbers
- Handle formatted vs unformatted input

---

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-01-16 | Rob & Claude | Initial draft |
| 1.1 | 2026-01-16 | Rob & Claude | Added group chat complexity analysis, cascading match strategies, disambiguation with activity context, display_name_generated, user join date tracking, grouped_by_chat search format |
| 1.2 | 2026-01-16 | Rob & Claude | Added 3 new tools (get_active_conversations, list_attachments, get_unread), from:"me" filter, unanswered message detection, conversation session boundaries, draft/mute status fields, smart error suggestions |
| 1.3 | 2026-01-16 | Rob & Claude | Token efficiency overhaul: compact response schemas, participant deduplication, smart timestamp strategy (ISO for messages, relative for summaries), shortened keys |
| 1.4 | 2026-01-16 | Rob & Claude | **Major research-based updates:** Removed AddressBook SQLite fallback (unreliable), updated Python requirement to 3.10+, added FastMCP version pin (`<3`), removed unverified mute/pin/draft fields, documented custom emoji reaction types 2006/2007/3006/3007, added RCS service type, added attributedBody parsing section (Appendix E), added phone number normalization with phonenumbers library, added pagination cursor parameter to all tools, added competition analysis (Appendix D), added schema version detection, added fuzzy matching specification (Appendix F), added input sanitization for AppleScript, standardized chat type filtering to `is_group` boolean, added `include_context` to search, added `session` parameter to get_messages, removed `local_path` from attachments for security, extended implementation timeline to 6 weeks |
