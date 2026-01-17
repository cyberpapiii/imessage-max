"""SQL query building utilities for iMessage MCP."""

import sqlite3
from typing import Any, Optional
from .contacts import ContactResolver
from .db import escape_like


class QueryBuilder:
    """Fluent SQL query builder for composing complex queries."""

    def __init__(self):
        self._select: list[str] = []
        self._from: str = ""
        self._joins: list[str] = []
        self._where: list[tuple[str, list]] = []
        self._group_by: list[str] = []
        self._order_by: list[str] = []
        self._limit: Optional[int] = None
        self._offset: Optional[int] = None

    def select(self, *columns: str) -> "QueryBuilder":
        """Add columns to SELECT clause."""
        self._select.extend(columns)
        return self

    def from_table(self, table: str) -> "QueryBuilder":
        """Set the FROM clause."""
        self._from = table
        return self

    def join(self, join_clause: str) -> "QueryBuilder":
        """Add an INNER JOIN clause."""
        self._joins.append(f"JOIN {join_clause}")
        return self

    def left_join(self, join_clause: str) -> "QueryBuilder":
        """Add a LEFT JOIN clause."""
        self._joins.append(f"LEFT JOIN {join_clause}")
        return self

    def where(self, condition: str, *params: Any) -> "QueryBuilder":
        """Add a WHERE condition (multiple conditions are ANDed)."""
        self._where.append((condition, list(params)))
        return self

    def group_by(self, *columns: str) -> "QueryBuilder":
        """Add GROUP BY columns."""
        self._group_by.extend(columns)
        return self

    def order_by(self, *columns: str) -> "QueryBuilder":
        """Add ORDER BY columns."""
        self._order_by.extend(columns)
        return self

    def limit(self, n: int) -> "QueryBuilder":
        """Set LIMIT clause."""
        self._limit = n
        return self

    def offset(self, n: int) -> "QueryBuilder":
        """Set OFFSET clause."""
        self._offset = n
        return self

    def build(self) -> tuple[str, list]:
        """Build the SQL query string and parameters.

        Returns:
            Tuple of (query_string, parameters_list)
        """
        parts = []
        params: list[Any] = []

        # SELECT
        parts.append(f"SELECT {', '.join(self._select)}")

        # FROM
        parts.append(f"FROM {self._from}")

        # JOINs
        for join in self._joins:
            parts.append(join)

        # WHERE
        if self._where:
            conditions = []
            for condition, condition_params in self._where:
                conditions.append(condition)
                params.extend(condition_params)
            parts.append(f"WHERE {' AND '.join(conditions)}")

        # GROUP BY
        if self._group_by:
            parts.append(f"GROUP BY {', '.join(self._group_by)}")

        # ORDER BY
        if self._order_by:
            parts.append(f"ORDER BY {', '.join(self._order_by)}")

        # LIMIT
        if self._limit is not None:
            parts.append(f"LIMIT {self._limit}")

        # OFFSET
        if self._offset is not None:
            parts.append(f"OFFSET {self._offset}")

        return '\n'.join(parts), params


def get_chat_by_id(conn: sqlite3.Connection, chat_id: int) -> Optional[dict]:
    """Get chat info by ROWID.

    Args:
        conn: Database connection
        chat_id: Chat ROWID

    Returns:
        Chat dict with id, guid, display_name, service_name, participant_count
        or None if not found
    """
    cursor = conn.execute("""
        SELECT c.ROWID as id, c.guid, c.display_name, c.service_name,
               COUNT(DISTINCT chj.handle_id) as participant_count
        FROM chat c
        LEFT JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
        WHERE c.ROWID = ?
        GROUP BY c.ROWID
    """, (chat_id,))

    row = cursor.fetchone()
    if row:
        return dict(row)
    return None


def get_chat_participants(
    conn: sqlite3.Connection,
    chat_id: int,
    resolver: Optional[ContactResolver] = None
) -> list[dict]:
    """Get all participants for a chat with resolved names.

    Args:
        conn: Database connection
        chat_id: Chat ROWID
        resolver: Optional ContactResolver for name lookup

    Returns:
        List of participant dicts with handle_id, handle, name, service, in_contacts
    """
    cursor = conn.execute("""
        SELECT h.ROWID, h.id as handle, h.service
        FROM chat_handle_join chj
        JOIN handle h ON chj.handle_id = h.ROWID
        WHERE chj.chat_id = ?
    """, (chat_id,))

    participants = []
    for row in cursor.fetchall():
        handle = row['handle']
        name = resolver.resolve(handle) if resolver else None
        participants.append({
            'handle_id': row['ROWID'],
            'handle': handle,
            'name': name,
            'service': row['service'],
            'in_contacts': name is not None,
        })

    return participants


