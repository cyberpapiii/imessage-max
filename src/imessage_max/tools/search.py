"""search tool implementation."""

from typing import Optional, Any
from ..db import get_db_connection, apple_to_datetime, datetime_to_apple, escape_like, DB_PATH
from ..contacts import ContactResolver
from ..time_utils import parse_time_input, format_compact_relative
from ..parsing import get_message_text
from ..suggestions import get_message_suggestions

# 24 hours in Apple timestamp format (nanoseconds)
TWENTY_FOUR_HOURS_NS = 24 * 60 * 60 * 1_000_000_000


def _looks_like_question(text: str) -> bool:
    """Check if a message appears to expect a response.

    Args:
        text: The message text to check

    Returns:
        True if the message looks like it expects a response
    """
    if not text:
        return False

    text_lower = text.lower().strip()

    # Contains question mark
    if '?' in text:
        return True

    # Ends with common question/request patterns
    question_endings = [
        "what do you think",
        "let me know",
        "thoughts",
        "can you",
        "could you",
        "would you",
        "will you",
        "please",
        "lmk",
    ]
    for ending in question_endings:
        if text_lower.endswith(ending):
            return True

    return False


def _has_reply_within_24h(conn, chat_id: int, message_date: int) -> bool:
    """Check if there's a reply from someone else within 24 hours.

    Args:
        conn: Database connection
        chat_id: Chat ROWID
        message_date: Apple timestamp of the original message

    Returns:
        True if there is a reply within 24 hours
    """
    cursor = conn.execute("""
        SELECT 1 FROM message m
        JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
        WHERE cmj.chat_id = ?
        AND m.date > ?
        AND m.date <= ?
        AND m.is_from_me = 0
        AND m.associated_message_type = 0
        LIMIT 1
    """, (chat_id, message_date, message_date + TWENTY_FOUR_HOURS_NS))

    return cursor.fetchone() is not None


# Use escape_like from db module (aliased for local use)
_escape_like = escape_like


