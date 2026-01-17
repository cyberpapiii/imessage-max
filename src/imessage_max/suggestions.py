"""Smart error suggestions for empty query results.

This module provides contextual suggestions when searches return no results,
helping users find what they're looking for by suggesting:
- Similar chat names (fuzzy matching)
- Chats by participants
- Chats by message content
- Expanded time ranges
- Alternative queries (spelling/nickname corrections)
- Other chats where the query would find results
"""

import logging
import sqlite3
from difflib import SequenceMatcher
from typing import Optional, Any
from .contacts import ContactResolver
from .time_utils import parse_time_input
from .db import datetime_to_apple, escape_like

logger = logging.getLogger(__name__)


# Use escape_like from db module (aliased for local use)
_escape_like = escape_like


def _similarity_ratio(a: str, b: str) -> float:
    """Calculate similarity ratio between two strings (0-1)."""
    return SequenceMatcher(None, a.lower(), b.lower()).ratio()


def find_similar_names(
    conn: sqlite3.Connection,
    query: str,
    limit: int = 3,
    min_similarity: float = 0.3
) -> list[dict[str, Any]]:
    """Find chats with names similar to the query.

    Uses fuzzy string matching to find chats whose display_name
    is similar to the search query.

    Args:
        conn: Database connection
        query: Name to search for
        limit: Maximum results to return
        min_similarity: Minimum similarity ratio (0-1) to include

    Returns:
        List of dicts with name, similarity, chat_id, and optional note
    """
    if not query or not query.strip():
        return []

    query = query.strip()

    # Get all chats with display names
    cursor = conn.execute("""
        SELECT ROWID as id, display_name
        FROM chat
        WHERE display_name IS NOT NULL AND display_name != ''
    """)

    results = []
    for row in cursor.fetchall():
        display_name = row['display_name']
        ratio = _similarity_ratio(query, display_name)

        # Also check if query is contained in name (case-insensitive)
        if query.lower() in display_name.lower():
            ratio = max(ratio, 0.7)  # Boost score for substring matches

        if ratio >= min_similarity:
            similarity_label = "high" if ratio >= 0.7 else "medium" if ratio >= 0.5 else "low"
            results.append({
                "name": display_name,
                "similarity": similarity_label,
                "chat_id": f"chat{row['id']}",
            })

    # Sort by similarity (high first) and limit
    similarity_order = {"high": 0, "medium": 1, "low": 2}
    results.sort(key=lambda x: similarity_order.get(x["similarity"], 3))

    return results[:limit]


def find_by_participants(
    conn: sqlite3.Connection,
    query: str,
    limit: int = 3
) -> list[dict[str, Any]]:
    """Find chats containing participants matching the query.

    Searches for handles (phone numbers/emails) that contain the query
    and returns the chats those handles belong to.

    Args:
        conn: Database connection
        query: Participant handle pattern to search for
        limit: Maximum results to return

    Returns:
        List of dicts with display_name_generated, chat_id, and note
    """
    if not query or not query.strip():
        return []

    query = query.strip()

    # Find handles matching the query
    cursor = conn.execute("""
        SELECT DISTINCT
            c.ROWID as chat_id,
            c.display_name,
            h.id as handle,
            GROUP_CONCAT(h.id) as all_handles
        FROM chat c
        JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
        JOIN handle h ON chj.handle_id = h.ROWID
        WHERE h.id LIKE ? ESCAPE '\\'
        GROUP BY c.ROWID
        LIMIT ?
    """, (f"%{_escape_like(query)}%", limit))

    results = []
    for row in cursor.fetchall():
        display_name = row['display_name']
        if not display_name:
            # Generate display name from handles
            display_name = row['handle']

        results.append({
            "display_name_generated": display_name,
            "chat_id": f"chat{row['chat_id']}",
            "note": f"Contains participant matching '{query}'",
        })

    return results


