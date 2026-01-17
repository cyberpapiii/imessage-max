"""list_chats tool implementation."""

from typing import Optional, Any
from ..db import get_db_connection, apple_to_datetime, datetime_to_apple, DB_PATH
from ..contacts import ContactResolver
from ..queries import get_chat_participants
from ..time_utils import parse_time_input, format_compact_relative
from ..models import Participant, generate_display_name
from ..phone import format_phone_display
from ..parsing import get_message_text


def list_chats_impl(
    limit: int = 20,
    since: Optional[str] = None,
    is_group: Optional[bool] = None,
    min_participants: Optional[int] = None,
    max_participants: Optional[int] = None,
    sort: str = "recent",
    cursor: Optional[str] = None,
    db_path: str = DB_PATH,
) -> dict[str, Any]:
    """
    List recent chats with previews.

    Args:
        limit: Max chats to return (default 20)
        since: Only chats with activity since this time
        is_group: True for groups only, False for DMs only
        min_participants: Filter to chats with at least N participants
        max_participants: Filter to chats with at most N participants
        sort: "recent" (default), "alphabetical", or "most_active"
        cursor: Pagination cursor for continuing listing
        db_path: Path to chat.db (for testing)

    Returns:
        Dict with chats list, totals, and pagination info
    """
    # Validate inputs
    limit = max(1, min(limit, 100))  # Clamp to 1-100
    if sort not in ("recent", "alphabetical", "most_active"):
        sort = "recent"  # Default to recent for invalid values

    resolver = ContactResolver()
    if resolver.is_available:
        resolver.initialize()  # Explicitly initialize to trigger auth check

    try:
        with get_db_connection(db_path) as conn:
            # Build base query
            query = """
                SELECT
                    c.ROWID as id,
                    c.guid,
                    c.display_name,
                    c.service_name,
                    COUNT(DISTINCT chj.handle_id) as participant_count,
                    MAX(m.date) as last_message_date
                FROM chat c
                LEFT JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
                LEFT JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
                LEFT JOIN message m ON cmj.message_id = m.ROWID
                    AND m.associated_message_type = 0
            """

            params: list = []
            conditions: list[str] = []

            # Time filter
            if since:
                since_dt = parse_time_input(since)
                if since_dt:
                    since_apple = datetime_to_apple(since_dt)
                    conditions.append("m.date >= ?")
                    params.append(since_apple)

            if conditions:
                query += " WHERE " + " AND ".join(conditions)

            query += " GROUP BY c.ROWID"

            # Participant count filters (HAVING clause)
            having: list[str] = []
            if min_participants is not None:
                having.append("participant_count >= ?")
                params.append(min_participants)
            if max_participants is not None:
                having.append("participant_count <= ?")
                params.append(max_participants)
            if is_group is not None:
                if is_group:
                    having.append("participant_count > 1")
                else:
                    having.append("participant_count <= 1")

            if having:
                query += " HAVING " + " AND ".join(having)

            # Sort
            if sort == "recent":
                query += " ORDER BY last_message_date DESC NULLS LAST"
            elif sort == "alphabetical":
                query += " ORDER BY COALESCE(c.display_name, '') ASC"
            elif sort == "most_active":
                query += " ORDER BY last_message_date DESC NULLS LAST"

            query += " LIMIT ?"
            params.append(limit)

            cursor_obj = conn.execute(query, params)
            rows = cursor_obj.fetchall()

            # Build results
            chats = []
            for row in rows:
                chat_id = row['id']

                # Get participants
                participant_rows = get_chat_participants(conn, chat_id, resolver)
                participants = []
                for p in participant_rows:
                    name = p['name']
                    if name is None:
                        name = format_phone_display(p['handle'])
                    participants.append({
                        "name": name,
                        "handle": p['handle'],
                    })

                participant_objs = [
                    Participant(handle=p['handle'], name=p.get('name'))
                    for p in participant_rows
                ]

                display_name = row['display_name'] or generate_display_name(participant_objs)
                is_group_chat = row['participant_count'] > 1

                # Get last message
                last_cursor = conn.execute("""
                    SELECT m.text, m.attributedBody, m.is_from_me, h.id as sender_handle, m.date
                    FROM message m
                    JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
                    LEFT JOIN handle h ON m.handle_id = h.ROWID
                    WHERE cmj.chat_id = ?
                    AND m.associated_message_type = 0
                    ORDER BY m.date DESC
                    LIMIT 1
                """, (chat_id,))
                last_msg = last_cursor.fetchone()

                chat_info: dict[str, Any] = {
                    "id": f"chat{chat_id}",
                    "name": display_name,
                    "participants": participants,
                    "participant_count": row['participant_count'],
                }

                if is_group_chat:
                    chat_info["group"] = True

                if last_msg:
                    sender: str
                    if last_msg['is_from_me']:
                        sender = "me"
                    elif last_msg['sender_handle']:
                        resolved_name = resolver.resolve(last_msg['sender_handle']) if resolver.is_available else None
                        sender = resolved_name or format_phone_display(last_msg['sender_handle'])
                    else:
                        sender = "unknown"

                    last_dt = apple_to_datetime(last_msg['date'])
                    msg_text = get_message_text(last_msg['text'], last_msg['attributedBody']) or ""
                    chat_info["last"] = {
                        "from": sender,
                        "text": msg_text[:50],
                        "ago": format_compact_relative(last_dt),
                    }

                chats.append(chat_info)

            # Get totals
            total_cursor = conn.execute("""
                SELECT
                    COUNT(*) as total,
                    SUM(CASE WHEN cnt > 1 THEN 1 ELSE 0 END) as groups,
                    SUM(CASE WHEN cnt <= 1 THEN 1 ELSE 0 END) as dms
                FROM (
                    SELECT c.ROWID, COUNT(chj.handle_id) as cnt
                    FROM chat c
                    LEFT JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
                    GROUP BY c.ROWID
                )
            """)
            totals = total_cursor.fetchone()

            return {
                "chats": chats,
                "total_chats": totals['total'] or 0,
                "total_groups": totals['groups'] or 0,
                "total_dms": totals['dms'] or 0,
                "more": len(chats) == limit,
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
