"""iMessage Max - MCP Server for iMessage."""

import subprocess
from typing import Optional
from fastmcp import FastMCP

from .tools.find_chat import find_chat_impl
from .tools.get_messages import get_messages_impl
from .tools.list_chats import list_chats_impl
from .tools.search import search_impl
from .tools.get_context import get_context_impl
from .tools.get_active import get_active_conversations_impl
from .tools.list_attachments import list_attachments_impl
from .tools.get_unread import get_unread_impl
from .tools.send import send_impl
from .tools.get_attachment import get_attachment_impl
from .contacts import check_contacts_authorization, request_contacts_access, PYOBJC_AVAILABLE, ContactResolver
from .db import check_database_access, DB_PATH
from .version_check import (
    check_for_update,
    get_update_notice_once,
    get_current_version,
    CURRENT_VERSION,
)

mcp = FastMCP("iMessage Max")


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
    result = find_chat_impl(
        participants=participants,
        name=name,
        contains_recent=contains_recent,
        is_group=is_group,
        limit=limit,
    )
    return _add_update_notice(result)


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
    unanswered: bool = False,
    session: Optional[str] = None,
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
        unanswered: Only return messages from me that didn't receive a reply within 24h
        session: Filter to specific session ID (e.g., "session_1")

    Returns:
        Messages with chat info, people map, and sessions summary
    """
    result = get_messages_impl(
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
        unanswered=unanswered,
        session=session,
    )
    return _add_update_notice(result)


def _add_update_notice(response: dict) -> dict:
    """Add update notice to response if available (once per session)."""
    update_notice = get_update_notice_once()
    if update_notice:
        response["_update"] = {
            "available": update_notice["latest_version"],
            "current": update_notice["current_version"],
            "message": f"iMessage Max {update_notice['latest_version']} is available (you have {update_notice['current_version']}). Use the 'update' tool to install it.",
        }
    return response


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
    result = list_chats_impl(
        limit=limit,
        since=since,
        is_group=is_group,
        min_participants=min_participants,
        max_participants=max_participants,
        sort=sort,
    )
    return _add_update_notice(result)


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
    unanswered: bool = False,
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
        unanswered: Only return messages from me that didn't receive a reply within 24h

    Returns:
        Search results with people map
    """
    result = search_impl(
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
        unanswered=unanswered,
    )
    return _add_update_notice(result)


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


@mcp.tool()
def get_unread(
    chat_id: Optional[str] = None,
    since: str = "7d",
    format: str = "messages",
    limit: int = 50,
    cursor: Optional[str] = None,
) -> dict:
    """
    Get unread messages across chats, or unread count summary.

    By default returns unread messages from the last 7 days, which matches
    what Messages.app displays. Use since="all" to include historical unread
    messages that were never properly marked as read.

    Args:
        chat_id: Filter to specific chat (e.g., "chat123")
        since: Time window for unread messages (default "7d").
               Accepts relative ("24h", "7d", "14d", "30d"), natural ("yesterday",
               "last week"), or "all" for no time limit.
        format: "messages" (default) returns full unread messages,
                "summary" returns unread counts by chat
        limit: Max messages to return in "messages" format (default 50, max 100)
        cursor: Pagination cursor from previous response

    Returns:
        Unread messages with chat info and people map, or summary breakdown
    """
    return get_unread_impl(
        chat_id=chat_id,
        since=since,
        format=format,
        limit=min(limit, 100),
        cursor=cursor,
    )


@mcp.tool()
def send(
    to: Optional[str] = None,
    chat_id: Optional[str] = None,
    text: Optional[str] = None,
    reply_to: Optional[str] = None,
) -> dict:
    """
    Send a message to a person or group chat.

    Args:
        to: Contact name, phone number, or email (required if chat_id not provided)
        chat_id: Existing chat ID for group chats or when 'to' is ambiguous
        text: Message content (required)
        reply_to: Message ID to reply to (not implemented yet)

    Returns:
        Success info with message_id, chat_id, timestamp, and delivered_to list.
        If recipient is ambiguous, returns candidates for disambiguation.
    """
    return send_impl(
        to=to,
        chat_id=chat_id,
        text=text,
        reply_to=reply_to,
    )


@mcp.tool()
def get_attachment(
    attachment_id: str,
    variant: str = "vision",
):
    """
    Get attachment content at specified resolution.

    Use this tool when you need to view an image from a conversation.
    The get_messages tool returns metadata only - use this to see actual images.

    Args:
        attachment_id: Attachment identifier from media objects (e.g., "att123")
        variant: Resolution variant:
            - "vision" (default): 1568px, optimized for AI analysis
            - "thumb": 400px, quick preview
            - "full": Original resolution (may be large)

    Returns:
        List with [metadata_string, Image] for successful image retrieval,
        or dict with error details if retrieval fails
    """
    return get_attachment_impl(attachment_id=attachment_id, variant=variant)