def search_impl(
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
    db_path: str = DB_PATH,
) -> dict[str, Any]:
    """
    Full-text search across messages with advanced filtering.

    Args:
        query: Text to search for
        from_person: Filter to messages from this person (or "me")
        in_chat: Chat ID to search within
        is_group: True for groups only, False for DMs only
        has: Content type: "link", "image", "video", "attachment"
        since: Time bound (ISO, relative like "24h", or natural like "yesterday")
        before: Upper time bound
        limit: Max results (default 20, max 100)
        sort: "recent_first" (default) or "oldest_first"
        format: "flat" (default) or "grouped_by_chat"
        include_context: Include messages before/after each result
        unanswered: Only return messages from me that didn't receive a reply within 24h
        db_path: Path to chat.db (for testing)

    Returns:
        Search results with people map
    """
    # Validate inputs
    if not query or not query.strip():
        return {"error": "invalid_query", "message": "Query cannot be empty"}

    limit = max(1, min(limit, 100))
    if sort not in ("recent_first", "oldest_first"):
        sort = "recent_first"
    if format not in ("flat", "grouped_by_chat"):
        format = "flat"

    resolver = ContactResolver()
    if resolver.is_available:
        resolver.initialize()  # Explicitly initialize to trigger auth check

    try:
        with get_db_connection(db_path) as conn:
            # Build search query
            base_query = """
                SELECT
                    m.ROWID as msg_id,
                    m.guid as msg_guid,
                    m.text,
                    m.attributedBody,
                    m.date,
                    m.is_from_me,
                    h.id as sender_handle,
                    c.ROWID as chat_id,
                    c.guid as chat_guid,
                    c.display_name as chat_display_name
                FROM message m
                JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
                JOIN chat c ON cmj.chat_id = c.ROWID
                LEFT JOIN handle h ON m.handle_id = h.ROWID
                WHERE m.associated_message_type = 0
            """

            params: list[Any] = []

            # Text search - use LIKE for partial matching
            search_term = query.strip()
            base_query += " AND (m.text LIKE ? ESCAPE '\\' COLLATE NOCASE)"
            params.append(f"%{_escape_like(search_term)}%")

            # Time filters
            if since:
                since_dt = parse_time_input(since)
                if since_dt:
                    base_query += " AND m.date >= ?"
                    params.append(datetime_to_apple(since_dt))

            if before:
                before_dt = parse_time_input(before)
                if before_dt:
                    base_query += " AND m.date <= ?"
                    params.append(datetime_to_apple(before_dt))

            # Chat filter
            if in_chat:
                chat_id_str = in_chat.replace("chat", "") if in_chat.startswith("chat") else in_chat
                try:
                    base_query += " AND c.ROWID = ?"
                    params.append(int(chat_id_str))
                except ValueError:
                    # If not numeric, try matching against guid
                    base_query += " AND c.guid LIKE ? ESCAPE '\\'"
                    params.append(f"%{_escape_like(in_chat)}%")

            # From filter (unanswered implies from_me)
            if unanswered:
                base_query += " AND m.is_from_me = 1"
            elif from_person:
                if from_person.lower() == "me":
                    base_query += " AND m.is_from_me = 1"
                else:
                    base_query += " AND h.id LIKE ? ESCAPE '\\'"
                    params.append(f"%{_escape_like(from_person)}%")

            # Is group filter
            if is_group is not None:
                # Group chats typically have multiple participants
                if is_group:
                    base_query += """ AND (
                        SELECT COUNT(*) FROM chat_handle_join chj
                        WHERE chj.chat_id = c.ROWID
                    ) > 1"""
                else:
                    base_query += """ AND (
                        SELECT COUNT(*) FROM chat_handle_join chj
                        WHERE chj.chat_id = c.ROWID
                    ) = 1"""

            # Has filter (content type)
            if has:
                if has == "link":
                    base_query += " AND m.text LIKE '%http%'"
                elif has in ("image", "video", "attachment"):
                    base_query += """ AND EXISTS (
                        SELECT 1 FROM attachment a
                        JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
                        WHERE maj.message_id = m.ROWID
                    )"""

            # Sort
            if sort == "recent_first":
                base_query += " ORDER BY m.date DESC"
            else:
                base_query += " ORDER BY m.date ASC"

            # For unanswered filtering, fetch more results initially since we'll filter some out
            fetch_limit = limit * 3 if unanswered else limit
            base_query += " LIMIT ?"
            params.append(fetch_limit)

            cursor_obj = conn.execute(base_query, params)
            rows = cursor_obj.fetchall()

            # Filter for unanswered messages if requested
            if unanswered:
                filtered_rows = []
                for row in rows:
                    text = get_message_text(row["text"], row["attributedBody"])
                    # Check if message looks like a question and has no reply within 24h
                    if _looks_like_question(text) and not _has_reply_within_24h(
                        conn, row["chat_id"], row["date"]
                    ):
                        filtered_rows.append(row)
                        # Stop once we have enough
                        if len(filtered_rows) >= limit:
                            break
                rows = filtered_rows

            if format == "grouped_by_chat":
                response = _build_grouped_response(rows, query, resolver)
            else:
                response = _build_flat_response(rows, resolver, limit)

            # Add suggestions when no results found
            if response.get("total", 0) == 0:
                # Parse in_chat to get numeric chat ID if provided
                numeric_chat_id = None
                if in_chat:
                    chat_id_str = in_chat.replace("chat", "") if in_chat.startswith("chat") else in_chat
                    try:
                        numeric_chat_id = int(chat_id_str)
                    except ValueError:
                        pass

                suggestions = get_message_suggestions(
                    conn,
                    resolver,
                    query=query,
                    chat_id=numeric_chat_id,
                    since=since,
                    from_person=from_person,
                )
                if suggestions:
                    response["suggestions"] = suggestions

            return response

    except FileNotFoundError:
        return {"error": "database_not_found", "message": f"Database not found at {db_path}"}
    except Exception as e:
        return {"error": "internal_error", "message": str(e)}


