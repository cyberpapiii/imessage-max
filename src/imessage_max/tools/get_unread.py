"""get_unread tool implementation."""

from typing import Optional, Any
from ..db import get_db_connection, apple_to_datetime, escape_like, DB_PATH
from ..contacts import ContactResolver
from ..queries import get_chat_participants
from ..time_utils import format_compact_relative
from ..models import Participant, generate_display_name
from ..phone import format_phone_display
from ..parsing import get_message_text


# Use escape_like from db module (aliased for local use)
_escape_like = escape_like


def get_unread_impl(
    chat_id: Optional[str] = None,
    format: str = "messages",
    limit: int = 50,
    cursor: Optional[str] = None,
    db_path: str = DB_PATH,
) -> dict[str, Any]:
    """
    Get all unread messages across chats, or unread count summary.

    Args:
        chat_id: Filter to specific chat (e.g., "chat123")
        format: "messages" (default) or "summary"
        limit: Max messages to return in "messages" format (max 100)
        cursor: Pagination cursor from previous response
        db_path: Path to chat.db (for testing)

    Returns:
        Dict with unread messages/summary and people map
    """
    # Validate inputs
    if format not in ("messages", "summary"):
        format = "messages"
    limit = max(1, min(limit, 100))  # Clamp to 1-100

    resolver = ContactResolver()
    if resolver.is_available:
        resolver.initialize()  # Explicitly initialize to trigger auth check

    try:
        with get_db_connection(db_path) as conn:
            # Resolve chat_id to numeric ID if provided
            numeric_chat_id = None
            if chat_id:
                if chat_id.startswith("chat"):
                    try:
                        numeric_chat_id = int(chat_id[4:])
                    except ValueError:
                        pass

                if numeric_chat_id is None:
                    # Try to find by GUID
                    cursor_obj = conn.execute(
                        "SELECT ROWID FROM chat WHERE guid LIKE ? ESCAPE '\\'",
                        (f"%{_escape_like(chat_id)}%",)
                    )
                    row = cursor_obj.fetchone()
                    if row:
                        numeric_chat_id = row[0]

                if numeric_chat_id is None:
                    return {
                        "error": "chat_not_found",
                        "message": f"Chat not found: {chat_id}",
                    }

            if format == "summary":
                return _get_unread_summary(conn, numeric_chat_id, resolver)
            else:
                return _get_unread_messages(conn, numeric_chat_id, limit, resolver)

    except FileNotFoundError:
        return {
            "error": "database_not_found",
            "message": f"Database not found at {db_path}",
        }
    except Exception as e:
        return {
            "error": "internal_error",
            "message": str(e),
        }


