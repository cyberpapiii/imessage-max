"""iMessage MCP Server."""

from typing import Optional
from fastmcp import FastMCP

from .tools.find_chat import find_chat_impl
from .tools.get_messages import get_messages_impl
from .tools.list_chats import list_chats_impl
from .tools.search import search_impl

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


def main() -> None:
    """Run the MCP server."""
    mcp.run()


if __name__ == "__main__":
    main()
