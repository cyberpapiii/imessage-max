"""send tool implementation."""

import subprocess
from datetime import datetime, timezone
from typing import Optional, Any

from ..db import get_db_connection, apple_to_datetime, DB_PATH
from ..contacts import ContactResolver
from ..phone import normalize_to_e164, format_phone_display, is_phone_number, is_email
from ..queries import get_chat_by_id, get_chat_participants
from ..time_utils import format_compact_relative


def _escape_applescript(s: str) -> str:
    """
    Escape a string for safe use in AppleScript.

    Handles:
    - Backslashes (must be escaped first)
    - Double quotes
    - Newlines and carriage returns (replaced with spaces)
    """
    # Escape backslashes first, then quotes
    result = s.replace("\\", "\\\\").replace('"', '\\"')
    # Replace newlines with spaces
    result = result.replace('\n', ' ').replace('\r', ' ')
    return result


def _send_via_applescript(recipient: str, message: str) -> dict:
    """
    Send message via AppleScript.

    Args:
        recipient: Phone number, email, or chat GUID
        message: Message text to send

    Returns:
        Dict with success=True or error details
    """
    escaped_recipient = _escape_applescript(recipient)
    escaped_message = _escape_applescript(message)

    script = f'''
    tell application "Messages"
        set targetService to 1st account whose service type = iMessage
        set targetBuddy to participant "{escaped_recipient}" of targetService
        send "{escaped_message}" to targetBuddy
    end tell
    '''

    try:
        result = subprocess.run(
            ['osascript', '-e', script],
            capture_output=True,
            text=True,
            timeout=30
        )
        if result.returncode != 0:
            return {"error": "send_failed", "message": result.stderr}
        return {"success": True}
    except subprocess.TimeoutExpired:
        return {"error": "timeout", "message": "Send operation timed out"}
    except Exception as e:
        return {"error": "internal_error", "message": str(e)}


def _resolve_recipient(
    to: str,
    db_path: str = DB_PATH,
    resolver: Optional[ContactResolver] = None
) -> dict:
    """
    Resolve a recipient identifier to a handle.

    Args:
        to: Contact name, phone number, or email
        db_path: Path to chat.db
        resolver: Optional ContactResolver for name lookups

    Returns:
        Dict with handle info or error details
    """
    if resolver is None:
        resolver = ContactResolver()
        if resolver.is_available:
            resolver.initialize()  # Explicitly initialize to trigger auth check

    # Check if it's a phone number
    if is_phone_number(to) or to.startswith('+'):
        normalized = normalize_to_e164(to)
        if normalized:
            # Verify handle exists in database
            try:
                with get_db_connection(db_path) as conn:
                    cursor = conn.execute(
                        "SELECT id FROM handle WHERE id = ?",
                        (normalized,)
                    )
                    row = cursor.fetchone()
                    if row:
                        return {
                            "handle": normalized,
                            "type": "phone"
                        }

                    # Also try with original format
                    cursor = conn.execute(
                        "SELECT id FROM handle WHERE id = ?",
                        (to,)
                    )
                    row = cursor.fetchone()
                    if row:
                        return {
                            "handle": to,
                            "type": "phone"
                        }
            except FileNotFoundError:
                pass

            return {
                "error": "recipient_not_found",
                "message": f"No conversation found with {to}"
            }

    # Check if it's an email
    if is_email(to):
        try:
            with get_db_connection(db_path) as conn:
                cursor = conn.execute(
                    "SELECT id FROM handle WHERE LOWER(id) = LOWER(?)",
                    (to,)
                )
                row = cursor.fetchone()
                if row:
                    return {
                        "handle": row['id'],
                        "type": "email"
                    }
        except FileNotFoundError:
            pass

        return {
            "error": "recipient_not_found",
            "message": f"No conversation found with {to}"
        }

    # It's a name - search contacts
    if not resolver.is_available:
        return {
            "error": "contacts_unavailable",
            "message": "Cannot search by name without contacts access"
        }

    # Search for matching contacts using public API
    search_results = resolver.search_by_name(to)
    matches = [{"handle": handle, "name": name} for handle, name in search_results]

    if len(matches) == 0:
        return {
            "error": "recipient_not_found",
            "message": f"No contact found matching '{to}'"
        }

    if len(matches) == 1:
        return {
            "handle": matches[0]["handle"],
            "name": matches[0]["name"],
            "type": "contact"
        }

    # Multiple matches - need disambiguation
    return {
        "error": "ambiguous_recipient",
        "matches": matches
    }


def _get_last_contact_time(conn, handle: str) -> Optional[datetime]:
    """Get the last message time for a handle."""
    cursor = conn.execute("""
        SELECT m.date
        FROM message m
        JOIN handle h ON m.handle_id = h.ROWID
        WHERE h.id = ?
        ORDER BY m.date DESC
        LIMIT 1
    """, (handle,))

    row = cursor.fetchone()
    if row:
        return apple_to_datetime(row['date'])
    return None