def _get_unread_messages(
    conn,
    chat_id: Optional[int],
    limit: int,
    resolver: ContactResolver,
) -> dict[str, Any]:
    """Get unread messages in messages format."""
    # Build query for unread messages
    # Unread = is_read = 0 AND is_from_me = 0
    query = """
        SELECT
            m.ROWID as id,
            m.guid,
            m.text,
            m.attributedBody,
            m.date,
            m.is_from_me,
            m.handle_id,
            h.id as sender_handle,
            c.ROWID as chat_id,
            c.display_name as chat_display_name,
            c.guid as chat_guid
        FROM message m
        JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
        JOIN chat c ON cmj.chat_id = c.ROWID
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        WHERE m.is_read = 0
        AND m.is_from_me = 0
        AND m.associated_message_type = 0
    """
    params: list = []

    if chat_id is not None:
        query += " AND cmj.chat_id = ?"
        params.append(chat_id)

    query += " ORDER BY m.date ASC"
    query += f" LIMIT {limit}"

    cursor_obj = conn.execute(query, params)
    rows = cursor_obj.fetchall()

    # Get total count and chat count
    count_query = """
        SELECT
            COUNT(DISTINCT m.ROWID) as total_unread,
            COUNT(DISTINCT cmj.chat_id) as chats_with_unread
        FROM message m
        JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
        WHERE m.is_read = 0
        AND m.is_from_me = 0
        AND m.associated_message_type = 0
    """
    count_params: list = []

    if chat_id is not None:
        count_query += " AND cmj.chat_id = ?"
        count_params.append(chat_id)

    count_cursor = conn.execute(count_query, count_params)
    count_row = count_cursor.fetchone()
    total_unread = count_row['total_unread'] if count_row else 0
    chats_with_unread = count_row['chats_with_unread'] if count_row else 0

    # Build people map and messages
    people: dict[str, str] = {}
    handle_to_key: dict[str, str] = {}
    unknown_count = 0

    # Cache for chat participants
    chat_participants_cache: dict[int, list[dict]] = {}

    unread_messages = []
    for row in rows:
        msg_chat_id = row['chat_id']
        sender_handle = row['sender_handle']

        # Build people map entry for sender
        if sender_handle and sender_handle not in handle_to_key:
            name = resolver.resolve(sender_handle) if resolver.is_available else None
            if name:
                key = name.split()[0].lower()
                # Handle duplicates
                base_key = key
                suffix = 1
                while key in people:
                    key = f"{base_key}{suffix}"
                    suffix += 1
                people[key] = name
                handle_to_key[sender_handle] = key
            else:
                unknown_count += 1
                key = f"p{unknown_count}"
                people[key] = format_phone_display(sender_handle)
                handle_to_key[sender_handle] = key

        # Ensure participants are cached for this chat
        if msg_chat_id not in chat_participants_cache:
            chat_participants_cache[msg_chat_id] = get_chat_participants(
                conn, msg_chat_id, resolver
            )

        # Get chat display name
        chat_display_name = row['chat_display_name']
        if not chat_display_name:
            # Generate from participants
            participant_rows = chat_participants_cache[msg_chat_id]
            participant_objs = [
                Participant(handle=p['handle'], name=p['name'])
                for p in participant_rows
            ]
            chat_display_name = generate_display_name(participant_objs)

        # Determine if group chat (use already-cached data)
        is_group = len(chat_participants_cache[msg_chat_id]) > 1

        # Build message
        text = get_message_text(row['text'], row['attributedBody'])
        msg_dt = apple_to_datetime(row['date'])

        msg_item: dict[str, Any] = {
            "message": {
                "id": f"msg_{row['id']}",
                "ts": msg_dt.isoformat() if msg_dt else None,
                "ago": format_compact_relative(msg_dt),
                "text": text,
            },
            "chat": {
                "id": f"chat{msg_chat_id}",
                "name": chat_display_name,
            },
        }

        # Add sender
        if sender_handle and sender_handle in handle_to_key:
            msg_item["message"]["from"] = handle_to_key[sender_handle]

        # Add is_group flag only if True (token efficiency)
        if is_group:
            msg_item["chat"]["is_group"] = True

        unread_messages.append(msg_item)

    return {
        "unread_messages": unread_messages,
        "people": people,
        "total_unread": total_unread,
        "chats_with_unread": chats_with_unread,
        "more": len(unread_messages) < total_unread,
        "cursor": None,
    }


def _get_unread_summary(
    conn,
    chat_id: Optional[int],
    resolver: ContactResolver,
) -> dict[str, Any]:
    """Get unread messages in summary format."""
    # Get breakdown by chat
    query = """
        SELECT
            cmj.chat_id,
            c.display_name as chat_display_name,
            COUNT(*) as unread_count,
            MIN(m.date) as oldest_unread_date
        FROM message m
        JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
        JOIN chat c ON cmj.chat_id = c.ROWID
        WHERE m.is_read = 0
        AND m.is_from_me = 0
        AND m.associated_message_type = 0
    """
    params: list = []

    if chat_id is not None:
        query += " AND cmj.chat_id = ?"
        params.append(chat_id)

    query += " GROUP BY cmj.chat_id"
    query += " ORDER BY unread_count DESC"

    cursor_obj = conn.execute(query, params)
    rows = cursor_obj.fetchall()

    total_unread = 0
    breakdown = []

    for row in rows:
        msg_chat_id = row['chat_id']
        unread_count = row['unread_count']
        total_unread += unread_count

        # Get chat display name
        chat_display_name = row['chat_display_name']
        if not chat_display_name:
            # Generate from participants
            participant_rows = get_chat_participants(conn, msg_chat_id, resolver)
            participant_objs = [
                Participant(handle=p['handle'], name=p['name'])
                for p in participant_rows
            ]
            chat_display_name = generate_display_name(participant_objs)

        oldest_dt = apple_to_datetime(row['oldest_unread_date'])

        breakdown.append({
            "chat_id": f"chat{msg_chat_id}",
            "chat_name": chat_display_name,
            "unread_count": unread_count,
            "oldest_unread": format_compact_relative(oldest_dt),
        })

    return {
        "summary": {
            "total_unread": total_unread,
            "chats_with_unread": len(breakdown),
            "breakdown": breakdown,
        }
    }
