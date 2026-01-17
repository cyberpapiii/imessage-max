"""get_context tool implementation."""

from typing import Optional, Any
from ..db import get_db_connection, apple_to_datetime, escape_like, DB_PATH
from ..contacts import ContactResolver
from ..time_utils import format_compact_relative
from ..parsing import get_message_text


# Use escape_like from db module (aliased for local use)
_escape_like = escape_like


def get_context_impl(
    message_id: Optional[str] = None,
    chat_id: Optional[str] = None,
    contains: Optional[str] = None,
    before: int = 5,
    after: int = 10,
    db_path: str = DB_PATH,
) -> dict[str, Any]:
    """
    Get messages surrounding a specific message.

    Either message_id OR (chat_id + contains) must be provided.

    Args:
        message_id: Specific message ID to get context around (e.g., "msg1" or "1")
        chat_id: Chat ID (required if using contains)
        contains: Find message containing this text, then get context
        before: Number of messages before the target (default 5, max 50)
        after: Number of messages after the target (default 10, max 50)
        db_path: Path to chat.db (for testing)

    Returns:
        Dict with target message, surrounding context, people map, and chat info
    """
    # Clamp before/after to reasonable bounds
    before = max(0, min(before, 50))
    after = max(0, min(after, 50))

    # Validate inputs
    if not message_id and not (chat_id and contains):
        return {
            "error": "invalid_params",
            "message": "Either message_id OR (chat_id + contains) is required",
        }

    if contains and not chat_id:
        return {
            "error": "invalid_params",
            "message": "chat_id is required when using contains",
        }

    resolver = ContactResolver()
    if resolver.is_available:
        resolver.initialize()  # Explicitly initialize to trigger auth check

    try:
        with get_db_connection(db_path) as conn:
            target_row = None
            target_chat_id = None

            if message_id:
                # Find by message ID
                # Extract numeric ID from "msgXXX" format
                msg_id_str = message_id
                if msg_id_str.startswith("msg"):
                    msg_id_str = msg_id_str[3:]

                try:
                    numeric_msg_id = int(msg_id_str)
                except ValueError:
                    return {
                        "error": "invalid_id",
                        "message": f"Invalid message ID format: {message_id}",
                    }

                cursor = conn.execute(
                    """
                    SELECT
                        m.ROWID as msg_id,
                        m.text,
                        m.attributedBody,
                        m.date,
                        m.is_from_me,
                        h.id as sender_handle,
                        c.ROWID as chat_id,
                        c.display_name as chat_name
                    FROM message m
                    JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
                    JOIN chat c ON cmj.chat_id = c.ROWID
                    LEFT JOIN handle h ON m.handle_id = h.ROWID
                    WHERE m.ROWID = ?
                    """,
                    (numeric_msg_id,),
                )
                target_row = cursor.fetchone()

                if target_row:
                    target_chat_id = target_row["chat_id"]
            else:
                # Find by contains in chat
                # Extract numeric chat ID from "chatXXX" format
                chat_id_str = chat_id
                if chat_id_str.startswith("chat"):
                    chat_id_str = chat_id_str[4:]

                try:
                    numeric_chat_id = int(chat_id_str)
                except ValueError:
                    return {
                        "error": "invalid_id",
                        "message": f"Invalid chat ID format: {chat_id}",
                    }

                cursor = conn.execute(
                    """
                    SELECT
                        m.ROWID as msg_id,
                        m.text,
                        m.attributedBody,
                        m.date,
                        m.is_from_me,
                        h.id as sender_handle,
                        c.ROWID as chat_id,
                        c.display_name as chat_name
                    FROM message m
                    JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
                    JOIN chat c ON cmj.chat_id = c.ROWID
                    LEFT JOIN handle h ON m.handle_id = h.ROWID
                    WHERE c.ROWID = ?
                    AND m.text LIKE ? ESCAPE '\\'
                    AND m.associated_message_type = 0
                    ORDER BY m.date DESC
                    LIMIT 1
                    """,
                    (numeric_chat_id, f"%{_escape_like(contains)}%"),
                )
                target_row = cursor.fetchone()

                if target_row:
                    target_chat_id = target_row["chat_id"]

            if not target_row:
                return {
                    "error": "not_found",
                    "message": "Target message not found",
                }

            target_date = target_row["date"]

            # Get messages before the target
            before_cursor = conn.execute(
                """
                SELECT
                    m.ROWID as msg_id,
                    m.text,
                    m.attributedBody,
                    m.date,
                    m.is_from_me,
                    h.id as sender_handle
                FROM message m
                JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
                LEFT JOIN handle h ON m.handle_id = h.ROWID
                WHERE cmj.chat_id = ?
                AND m.date < ?
                AND m.associated_message_type = 0
                ORDER BY m.date DESC
                LIMIT ?
                """,
                (target_chat_id, target_date, before),
            )
            # Reverse to get chronological order (oldest first)
            before_rows = list(reversed(before_cursor.fetchall()))

            # Get messages after the target
            after_cursor = conn.execute(
                """
                SELECT
                    m.ROWID as msg_id,
                    m.text,
                    m.attributedBody,
                    m.date,
                    m.is_from_me,
                    h.id as sender_handle
                FROM message m
                JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
                LEFT JOIN handle h ON m.handle_id = h.ROWID
                WHERE cmj.chat_id = ?
                AND m.date > ?
                AND m.associated_message_type = 0
                ORDER BY m.date ASC
                LIMIT ?
                """,
                (target_chat_id, target_date, after),
            )
            after_rows = after_cursor.fetchall()

            # Build people map with token-efficient keys
            people: dict[str, dict[str, Any]] = {}
            handle_to_key: dict[str, str] = {}
            person_counter = 1

            def get_person_key(row) -> str:
                nonlocal person_counter
                if row["is_from_me"]:
                    if "me" not in people:
                        people["me"] = {"name": "Me", "is_me": True}
                    return "me"
                else:
                    handle = row["sender_handle"] or "unknown"
                    if handle not in handle_to_key:
                        key = f"p{person_counter}"
                        person_counter += 1
                        handle_to_key[handle] = key

                        # Try to resolve contact name
                        name = None
                        if resolver.is_available:
                            name = resolver.resolve(handle)

                        people[key] = {
                            "name": name or handle,
                            "handle": handle,
                        }
                    return handle_to_key[handle]

            def format_message(row) -> dict[str, Any]:
                """Format a message row into response format."""
                text = get_message_text(row["text"], row["attributedBody"])
                msg_dt = apple_to_datetime(row["date"])

                return {
                    "id": f"msg{row['msg_id']}",
                    "ts": msg_dt.isoformat() if msg_dt else None,
                    "ago": format_compact_relative(msg_dt),
                    "from": get_person_key(row),
                    "text": text,
                }

            # Format all messages
            target = format_message(target_row)
            before_msgs = [format_message(r) for r in before_rows]
            after_msgs = [format_message(r) for r in after_rows]

            return {
                "target": target,
                "before": before_msgs,
                "after": after_msgs,
                "people": people,
                "chat": {
                    "id": f"chat{target_chat_id}",
                    "name": target_row["chat_name"],
                },
            }

    except FileNotFoundError:
        return {
            "error": "database_not_found",
            "message": f"Database not found at {db_path}",
        }
    except ValueError as e:
        return {
            "error": "invalid_id",
            "message": str(e),
        }
    except Exception as e:
        return {
            "error": "internal_error",
            "message": str(e),
        }
