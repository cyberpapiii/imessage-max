"""get_messages tool implementation."""

from typing import Optional, Any
from ..db import get_db_connection, apple_to_datetime, datetime_to_apple, DB_PATH
from ..contacts import ContactResolver
from ..phone import normalize_to_e164, format_phone_display
from ..queries import get_chat_participants, get_messages_for_chat, get_reactions_for_messages
from ..parsing import get_message_text, get_reaction_type, reaction_to_emoji, extract_links
from ..time_utils import parse_time_input
from ..models import Participant, generate_display_name


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
            if from_person:
                if from_person.lower() == "me":
                    # Special handling for "me" - filter by is_from_me later
                    pass
                else:
                    from_handle = normalize_to_e164(from_person)
                    if not from_handle and resolver.is_available:
                        resolver.initialize()
                        for handle, name in (resolver._lookup or {}).items():
                            if from_person.lower() in name.lower():
                                from_handle = handle
                                break

            # Get messages
            message_rows = get_messages_for_chat(
                conn,
                numeric_chat_id,
                limit=limit,
                since_apple=since_apple,
                before_apple=before_apple,
                from_handle=from_handle,
                contains=contains,
            )

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
