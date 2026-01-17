"""get_active_conversations tool implementation."""

from typing import Optional, Any
from datetime import datetime, timezone, timedelta
from ..db import get_db_connection, apple_to_datetime, datetime_to_apple, DB_PATH
from ..contacts import ContactResolver
from ..queries import get_chat_participants
from ..models import Participant, generate_display_name
from ..phone import format_phone_display


def get_active_conversations_impl(
    hours: int = 24,
    min_exchanges: int = 2,
    is_group: Optional[bool] = None,
    limit: int = 10,
    db_path: str = DB_PATH,
) -> dict[str, Any]:
    """
    Find conversations with recent bidirectional activity.

    Identifies chats with actual back-and-forth (not just received messages),
    ordered by most recent activity.

    Args:
        hours: Time window to consider (default 24, max 168 = 1 week)
        min_exchanges: Minimum back-and-forth exchanges to qualify (default 2)
        is_group: True for groups only, False for DMs only, None for both
        limit: Max results (default 10, max 50)
        db_path: Path to chat.db (for testing)

    Returns:
        Dict with conversations list and metadata
    """
    # Validate and clamp inputs
    hours = max(1, min(hours, 168))  # 1 hour to 1 week
    min_exchanges = max(1, min(min_exchanges, 100))
    limit = max(1, min(limit, 50))

    resolver = ContactResolver()
    if resolver.is_available:
        resolver.initialize()  # Explicitly initialize to trigger auth check
    now = datetime.now(timezone.utc)
    window_start = now - timedelta(hours=hours)
    window_start_apple = datetime_to_apple(window_start)

    try:
        with get_db_connection(db_path) as conn:
            # Get chats with bidirectional message activity in window
            # We need chats where BOTH is_from_me=1 AND is_from_me=0 messages exist
            query = """
                SELECT
                    c.ROWID as chat_id,
                    c.display_name,
                    COUNT(DISTINCT chj.handle_id) as participant_count,
                    SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) as my_count,
                    SUM(CASE WHEN m.is_from_me = 0 THEN 1 ELSE 0 END) as their_count,
                    MAX(CASE WHEN m.is_from_me = 1 THEN m.date ELSE NULL END) as last_from_me,
                    MAX(CASE WHEN m.is_from_me = 0 THEN m.date ELSE NULL END) as last_from_them,
                    MIN(m.date) as first_in_window,
                    MAX(m.date) as last_in_window
                FROM chat c
                LEFT JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
                JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
                JOIN message m ON cmj.message_id = m.ROWID
                WHERE m.date >= ?
                AND m.associated_message_type = 0
                GROUP BY c.ROWID
                HAVING my_count >= 1 AND their_count >= 1
            """

            params: list[Any] = [window_start_apple]

            # Apply group filter as HAVING clause based on participant count
            if is_group is True:
                query += " AND participant_count > 1"
            elif is_group is False:
                query += " AND participant_count <= 1"

            query += " ORDER BY last_in_window DESC"

            # Fetch more than limit to account for filtering
            fetch_limit = limit * 3
            query += " LIMIT ?"
            params.append(fetch_limit)

            cursor = conn.execute(query, params)
            rows = cursor.fetchall()

            conversations = []
            for row in rows:
                if len(conversations) >= limit:
                    break

                chat_id = row['chat_id']
                my_count = row['my_count']
                their_count = row['their_count']

                # Calculate exchanges (min of my and their messages)
                exchanges = min(my_count, their_count)

                # Filter by minimum exchanges
                if exchanges < min_exchanges:
                    continue

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

                # Determine awaiting reply
                last_from_me = row['last_from_me']
                last_from_them = row['last_from_them']
                awaiting_reply = False
                if last_from_them and last_from_me:
                    awaiting_reply = last_from_them > last_from_me
                elif last_from_them and not last_from_me:
                    awaiting_reply = True

                conv: dict[str, Any] = {
                    "id": f"chat{chat_id}",
                    "name": display_name,
                    "participants": participants,
                    "activity": {
                        "exchanges": exchanges,
                        "my_msgs": my_count,
                        "their_msgs": their_count,
                        "last_from_me": apple_to_datetime(last_from_me).isoformat() if last_from_me else None,
                        "last_from_them": apple_to_datetime(last_from_them).isoformat() if last_from_them else None,
                        "started": apple_to_datetime(row['first_in_window']).isoformat() if row['first_in_window'] else None,
                    },
                    "awaiting_reply": awaiting_reply,
                }

                if is_group_chat:
                    conv["group"] = True

                conversations.append(conv)

            return {
                "conversations": conversations,
                "total": len(conversations),
                "window_hours": hours,
                "more": len(conversations) >= limit,
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
