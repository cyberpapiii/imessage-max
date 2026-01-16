"""iMessage MCP Server."""

from typing import Optional
from fastmcp import FastMCP

from .tools.find_chat import find_chat_impl

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


def main() -> None:
    """Run the MCP server."""
    mcp.run()


if __name__ == "__main__":
    main()
