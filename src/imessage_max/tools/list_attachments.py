"""list_attachments tool implementation."""

from typing import Optional, Any
from ..db import get_db_connection, apple_to_datetime, datetime_to_apple, escape_like, DB_PATH
from ..contacts import ContactResolver
from ..time_utils import parse_time_input, format_compact_relative
from ..parsing import get_message_text


def _format_file_size(bytes_size: Optional[int]) -> str:
    """Format file size in human-readable format."""
    if bytes_size is None or bytes_size <= 0:
        return "0 B"

    size = float(bytes_size)
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size < 1024:
            if unit == 'B':
                return f"{int(size)} {unit}"
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} TB"


# Use escape_like from db module (aliased for local use)
_escape_like = escape_like


def _get_attachment_type(mime_type: Optional[str], uti: Optional[str]) -> str:
    """Determine attachment type from MIME type or UTI."""
    if not mime_type and not uti:
        return "other"

    mime = (mime_type or "").lower()
    uti_str = (uti or "").lower()

    if "image" in mime or "image" in uti_str or "jpeg" in uti_str or "png" in uti_str:
        return "image"
    elif "video" in mime or "movie" in uti_str or "video" in uti_str:
        return "video"
    elif "audio" in mime or "audio" in uti_str:
        return "audio"
    elif "pdf" in mime or "pdf" in uti_str:
        return "pdf"
    elif any(x in mime for x in ["document", "msword", "spreadsheet", "presentation"]):
        return "document"
    else:
        return "other"


def list_attachments_impl(
    chat_id: Optional[str] = None,
    from_person: Optional[str] = None,
    type: Optional[str] = None,
    since: Optional[str] = None,
    before: Optional[str] = None,
    limit: int = 50,
    sort: str = "recent_first",
    db_path: str = DB_PATH,
) -> dict[str, Any]:
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
        db_path: Path to chat.db (for testing)

    Returns:
        Dict with attachments, people map, total count, and pagination info
    """
    # Validate and constrain inputs
    limit = max(1, min(limit, 100))
    if sort not in ("recent_first", "oldest_first", "largest_first"):
        sort = "recent_first"

    valid_types = {"image", "video", "audio", "pdf", "document", "link", "any", None}
    if type not in valid_types:
        type = None  # Treat invalid type as "any"

    resolver = ContactResolver()
    if resolver.is_available:
        resolver.initialize()  # Explicitly initialize to trigger auth check

    try:
        with get_db_connection(db_path) as conn:
            # Build attachment query
            query = """
                SELECT
                    a.ROWID as att_id,
                    a.filename,
                    a.mime_type,
                    a.uti,
                    a.total_bytes,
                    m.ROWID as msg_id,
                    m.text,
                    m.attributedBody,
                    m.date,
                    m.is_from_me,
                    h.id as sender_handle,
                    c.ROWID as chat_id,
                    c.display_name as chat_name
                FROM attachment a
                JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
                JOIN message m ON maj.message_id = m.ROWID
                JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
                JOIN chat c ON cmj.chat_id = c.ROWID
                LEFT JOIN handle h ON m.handle_id = h.ROWID
                WHERE 1=1
            """

            params: list[Any] = []

            # Chat filter
            if chat_id:
                cid = chat_id.replace("chat", "") if chat_id.startswith("chat") else chat_id
                try:
                    query += " AND c.ROWID = ?"
                    params.append(int(cid))
                except ValueError:
                    # If chat_id is invalid format, return error
                    return {
                        "error": "invalid_id",
                        "message": f"Invalid chat ID format: {chat_id}",
                    }

            # From filter
            if from_person:
                if from_person.lower() == "me":
                    query += " AND m.is_from_me = 1"
                else:
                    query += " AND h.id LIKE ? ESCAPE '\\'"
                    params.append(f"%{_escape_like(from_person)}%")

            # Time filters
            if since:
                since_dt = parse_time_input(since)
                if since_dt:
                    query += " AND m.date >= ?"
                    params.append(datetime_to_apple(since_dt))

            if before:
                before_dt = parse_time_input(before)
                if before_dt:
                    query += " AND m.date <= ?"
                    params.append(datetime_to_apple(before_dt))

            # Sort order
            if sort == "recent_first":
                query += " ORDER BY m.date DESC"
            elif sort == "oldest_first":
                query += " ORDER BY m.date ASC"
            elif sort == "largest_first":
                query += " ORDER BY a.total_bytes DESC"

            # Fetch more than limit to allow for type filtering
            fetch_limit = limit * 3
            query += " LIMIT ?"
            params.append(fetch_limit)

            cursor = conn.execute(query, params)
            rows = cursor.fetchall()

            # Build results
            attachments: list[dict[str, Any]] = []
            people: dict[str, dict[str, Any]] = {}
            handle_to_key: dict[str, str] = {}
            person_counter = 1

            for row in rows:
                if len(attachments) >= limit:
                    break

                att_type = _get_attachment_type(row['mime_type'], row['uti'])

                # Type filter
                if type and type != "any":
                    if type == "link":
                        continue  # Links are not in attachment table
                    if att_type != type:
                        continue

                # Get person key
                if row['is_from_me']:
                    sender_key = "me"
                    if "me" not in people:
                        people["me"] = {"name": "Me", "is_me": True}
                else:
                    handle = row['sender_handle'] or "unknown"
                    if handle not in handle_to_key:
                        key = f"p{person_counter}"
                        person_counter += 1
                        handle_to_key[handle] = key
                        name = None
                        if resolver.is_available:
                            name = resolver.resolve(handle)
                        people[key] = {
                            "name": name or handle,
                            "handle": handle,
                        }
                    sender_key = handle_to_key[handle]

                msg_dt = apple_to_datetime(row['date'])
                msg_text = get_message_text(row['text'], row['attributedBody'])

                # Extract filename from path
                filename = row['filename']
                if filename:
                    filename = filename.split('/')[-1]

                att: dict[str, Any] = {
                    "id": f"att{row['att_id']}",
                    "type": att_type,
                    "mime": row['mime_type'],
                    "name": filename,
                    "size": row['total_bytes'],
                    "size_human": _format_file_size(row['total_bytes']),
                    "ts": msg_dt.isoformat() if msg_dt else None,
                    "ago": format_compact_relative(msg_dt),
                    "from": sender_key,
                    "chat": f"chat{row['chat_id']}",
                    "msg_id": f"msg{row['msg_id']}",
                    "msg_preview": (msg_text or "")[:50] if msg_text else None,
                }

                attachments.append(att)

            return {
                "attachments": attachments,
                "people": people,
                "total": len(attachments),
                "more": len(rows) >= fetch_limit,
                "cursor": None,
            }

    except FileNotFoundError:
        return {"error": "database_not_found", "message": f"Database not found at {db_path}"}
    except Exception as e:
        return {"error": "internal_error", "message": str(e)}
