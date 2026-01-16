"""find_chat tool implementation."""

from typing import Optional, Any
from ..db import get_db_connection, apple_to_datetime, DB_PATH
from ..contacts import ContactResolver
from ..phone import normalize_to_e164, format_phone_display
from ..queries import (
    get_chat_participants,
    find_chats_by_handles,
)
from ..models import Participant, generate_display_name
from ..time_utils import format_compact_relative


def find_chat_impl(
    participants: Optional[list[str]] = None,
    name: Optional[str] = None,
    contains_recent: Optional[str] = None,
    is_group: Optional[bool] = None,
    limit: int = 5,
    cursor: Optional[str] = None,
    db_path: str = DB_PATH,
) -> dict[str, Any]:
    """
    Find chats by participants, name, or recent content.

    At least one of participants, name, or contains_recent must be provided.

    Args:
        participants: List of participant names or phone numbers to match
        name: Chat display name to search for (fuzzy match)
        contains_recent: Text that appears in recent messages
        is_group: Filter to group chats only (True) or DMs only (False)
        limit: Maximum results to return (default 5)
        cursor: Pagination cursor for continuing search
        db_path: Path to chat.db (for testing)

    Returns:
        Dict with chats list and pagination info
    """
    if not any([participants, name, contains_recent]):
        return {
            "error": "validation_error",
            "message": "At least one of participants, name, or contains_recent required",
        }

    resolver = ContactResolver()

    try:
        with get_db_connection(db_path) as conn:
            results = []

            # Strategy 1: Search by participant handles
            if participants:
                handles = []
                for p in participants:
                    if p.startswith('+'):
                        handles.append(p)
                    else:
                        normalized = normalize_to_e164(p)
                        if normalized:
                            handles.append(normalized)
                        else:
                            # Try name lookup via contacts
                            if resolver.is_available:
                                resolver.initialize()
                                for handle, contact_name in (resolver._lookup or {}).items():
                                    if p.lower() in contact_name.lower():
                                        handles.append(handle)

                if handles:
                    chat_rows = find_chats_by_handles(conn, handles)
                    for chat_row in chat_rows:
                        chat_info = _build_chat_info(conn, chat_row, resolver)
                        chat_info["match"] = "participants"
                        results.append(chat_info)

            # Strategy 2: Search by display name
            if name and not results:
                cursor_obj = conn.execute("""
                    SELECT c.ROWID as id, c.guid, c.display_name, c.service_name
                    FROM chat c
                    WHERE c.display_name LIKE ?
                    LIMIT ?
                """, (f"%{name}%", limit))

                for row in cursor_obj.fetchall():
                    chat_info = _build_chat_info(conn, dict(row), resolver)
                    chat_info["match"] = "name"
                    results.append(chat_info)

            # Strategy 3: Search by recent content
            if contains_recent and not results:
                cursor_obj = conn.execute("""
                    SELECT DISTINCT c.ROWID as id, c.guid, c.display_name, c.service_name
                    FROM chat c
                    JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
                    JOIN message m ON cmj.message_id = m.ROWID
                    WHERE m.text LIKE ?
                    ORDER BY m.date DESC
                    LIMIT ?
                """, (f"%{contains_recent}%", limit))

                for row in cursor_obj.fetchall():
                    chat_info = _build_chat_info(conn, dict(row), resolver)
                    chat_info["match"] = "content"
                    results.append(chat_info)

            # Filter by is_group if specified
            if is_group is not None:
                results = [r for r in results if r.get("group", False) == is_group]

            # Deduplicate and limit
            seen_ids = set()
            unique_results = []
            for r in results:
                if r["id"] not in seen_ids:
                    seen_ids.add(r["id"])
                    unique_results.append(r)
                    if len(unique_results) >= limit:
                        break

            return {
                "chats": unique_results,
                "more": len(results) > limit,
                "cursor": None,
            }

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


def _build_chat_info(conn, chat_row: dict, resolver: ContactResolver) -> dict:
    """Build chat info dict with participants."""
    chat_id = chat_row['id']

    # Get participants
    participant_rows = get_chat_participants(conn, chat_id, resolver)
    participants = []
    for p in participant_rows:
        participant_info = {
            "handle": p['handle'],
        }
        if p['name']:
            participant_info["name"] = p['name']
        else:
            participant_info["name"] = format_phone_display(p['handle'])
        participants.append(participant_info)

    is_group = len(participants) > 1

    # Generate display name if not set
    display_name = chat_row.get('display_name')
    if not display_name:
        participant_objs = [
            Participant(handle=p['handle'], name=p.get('name'))
            for p in participants
        ]
        display_name = generate_display_name(participant_objs)

    # Get last message
    cursor = conn.execute("""
        SELECT m.text, m.date, m.is_from_me, h.id as sender_handle
        FROM message m
        JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        WHERE cmj.chat_id = ?
        AND m.associated_message_type = 0
        ORDER BY m.date DESC
        LIMIT 1
    """, (chat_id,))

    last_msg = cursor.fetchone()
    last_info = None
    if last_msg:
        sender = "me" if last_msg['is_from_me'] else (
            resolver.resolve(last_msg['sender_handle']) if resolver.is_available else last_msg['sender_handle']
        )
        if sender is None:
            sender = format_phone_display(last_msg['sender_handle']) if last_msg['sender_handle'] else "unknown"
        last_dt = apple_to_datetime(last_msg['date'])
        last_info = {
            "from": sender,
            "text": (last_msg['text'] or "")[:50],
            "ago": format_compact_relative(last_dt),
        }

    result = {
        "id": f"chat{chat_id}",
        "name": display_name,
        "participants": participants,
    }

    if is_group:
        result["group"] = True

    if last_info:
        result["last"] = last_info

    return result
