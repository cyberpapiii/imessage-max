"""get_messages tool implementation."""

from typing import Optional, Any
from ..db import get_db_connection, apple_to_datetime, datetime_to_apple, DB_PATH
from ..contacts import ContactResolver
from ..phone import normalize_to_e164, format_phone_display
from ..queries import get_chat_participants, get_messages_for_chat, get_reactions_for_messages
from ..parsing import get_message_text, get_reaction_type, reaction_to_emoji, extract_links
from ..time_utils import parse_time_input
from ..models import Participant, generate_display_name

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


def get_messages_impl(
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
    db_path: str = DB_PATH,
) -> dict[str, Any]:
    """
    Get messages from a chat with flexible filtering.

    Either chat_id or participants must be provided.

    Args:
        chat_id: Chat identifier (e.g., "chat1" or "chat123")
        participants: Alternative - find chat by participant handles
        since: Time bound (ISO, relative like "24h", or natural like "yesterday")
        before: Upper time bound
        limit: Maximum messages to return (default 50)
        from_person: Filter to messages from specific person (or "me")
        contains: Text search within messages
        has: Filter by content type ("links", "attachments", etc.)
        include_reactions: Include reaction data (default True)
        cursor: Pagination cursor for continuing retrieval
        unanswered: Only return messages from me that didn't receive a reply within 24h
        db_path: Path to chat.db (for testing)

    Returns:
        Dict with chat info, people map, and messages
    """
    if not chat_id and not participants:
        return {
            "error": "validation_error",
            "message": "Either chat_id or participants must be provided",
        }

    resolver = ContactResolver()

    try:
        with get_db_connection(db_path) as conn:
            # Resolve chat_id to numeric ID
            numeric_chat_id = None

            if chat_id:
                # Extract numeric ID from "chatXXX" format
                if chat_id.startswith("chat"):
                    try:
                        numeric_chat_id = int(chat_id[4:])
                    except ValueError:
                        pass

                if numeric_chat_id is None:
                    # Try to find by GUID
                    cursor_obj = conn.execute(
                        "SELECT ROWID FROM chat WHERE guid LIKE ?",
                        (f"%{chat_id}%",)
                    )
                    row = cursor_obj.fetchone()
                    if row:
                        numeric_chat_id = row[0]

            if numeric_chat_id is None:
                return {
                    "error": "chat_not_found",
                    "message": f"Chat not found: {chat_id}",
                }

            # Get chat info
            chat_cursor = conn.execute("""
                SELECT c.ROWID, c.guid, c.display_name, c.service_name
                FROM chat c WHERE c.ROWID = ?
            """, (numeric_chat_id,))
            chat_row = chat_cursor.fetchone()

            if not chat_row:
                return {
                    "error": "chat_not_found",
                    "message": f"Chat not found: {chat_id}",
                }

            # Get participants
            participant_rows = get_chat_participants(conn, numeric_chat_id, resolver)

            # Build people map (handle -> short key)
            people = {"me": "Me"}
            handle_to_key = {}
            unknown_count = 0

            for i, p in enumerate(participant_rows):
                handle = p['handle']
                if p['name']:
                    # Use first name as key
                    key = p['name'].split()[0].lower()
                    # Handle duplicates
                    if key in people:
                        key = f"{key}{i}"
                    people[key] = p['name']
                    handle_to_key[handle] = key
                else:
                    unknown_count += 1
                    key = f"unknown{unknown_count}"
                    people[key] = format_phone_display(handle)
                    handle_to_key[handle] = key

            # Convert time filters to Apple epoch
            since_apple = None
            before_apple = None

            if since:
                since_dt = parse_time_input(since)
                if since_dt:
                    since_apple = datetime_to_apple(since_dt)

            if before:
                before_dt = parse_time_input(before)
                if before_dt:
                    before_apple = datetime_to_apple(before_dt)

            # Resolve from_person to handle
            from_handle = None
            from_me_only = False

            # unanswered implies from_me_only (only my messages can be unanswered)
            if unanswered:
                from_me_only = True
            elif from_person:
                if from_person.lower() == "me":
                    from_me_only = True
                else:
                    from_handle = normalize_to_e164(from_person)
                    if not from_handle and resolver.is_available:
                        resolver.initialize()
                        # Use public search_by_name method instead of private _lookup
                        matches = resolver.search_by_name(from_person)
                        if matches:
                            from_handle = matches[0][0]

            # For unanswered filtering, we need to fetch more messages initially
            # since we'll filter some out, then apply limit after filtering
            fetch_limit = limit * 3 if unanswered else limit

            # Get messages
            message_rows = get_messages_for_chat(
                conn,
                numeric_chat_id,
                limit=fetch_limit,
                since_apple=since_apple,
                before_apple=before_apple,
                from_handle=from_handle,
                from_me_only=from_me_only,
                contains=contains,
            )

            # Filter for unanswered messages if requested
            if unanswered:
                filtered_rows = []
                for row in message_rows:
                    text = get_message_text(row['text'], row.get('attributedBody'))
                    # Check if message looks like a question and has no reply within 24h
                    if _looks_like_question(text) and not _has_reply_within_24h(
                        conn, numeric_chat_id, row['date']
                    ):
                        filtered_rows.append(row)
                        # Stop once we have enough
                        if len(filtered_rows) >= limit:
                            break
                message_rows = filtered_rows

            # Get reactions for messages
            reactions_map = {}
            if include_reactions and message_rows:
                message_guids = [m['guid'] for m in message_rows]
                reactions_map = get_reactions_for_messages(conn, message_guids)

            # Build response
            messages = []
            for row in message_rows:
                text = get_message_text(row['text'], row.get('attributedBody'))

                msg: dict[str, Any] = {
                    "id": f"msg_{row['id']}",
                    "ts": apple_to_datetime(row['date']).isoformat() if row['date'] else None,
                    "text": text,
                }

                # Add sender
                if row['is_from_me']:
                    msg["from"] = "me"
                elif row['sender_handle']:
                    msg["from"] = handle_to_key.get(row['sender_handle'], row['sender_handle'])

                # Add reactions if enabled
                if include_reactions and row['guid'] in reactions_map:
                    reactions = []
                    for r in reactions_map[row['guid']]:
                        reaction_type = get_reaction_type(r['type'])
                        if reaction_type and not reaction_type.startswith('removed'):
                            emoji = reaction_to_emoji(reaction_type)
                            if r['from_handle']:
                                from_key = handle_to_key.get(r['from_handle'], 'unknown')
                            else:
                                from_key = 'me'
                            reactions.append(f"{emoji} {from_key}")
                    if reactions:
                        msg["reactions"] = reactions

                # Extract links
                if text:
                    links = extract_links(text)
                    if links:
                        msg["links"] = links

                messages.append(msg)

            # Build chat info
            participant_objs = [
                Participant(handle=p['handle'], name=p['name'])
                for p in participant_rows
            ]
            display_name = chat_row['display_name'] or generate_display_name(participant_objs)

            return {
                "chat": {
                    "id": f"chat{numeric_chat_id}",
                    "name": display_name,
                },
                "people": people,
                "messages": messages,
                "more": len(messages) == limit,
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