def find_chats_by_handles(
    conn: sqlite3.Connection,
    handles: list[str]
) -> list[dict]:
    """Find chats containing ALL specified handles.

    Args:
        conn: Database connection
        handles: List of handle identifiers (phone/email)

    Returns:
        List of chat dicts matching the criteria
    """
    if not handles:
        return []

    placeholders = ','.join('?' * len(handles))
    cursor = conn.execute(f"""
        SELECT c.ROWID as id, c.guid, c.display_name, c.service_name
        FROM chat c
        WHERE c.ROWID IN (
            SELECT chat_id
            FROM chat_handle_join chj
            JOIN handle h ON chj.handle_id = h.ROWID
            WHERE h.id IN ({placeholders})
            GROUP BY chat_id
            HAVING COUNT(DISTINCT h.id) = ?
        )
    """, (*handles, len(handles)))

    return [dict(row) for row in cursor.fetchall()]


def get_messages_for_chat(
    conn: sqlite3.Connection,
    chat_id: int,
    limit: int = 50,
    since_apple: Optional[int] = None,
    before_apple: Optional[int] = None,
    from_handle: Optional[str] = None,
    from_me_only: bool = False,
    contains: Optional[str] = None,
) -> list[dict]:
    """Get messages from a chat with optional filters.

    Args:
        conn: Database connection
        chat_id: Chat ROWID
        limit: Maximum messages to return (default 50)
        since_apple: Filter messages after this Apple timestamp
        before_apple: Filter messages before this Apple timestamp
        from_handle: Filter by sender handle
        from_me_only: Filter to only messages from "me" (is_from_me = 1)
        contains: Filter by text content (case-insensitive LIKE)

    Returns:
        List of message dicts ordered by date DESC (most recent first)
    """
    qb = QueryBuilder()
    qb.select(
        "m.ROWID as id",
        "m.guid",
        "m.text",
        "m.attributedBody",
        "m.date",
        "m.is_from_me",
        "m.associated_message_type",
        "m.associated_message_guid",
        "h.id as sender_handle"
    )
    qb.from_table("message m")
    qb.join("chat_message_join cmj ON m.ROWID = cmj.message_id")
    qb.left_join("handle h ON m.handle_id = h.ROWID")
    qb.where("cmj.chat_id = ?", chat_id)
    qb.where("m.associated_message_type = 0")  # Exclude reactions

    if since_apple is not None:
        qb.where("m.date >= ?", since_apple)

    if before_apple is not None:
        qb.where("m.date < ?", before_apple)

    if from_me_only:
        qb.where("m.is_from_me = 1")
    elif from_handle is not None:
        qb.where("h.id = ?", from_handle)

    if contains is not None:
        qb.where("m.text LIKE ? ESCAPE '\\'", f"%{escape_like(contains)}%")

    qb.order_by("m.date DESC")
    qb.limit(limit)

    query, params = qb.build()
    cursor = conn.execute(query, params)

    return [dict(row) for row in cursor.fetchall()]


def get_reactions_for_messages(
    conn: sqlite3.Connection,
    message_guids: list[str]
) -> dict[str, list[dict]]:
    """Get reactions grouped by original message GUID.

    Reaction types (associated_message_type):
        2000: Loved
        2001: Liked
        2002: Disliked
        2003: Laughed
        2004: Emphasized
        2005: Questioned
        3000-3005: Removal of above reactions

    Args:
        conn: Database connection
        message_guids: List of message GUIDs to find reactions for

    Returns:
        Dict mapping message GUID to list of reaction dicts
    """
    if not message_guids:
        return {}

    placeholders = ','.join('?' * len(message_guids))
    cursor = conn.execute(f"""
        SELECT
            m.associated_message_guid,
            m.associated_message_type,
            h.id as from_handle,
            m.date
        FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        WHERE m.associated_message_guid IN ({placeholders})
        AND m.associated_message_type >= 2000
        AND m.associated_message_type < 3000
        ORDER BY m.date
    """, tuple(message_guids))

    reactions: dict[str, list[dict]] = {}
    for row in cursor.fetchall():
        guid = row['associated_message_guid']
        if guid not in reactions:
            reactions[guid] = []
        reactions[guid].append({
            'type': row['associated_message_type'],
            'from_handle': row['from_handle'],
            'date': row['date'],
        })

    return reactions