def find_by_content(
    conn: sqlite3.Connection,
    query: str,
    limit: int = 3
) -> list[dict[str, Any]]:
    """Find chats containing messages matching the query.

    Args:
        conn: Database connection
        query: Text content to search for
        limit: Maximum results to return

    Returns:
        List of dicts with display_name, chat_id, match_count, and note
    """
    if not query or not query.strip():
        return []

    query = query.strip()

    cursor = conn.execute("""
        SELECT
            c.ROWID as chat_id,
            c.display_name,
            COUNT(*) as match_count
        FROM chat c
        JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
        JOIN message m ON cmj.message_id = m.ROWID
        WHERE m.text LIKE ? ESCAPE '\\' COLLATE NOCASE
        AND m.associated_message_type = 0
        GROUP BY c.ROWID
        ORDER BY match_count DESC
        LIMIT ?
    """, (f"%{_escape_like(query)}%", limit))

    results = []
    for row in cursor.fetchall():
        display_name = row['display_name'] or f"Chat {row['chat_id']}"
        results.append({
            "display_name": display_name,
            "chat_id": f"chat{row['chat_id']}",
            "match_count": row['match_count'],
            "note": f"Found {row['match_count']} messages mentioning '{query}'",
        })

    return results


def suggest_expanded_time(
    conn: sqlite3.Connection,
    chat_id: Optional[int] = None,
    original_since: Optional[str] = None,
    query: Optional[str] = None,
) -> Optional[dict[str, Any]]:
    """Suggest a wider time range that would return results.

    Args:
        conn: Database connection
        chat_id: Optional chat ROWID to scope the search
        original_since: Original time filter (e.g., "24h", "7d")
        query: Optional text query to check against

    Returns:
        Dict with original, expanded, and would_find counts, or None
    """
    if not original_since:
        return None

    # Parse original time to get the timestamp
    original_dt = parse_time_input(original_since)
    if not original_dt:
        return None

    original_apple = datetime_to_apple(original_dt)

    # Define expansion tiers
    expansions = [
        ("last 7 days", "7d"),
        ("last 30 days", "30d"),
        ("last 90 days", "90d"),
        ("last year", "365d"),
    ]

    for expanded_label, expanded_since in expansions:
        expanded_dt = parse_time_input(expanded_since)
        if not expanded_dt:
            continue

        expanded_apple = datetime_to_apple(expanded_dt)

        # Don't suggest if expanded is narrower than original
        if expanded_apple >= original_apple:
            continue

        # Build query to count messages in expanded range
        sql = """
            SELECT COUNT(*) as count FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            WHERE m.date >= ? AND m.associated_message_type = 0
        """
        params: list[Any] = [expanded_apple]

        if chat_id is not None:
            sql += " AND cmj.chat_id = ?"
            params.append(chat_id)

        if query:
            sql += " AND m.text LIKE ? ESCAPE '\\' COLLATE NOCASE"
            params.append(f"%{_escape_like(query)}%")

        cursor = conn.execute(sql, params)
        row = cursor.fetchone()
        would_find = row['count'] if row else 0

        if would_find > 0:
            return {
                "original": original_since,
                "expanded": expanded_label,
                "would_find": would_find,
            }

    return None


