"""iMessage MCP Server."""

from typing import Optional
from fastmcp import FastMCP

from .tools.find_chat import find_chat_impl
from .tools.get_messages import get_messages_impl
from .tools.list_chats import list_chats_impl
from .tools.search import search_impl
from .tools.get_context import get_context_impl
from .tools.get_active import get_active_conversations_impl
from .tools.list_attachments import list_attachments_impl

mcp = FastMCP("iMessage MCP")


@mcp.tool()
def find_chat(
    participants: Optional[list[str]] = None,
    name: Optional[str] = None,
    contains_recent: Optional[str] = None,
    is_group: Optional[bool] = None,
    limit: int = 5,
) -> dict:
    """
    Find chats by participants, name, or recent content.

    Args:
        participants: List of participant names or phone numbers to match
        name: Chat display name to search for (fuzzy match)
        contains_recent: Text that appears in recent messages
        is_group: Filter to group chats only (True) or DMs only (False)
        limit: Maximum results to return (default 5)

    Returns:
        List of matching chats with participant info
    """
    return find_chat_impl(
        participants=participants,
        name=name,
        contains_recent=contains_recent,
        is_group=is_group,
        limit=limit,
    )


@mcp.tool()
def get_messages(
    chat_id: Optional[str] = None,
    participants: Optional[list[str]] = None,
    since: Optional[str] = None,
    before: Optional[str] = None,
    limit: int = 50,
    from_person: Optional[str] = None,
    contains: Optional[str] = None,
    has: Optional[str] = None,
    include_reactions: bool = True,
    cursor: Optional[str] = None,
) -> dict:
    """
    Get messages from a chat with flexible filtering.

    Args:
        chat_id: Chat identifier from find_chat
        participants: Alternative - find chat by participants
        since: Time bound (ISO, relative like "24h", or natural like "yesterday")
        before: Upper time bound
        limit: Max messages (default 50, max 200)
        from_person: Filter to messages from specific person (or "me")
        contains: Text search within messages
        has: Filter by content type (links, attachments, images)
        include_reactions: Include reaction data (default True)
        cursor: Pagination cursor from previous response

    Returns:
        Messages with chat info and people map for compact references
    """
    return get_messages_impl(
        chat_id=chat_id,
        participants=participants,
        since=since,
        before=before,
        limit=min(limit, 200),
        from_person=from_person,
        contains=contains,
        has=has,
        include_reactions=include_reactions,
        cursor=cursor,
    )


@mcp.tool()
def list_chats(
    limit: int = 20,
    since: Optional[str] = None,
    is_group: Optional[bool] = None,
    min_participants: Optional[int] = None,
    max_participants: Optional[int] = None,
    sort: str = "recent",
) -> dict:
    """
    List recent chats with previews.

    Args:
        limit: Max chats to return (default 20)
        since: Only chats with activity since this time
        is_group: True for groups only, False for DMs only
        min_participants: Filter to chats with at least N participants
        max_participants: Filter to chats with at most N participants
        sort: "recent" (default), "alphabetical", or "most_active"

    Returns:
        List of chats with last message previews
    """
    return list_chats_impl(
        limit=limit,
        since=since,
        is_group=is_group,
        min_participants=min_participants,
        max_participants=max_participants,
        sort=sort,
    )


@mcp.tool()
def search(
    query: str,
    from_person: Optional[str] = None,
    in_chat: Optional[str] = None,
    is_group: Optional[bool] = None,
    has: Optional[str] = None,
    since: Optional[str] = None,
    before: Optional[str] = None,
    limit: int = 20,
    sort: str = "recent_first",
    format: str = "flat",
    include_context: bool = False,
) -> dict:
    """
    Full-text search across messages with advanced filtering.

    Args:
        query: Text to search for
        from_person: Filter to messages from this person (or "me")
        in_chat: Chat ID to search within
        is_group: True for groups only, False for DMs only
        has: Content type filter: "link", "image", "video", "attachment"
        since: Time bound (ISO, relative like "24h", or natural like "yesterday")
        before: Upper time bound
        limit: Max results (default 20, max 100)
        sort: "recent_first" (default) or "oldest_first"
        format: "flat" (default) or "grouped_by_chat"
        include_context: Include messages before/after each result

    Returns:
        Search results with people map
    """
    return search_impl(
        query=query,
        from_person=from_person,
        in_chat=in_chat,
        is_group=is_group,
        has=has,
        since=since,
        before=before,
        limit=limit,
        sort=sort,
        format=format,
        include_context=include_context,
    )


@mcp.tool()
def get_context(
    message_id: Optional[str] = None,
    chat_id: Optional[str] = None,
    contains: Optional[str] = None,
    before: int = 5,
    after: int = 10,
) -> dict:
    """
    Get messages surrounding a specific message.

    Args:
        message_id: Specific message ID to get context around
        chat_id: Chat ID (required if using contains)
        contains: Find message containing this text, then get context
        before: Number of messages before target (default 5)
        after: Number of messages after target (default 10)

    Returns:
        Target message with surrounding context and people map
    """
    return get_context_impl(
        message_id=message_id,
        chat_id=chat_id,
        contains=contains,
        before=before,
        after=after,
    )


@mcp.tool()
def get_active_conversations(
    hours: int = 24,
    min_exchanges: int = 2,
    is_group: Optional[bool] = None,
    limit: int = 10,
) -> dict:
    """
    Find conversations with recent bidirectional activity.

    Identifies chats with actual back-and-forth exchanges (not just received
    messages), useful for finding ongoing conversations that need attention.

    Args:
        hours: Time window to consider (default 24, max 168 = 1 week)
        min_exchanges: Minimum back-and-forth exchanges to qualify (default 2)
        is_group: True for groups only, False for DMs only
        limit: Max results (default 10)

    Returns:
        Active conversations with activity summaries and awaiting_reply flags
    """
    return get_active_conversations_impl(
        hours=hours,
        min_exchanges=min_exchanges,
        is_group=is_group,
        limit=limit,
    )


@mcp.tool()
def list_attachments(
    chat_id: Optional[str] = None,
    from_person: Optional[str] = None,
    type: Optional[str] = None,
    since: Optional[str] = None,
    before: Optional[str] = None,
    limit: int = 50,
    sort: str = "recent_first",
) -> dict:
    """
    List attachments with metadata.

    Args:
        chat_id: Filter to specific chat
        from_person: Filter to attachments from specific person (or "me")
        type: Filter by type: "image", "video", "audio", "pdf", "document", "any"
        since: Time bound (ISO, relative like "24h", or natural like "yesterday")
        before: Upper time bound
        limit: Max results (default 50, max 100)
        sort: "recent_first" (default), "oldest_first", "largest_first"

    Returns:
        Attachments with metadata and people map
    """
    return list_attachments_impl(
        chat_id=chat_id,
        from_person=from_person,
        type=type,
        since=since,
        before=before,
        limit=limit,
        sort=sort,
    )


def main() -> None:
    """Run the MCP server."""
    mcp.run()


if __name__ == "__main__":
    main()