def _find_chat_for_handle(conn, handle: str) -> Optional[int]:
    """Find the chat ID for a 1:1 conversation with a handle."""
    cursor = conn.execute("""
        SELECT c.ROWID
        FROM chat c
        JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
        JOIN handle h ON chj.handle_id = h.ROWID
        WHERE h.id = ?
        GROUP BY c.ROWID
        HAVING COUNT(DISTINCT chj.handle_id) = 1
        LIMIT 1
    """, (handle,))

    row = cursor.fetchone()
    if row:
        return row['ROWID']

    # If no 1:1 chat, get any chat with this handle
    cursor = conn.execute("""
        SELECT c.ROWID
        FROM chat c
        JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
        JOIN handle h ON chj.handle_id = h.ROWID
        WHERE h.id = ?
        ORDER BY c.ROWID DESC
        LIMIT 1
    """, (handle,))

    row = cursor.fetchone()
    return row['ROWID'] if row else None


def send_impl(
    to: Optional[str] = None,
    chat_id: Optional[str] = None,
    text: Optional[str] = None,
    reply_to: Optional[str] = None,
    db_path: str = DB_PATH,
) -> dict[str, Any]:
    """
    Send a message to a person or group chat.

    Args:
        to: Contact name, phone number, or email
        chat_id: Existing chat ID (for group chats or when `to` is ambiguous)
        text: Message content
        reply_to: Message ID to reply to (not implemented yet)
        db_path: Path to chat.db (for testing)

    Returns:
        Dict with success info or error details
    """
    # Validation
    if not to and not chat_id:
        return {
            "error": "validation_error",
            "message": "Either 'to' or 'chat_id' must be provided"
        }

    if not text:
        return {
            "error": "validation_error",
            "message": "Message 'text' is required"
        }

    resolver = ContactResolver()
    if resolver.is_available:
        resolver.initialize()  # Explicitly initialize to trigger auth check
    recipient_handle = None
    target_chat_id = None
    delivered_to = []

    try:
        with get_db_connection(db_path) as conn:
            # Resolve recipient from chat_id
            if chat_id:
                # Extract numeric ID from chat_id (e.g., "chat123" -> 123)
                try:
                    numeric_id = int(chat_id.replace('chat', ''))
                except ValueError:
                    return {
                        "error": "validation_error",
                        "message": f"Invalid chat_id format: {chat_id}"
                    }

                chat_info = get_chat_by_id(conn, numeric_id)
                if not chat_info:
                    return {
                        "error": "chat_not_found",
                        "message": f"Chat not found: {chat_id}"
                    }

                target_chat_id = numeric_id

                # Get participants for the chat
                participants = get_chat_participants(conn, numeric_id, resolver)
                if participants:
                    # For group chats, use the chat GUID; for DMs, use the handle
                    if len(participants) == 1:
                        recipient_handle = participants[0]['handle']
                        name = participants[0].get('name') or format_phone_display(recipient_handle)
                        delivered_to.append(name)
                    else:
                        # Group chat - use the first handle (AppleScript will route to group)
                        recipient_handle = participants[0]['handle']
                        for p in participants:
                            name = p.get('name') or format_phone_display(p['handle'])
                            delivered_to.append(name)
                else:
                    return {
                        "error": "chat_not_found",
                        "message": f"No participants found for chat: {chat_id}"
                    }

            # Resolve recipient from 'to' parameter
            elif to:
                result = _resolve_recipient(to, db_path, resolver)

                if 'error' in result:
                    if result['error'] == 'ambiguous_recipient':
                        # Build candidate list with last contact times
                        candidates = []
                        for match in result['matches']:
                            last_time = _get_last_contact_time(conn, match['handle'])
                            candidates.append({
                                "name": match['name'],
                                "handle": match['handle'],
                                "last_contact": format_compact_relative(last_time) if last_time else "never",
                                "_sort_ts": last_time  # Store raw timestamp for sorting
                            })
                        # Sort by most recent contact (most recent first, never = oldest)
                        candidates.sort(
                            key=lambda x: x['_sort_ts'] if x['_sort_ts'] else datetime.min.replace(tzinfo=timezone.utc),
                            reverse=True
                        )
                        # Remove internal sort key before returning
                        for c in candidates:
                            c.pop('_sort_ts', None)

                        return {
                            "success": False,
                            "error": "ambiguous_recipient",
                            "candidates": candidates
                        }
                    return result

                recipient_handle = result['handle']
                name = result.get('name') or format_phone_display(recipient_handle)
                delivered_to.append(name)

                # Find associated chat ID
                target_chat_id = _find_chat_for_handle(conn, recipient_handle)

    except FileNotFoundError:
        return {
            "error": "database_not_found",
            "message": f"Database not found at {db_path}"
        }
    except Exception as e:
        return {
            "error": "internal_error",
            "message": str(e)
        }

    if not recipient_handle:
        return {
            "error": "internal_error",
            "message": "Could not determine recipient"
        }

    # Send the message
    send_result = _send_via_applescript(recipient_handle, text)

    if 'error' in send_result:
        return send_result

    # Build success response
    response = {
        "success": True,
        "message_id": None,  # Cannot reliably retrieve new message ID
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "delivered_to": delivered_to,
    }

    if target_chat_id:
        response["chat_id"] = f"chat{target_chat_id}"

    return response