@mcp.tool()
def diagnose() -> dict:
    """
    Diagnose iMessage MCP configuration and permissions.

    Use this tool to troubleshoot issues with contact resolution,
    database access, or permission problems.

    Returns:
        Dict with database access status, contacts status, version info, and system info
    """
    import sys
    import os

    result = {
        "python_executable": sys.executable,
        "process_id": os.getpid(),
    }

    # Version info
    result["version"] = CURRENT_VERSION
    update_info = check_for_update()
    if update_info:
        result["update_available"] = update_info["latest_version"]
        result["update_command"] = update_info["update_command"]

    # Check database access (Full Disk Access)
    db_accessible, db_status = check_database_access()
    result["database_accessible"] = db_accessible
    result["database_status"] = db_status
    result["database_path"] = DB_PATH

    if not db_accessible:
        if db_status == "permission_denied":
            result["database_fix"] = (
                "Grant Full Disk Access: System Settings → Privacy & Security → "
                "Full Disk Access → Add your Python interpreter or uvx"
            )
        elif db_status == "database_not_found":
            result["database_fix"] = (
                "iMessage database not found. Ensure iMessage is set up and "
                "has sent/received at least one message."
            )

    # Check Contacts access
    result["pyobjc_available"] = PYOBJC_AVAILABLE

    if PYOBJC_AVAILABLE:
        is_authorized, status = check_contacts_authorization()
        result["contacts_authorized"] = is_authorized
        result["contacts_status"] = status

        if is_authorized:
            resolver = ContactResolver()
            resolver.initialize()
            stats = resolver.get_stats()
            result["contacts_loaded"] = stats.get("handle_count", 0)
        else:
            result["contacts_fix"] = (
                "Grant Contacts access: System Settings → Privacy & Security → "
                "Contacts → Add your Python interpreter or uvx"
            )
    else:
        result["contacts_authorized"] = False
        result["contacts_status"] = "pyobjc_not_available"

    # Overall status
    all_good = db_accessible and result.get("contacts_authorized", False)
    result["status"] = "ready" if all_good else "needs_setup"

    return result


@mcp.tool()
def update() -> dict:
    """
    Check for and install iMessage Max updates.

    This tool checks PyPI for a newer version and installs it if available.
    After updating, Claude Desktop needs to be restarted to use the new version.

    Returns:
        Dict with update status and instructions
    """
    # Check if update is available
    update_info = check_for_update()

    if not update_info:
        return {
            "status": "up_to_date",
            "current_version": CURRENT_VERSION,
            "message": "You're running the latest version of iMessage Max."
        }

    # Perform the update
    try:
        result = subprocess.run(
            ["uvx", "--refresh", "imessage-max", "--version"],
            capture_output=True,
            text=True,
            timeout=60
        )

        if result.returncode == 0:
            return {
                "status": "updated",
                "previous_version": CURRENT_VERSION,
                "new_version": update_info["latest_version"],
                "message": (
                    f"Successfully updated from {CURRENT_VERSION} to {update_info['latest_version']}. "
                    f"Please restart Claude Desktop (Cmd+Q, then reopen) to use the new version."
                ),
                "action_required": "Restart Claude Desktop"
            }
        else:
            return {
                "status": "update_failed",
                "error": result.stderr or "Unknown error",
                "manual_command": "uvx --refresh imessage-max",
                "message": "Automatic update failed. Please run the manual command in your terminal."
            }

    except FileNotFoundError:
        return {
            "status": "update_failed",
            "error": "uvx not found",
            "manual_command": "pip install --upgrade imessage-max",
            "message": "uvx is not installed. Please update manually with pip."
        }
    except subprocess.TimeoutExpired:
        return {
            "status": "update_failed",
            "error": "Update timed out",
            "manual_command": "uvx --refresh imessage-max",
            "message": "Update timed out. Please try the manual command."
        }


__version__ = CURRENT_VERSION


def main() -> None:
    """Run the MCP server."""
    import argparse
    import sys

    parser = argparse.ArgumentParser(description="iMessage Max - MCP Server")
    parser.add_argument("--version", "-v", action="version", version=f"imessage-max {CURRENT_VERSION}")
    parser.parse_args()

    # Check database access on startup (Full Disk Access)
    db_accessible, db_status = check_database_access()
    if not db_accessible:
        if db_status == "permission_denied":
            print("""
╔══════════════════════════════════════════════════════════════════════════════╗
║                         FULL DISK ACCESS REQUIRED                            ║
╚══════════════════════════════════════════════════════════════════════════════╝

iMessage Max cannot access your iMessage database.

To fix this:
  1. Open System Settings → Privacy & Security → Full Disk Access
  2. Click + and add: """ + sys.executable + """
  3. Restart Claude Desktop

If using UV/uvx, also add: ~/.local/bin/uvx

TIP: Press Cmd+Shift+G to type the path directly.

Run the 'diagnose' tool after granting permission to verify setup.
""", file=sys.stderr, flush=True)
        elif db_status == "database_not_found":
            print(f"[iMessage Max] Database not found at {DB_PATH}. "
                  f"Make sure iMessage is set up.", file=sys.stderr, flush=True)
        else:
            print(f"[iMessage Max] Database access issue: {db_status}", file=sys.stderr, flush=True)
        # Continue anyway - the error will surface when tools are used

    # Request Contacts access on startup - triggers macOS permission dialog if needed
    if PYOBJC_AVAILABLE:
        granted, status = request_contacts_access(timeout=30.0)
        if not granted:
            print(f"[iMessage Max] Contacts access not granted ({status}). "
                  f"Contact names will show as phone numbers.", file=sys.stderr, flush=True)

    mcp.run()


if __name__ == "__main__":
    main()