def suggest_similar_query(
    conn: sqlite3.Connection,
    query: str,
    resolver: Optional[ContactResolver] = None,
) -> Optional[dict[str, Any]]:
    """Suggest alternative query based on similar terms found.

    Looks for nickname matches, spelling corrections, etc.

    Args:
        conn: Database connection
        query: Original search query
        resolver: Optional ContactResolver for name matching

    Returns:
        Dict with original, suggestion, would_find, and note, or None
    """
    if not query or not query.strip():
        return None

    query = query.strip()

    # Strategy 1: Check if a partial match in handles exists
    # e.g., "Michael" -> "mike" in mike@example.com
    query_lower = query.lower()

    # Look for handles that contain parts of the query
    cursor = conn.execute("""
        SELECT h.id as handle
        FROM handle h
        WHERE LOWER(h.id) LIKE ? ESCAPE '\\'
        LIMIT 1
    """, (f"%{_escape_like(query_lower[:3])}%",))

    row = cursor.fetchone()
    if row:
        handle = row['handle']
        # Extract potential name from handle
        if '@' in handle:
            # Email - use local part
            potential_name = handle.split('@')[0]
        elif handle.startswith('+'):
            # Phone number - not useful for name suggestion
            potential_name = None
        else:
            potential_name = handle

        if potential_name and potential_name.lower() != query_lower:
            # Check if this would find results
            cursor = conn.execute("""
                SELECT COUNT(*) as count FROM message m
                JOIN handle h ON m.handle_id = h.ROWID
                WHERE h.id LIKE ? ESCAPE '\\' COLLATE NOCASE
            """, (f"%{_escape_like(potential_name)}%",))

            count_row = cursor.fetchone()
            would_find = count_row['count'] if count_row else 0

            if would_find > 0:
                return {
                    "original": query,
                    "suggestion": potential_name,
                    "would_find": would_find,
                    "note": f"Found '{potential_name}' in handles",
                }

    # Strategy 2: Look for similar text in recent messages
    cursor = conn.execute("""
        SELECT DISTINCT m.text
        FROM message m
        WHERE m.text LIKE ? ESCAPE '\\' COLLATE NOCASE
        AND m.associated_message_type = 0
        LIMIT 100
    """, (f"%{_escape_like(query_lower[:3])}%",))

    for row in cursor.fetchall():
        text = row['text']
        if text:
            # Find words similar to query
            words = text.split()
            for word in words:
                word_clean = ''.join(c for c in word if c.isalnum())
                if word_clean and len(word_clean) >= 3:
                    ratio = _similarity_ratio(query, word_clean)
                    if ratio >= 0.6 and word_clean.lower() != query_lower:
                        # Check if this would find more results
                        cursor2 = conn.execute("""
                            SELECT COUNT(*) as count FROM message m
                            WHERE m.text LIKE ? ESCAPE '\\' COLLATE NOCASE
                        """, (f"%{_escape_like(word_clean)}%",))

                        count_row = cursor2.fetchone()
                        would_find = count_row['count'] if count_row else 0

                        if would_find > 0:
                            return {
                                "original": query,
                                "suggestion": word_clean,
                                "would_find": would_find,
                                "note": f"Similar term found in messages",
                            }

    return None


def suggest_renamed_chat(
    conn: sqlite3.Connection,
    search_name: str,
    limit: int = 3,
) -> list[dict[str, Any]]:
    """
    Suggest chats that may have been renamed from the search term.

    NOTE: The iMessage chat.db does not track historical display_name changes,
    so this function cannot detect actual renames. It returns an empty list.

    If Apple adds rename tracking in the future, this function can be enhanced
    to detect old_name -> new_name mappings.

    Args:
        conn: Database connection
        search_name: The name that was searched for
        limit: Maximum suggestions to return

    Returns:
        Empty list (rename tracking not available in chat.db)
    """
    # iMessage chat.db does not store historical display_name changes
    # This would require either:
    # 1. A separate tracking table (we have read-only access)
    # 2. Apple adding rename events to the message table
    # 3. An external cache of previous chat names
    return []


def suggest_other_chats(
    conn: sqlite3.Connection,
    query: str,
    exclude_chat_id: Optional[int] = None,
    limit: int = 3
) -> list[dict[str, Any]]:
    """Find other chats where the query would return results.

    Args:
        conn: Database connection
        query: Text query to search for
        exclude_chat_id: Chat ROWID to exclude from results
        limit: Maximum results to return

    Returns:
        List of dicts with chat, match_count, and note
    """
    if not query or not query.strip():
        return []

    query = query.strip()

    sql = """
        SELECT
            c.ROWID as chat_id,
            c.display_name,
            COUNT(*) as match_count
        FROM chat c
        JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
        JOIN message m ON cmj.message_id = m.ROWID
        WHERE m.text LIKE ? ESCAPE '\\' COLLATE NOCASE
        AND m.associated_message_type = 0
    """
    params: list[Any] = [f"%{_escape_like(query)}%"]

    if exclude_chat_id is not None:
        sql += " AND c.ROWID != ?"
        params.append(exclude_chat_id)

    sql += """
        GROUP BY c.ROWID
        ORDER BY match_count DESC
        LIMIT ?
    """
    params.append(limit)

    cursor = conn.execute(sql, params)

    results = []
    for row in cursor.fetchall():
        display_name = row['display_name'] or f"Chat {row['chat_id']}"
        results.append({
            "chat": f"chat{row['chat_id']}",
            "chat_name": display_name,
            "match_count": row['match_count'],
            "note": f"Found {row['match_count']} matches in different chat",
        })

    return results