def _build_flat_response(rows: list, resolver: ContactResolver, limit: int) -> dict[str, Any]:
    """Build flat format response."""
    results = []
    people: dict[str, Any] = {}
    person_counter = 1
    handle_to_key: dict[str, str] = {}

    for row in rows:
        # Get or create person reference
        if row["is_from_me"]:
            sender_key = "me"
            if "me" not in people:
                people["me"] = {"name": "Me", "is_me": True}
        else:
            handle = row["sender_handle"] or "unknown"
            if handle not in handle_to_key:
                key = f"p{person_counter}"
                person_counter += 1
                handle_to_key[handle] = key
                name = resolver.resolve(handle) if resolver.is_available else None
                people[key] = {
                    "name": name or handle,
                    "handle": handle,
                }
            sender_key = handle_to_key[handle]

        text = get_message_text(row["text"], row["attributedBody"])
        msg_dt = apple_to_datetime(row["date"])

        results.append({
            "id": f"msg{row['msg_id']}",
            "ts": msg_dt.isoformat() if msg_dt else None,
            "ago": format_compact_relative(msg_dt),
            "from": sender_key,
            "text": text,
            "chat": f"chat{row['chat_id']}",
            "chat_name": row["chat_display_name"],
        })

    return {
        "results": results,
        "people": people,
        "total": len(results),
        "more": len(results) >= limit,
        "cursor": None,
    }


def _build_grouped_response(rows: list, query: str, resolver: ContactResolver) -> dict[str, Any]:
    """Build grouped_by_chat format response."""
    chats_data: dict[int, dict[str, Any]] = {}
    people: dict[str, Any] = {}
    person_counter = 1
    handle_to_key: dict[str, str] = {}

    for row in rows:
        chat_id = row["chat_id"]

        # Get or create person reference
        if row["is_from_me"]:
            sender_key = "me"
            if "me" not in people:
                people["me"] = {"name": "Me", "is_me": True}
        else:
            handle = row["sender_handle"] or "unknown"
            if handle not in handle_to_key:
                key = f"p{person_counter}"
                person_counter += 1
                handle_to_key[handle] = key
                name = resolver.resolve(handle) if resolver.is_available else None
                people[key] = {
                    "name": name or handle,
                    "handle": handle,
                }
            sender_key = handle_to_key[handle]

        text = get_message_text(row["text"], row["attributedBody"])
        msg_dt = apple_to_datetime(row["date"])

        if chat_id not in chats_data:
            chats_data[chat_id] = {
                "id": f"chat{chat_id}",
                "name": row["chat_display_name"],
                "match_count": 0,
                "first_match_dt": msg_dt,
                "last_match_dt": msg_dt,
                "sample_messages": [],
            }

        chat = chats_data[chat_id]
        chat["match_count"] += 1

        if msg_dt:
            if chat["first_match_dt"] is None or msg_dt < chat["first_match_dt"]:
                chat["first_match_dt"] = msg_dt
            if chat["last_match_dt"] is None or msg_dt > chat["last_match_dt"]:
                chat["last_match_dt"] = msg_dt

        # Add sample messages (up to 3)
        if len(chat["sample_messages"]) < 3:
            chat["sample_messages"].append({
                "id": f"msg{row['msg_id']}",
                "text": text,
                "from": sender_key,
                "ts": msg_dt.isoformat() if msg_dt else None,
            })

    # Format response
    chats = []
    for chat in chats_data.values():
        chats.append({
            "id": chat["id"],
            "name": chat["name"],
            "match_count": chat["match_count"],
            "first_match": chat["first_match_dt"].isoformat() if chat["first_match_dt"] else None,
            "last_match": chat["last_match_dt"].isoformat() if chat["last_match_dt"] else None,
            "sample_messages": chat["sample_messages"],
        })

    # Sort by match count
    chats.sort(key=lambda x: x["match_count"], reverse=True)

    return {
        "chats": chats,
        "people": people,
        "total": sum(c["match_count"] for c in chats),
        "chat_count": len(chats),
        "query": query,
        "more": False,
        "cursor": None,
    }