def get_chat_suggestions(
    conn: sqlite3.Connection,
    resolver: Optional[ContactResolver],
    name: Optional[str] = None,
    participants: Optional[list[str]] = None,
    contains_recent: Optional[str] = None,
) -> dict[str, Any]:
    """Get suggestions when find_chat returns no results.

    Args:
        conn: Database connection
        resolver: ContactResolver for name matching
        name: Chat name that was searched for
        participants: Participant handles that were searched for
        contains_recent: Message content that was searched for

    Returns:
        Dict with suggestion types: similar_names, by_participants, by_content
    """
    suggestions: dict[str, Any] = {}

    try:
        # Similar names (when searching by name)
        if name:
            similar = find_similar_names(conn, name, limit=3)
            if similar:
                suggestions["similar_names"] = similar

        # By participants (when searching by participants or name)
        if participants:
            for p in participants[:3]:  # Limit to first 3 participants
                by_participants = find_by_participants(conn, p, limit=3)
                if by_participants:
                    suggestions.setdefault("by_participants", [])
                    suggestions["by_participants"].extend(by_participants)
            # Dedupe and limit
            if "by_participants" in suggestions:
                seen = set()
                unique = []
                for item in suggestions["by_participants"]:
                    if item["chat_id"] not in seen:
                        seen.add(item["chat_id"])
                        unique.append(item)
                suggestions["by_participants"] = unique[:3]

        # By content (when searching by content)
        if contains_recent:
            by_content = find_by_content(conn, contains_recent, limit=3)
            if by_content:
                suggestions["by_content"] = by_content

        # If nothing found via name, try finding by content with the name as query
        if name and not suggestions.get("similar_names") and not suggestions.get("by_content"):
            by_content = find_by_content(conn, name, limit=3)
            if by_content:
                suggestions["by_content"] = by_content

        # Renamed chat suggestions (for spec compliance)
        # Note: Returns empty list as chat.db doesn't track historical display_name changes
        if name:
            renamed = suggest_renamed_chat(conn, name, limit=3)
            if renamed:
                suggestions["renamed_chat"] = renamed

    except Exception as e:
        # Gracefully handle any errors in suggestion generation
        logger.debug(f"Error generating chat suggestions: {e}")

    return suggestions


def get_message_suggestions(
    conn: sqlite3.Connection,
    resolver: Optional[ContactResolver],
    query: Optional[str] = None,
    chat_id: Optional[int] = None,
    since: Optional[str] = None,
    from_person: Optional[str] = None,
) -> dict[str, Any]:
    """Get suggestions when get_messages or search returns no results.

    Args:
        conn: Database connection
        resolver: ContactResolver for name matching
        query: Text query that was searched for
        chat_id: Numeric chat ID that was searched within
        since: Time filter that was used
        from_person: Person filter that was used

    Returns:
        Dict with suggestion types: expanded_time, similar_query, other_chats
    """
    suggestions: dict[str, Any] = {}

    try:
        # Expanded time range
        if since and query:
            expanded = suggest_expanded_time(conn, chat_id, since, query)
            if expanded and expanded.get("would_find", 0) > 0:
                suggestions["expanded_time"] = expanded

        # Similar query (spelling/nickname)
        if query:
            similar = suggest_similar_query(conn, query, resolver)
            if similar:
                suggestions["similar_query"] = similar

        # Other chats with matches
        if query and chat_id is not None:
            other_chats = suggest_other_chats(conn, query, exclude_chat_id=chat_id, limit=3)
            if other_chats:
                suggestions["other_chats"] = other_chats
        elif query:
            # No specific chat - just find where the query appears
            other_chats = suggest_other_chats(conn, query, limit=3)
            if other_chats:
                suggestions["other_chats"] = other_chats

    except Exception as e:
        # Gracefully handle any errors in suggestion generation
        logger.debug(f"Error generating message suggestions: {e}")

    return suggestions
