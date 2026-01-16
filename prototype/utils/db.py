"""
Database connection utilities for iMessage chat.db

Safe read-only access patterns with proper connection lifecycle management.
"""

import sqlite3
import os
from contextlib import contextmanager
from datetime import datetime, timezone, timedelta
from typing import Generator, Any

# Default database path
DB_PATH = os.path.expanduser("~/Library/Messages/chat.db")

# Apple epoch (2001-01-01 00:00:00 UTC)
APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)


def apple_to_datetime(apple_timestamp: int) -> datetime:
    """Convert Apple epoch nanoseconds to Python datetime."""
    if apple_timestamp is None:
        return None
    seconds = apple_timestamp / 1_000_000_000
    return APPLE_EPOCH + timedelta(seconds=seconds)


def datetime_to_apple(dt: datetime) -> int:
    """Convert Python datetime to Apple epoch nanoseconds."""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    delta = dt - APPLE_EPOCH
    return int(delta.total_seconds() * 1_000_000_000)


@contextmanager
def get_db_connection(db_path: str = DB_PATH) -> Generator[sqlite3.Connection, None, None]:
    """
    Open database connection in read-only mode with safe settings.

    Uses URI mode for read-only access and appropriate timeouts.
    Connection is closed immediately after use.

    Args:
        db_path: Path to chat.db file

    Yields:
        sqlite3.Connection object

    Raises:
        sqlite3.Error: If database cannot be opened
        FileNotFoundError: If database file doesn't exist
    """
    if not os.path.exists(db_path):
        raise FileNotFoundError(f"Database not found: {db_path}")

    # Use URI mode with read-only flag
    conn = sqlite3.connect(
        f"file:{db_path}?mode=ro",
        uri=True,
        timeout=5.0  # 5 second timeout
    )
    conn.row_factory = sqlite3.Row

    # Additional safety pragmas
    conn.execute("PRAGMA query_only = ON")
    conn.execute("PRAGMA busy_timeout = 1000")  # 1 second lock timeout

    try:
        yield conn
    finally:
        conn.close()


def detect_schema_capabilities(conn: sqlite3.Connection) -> dict:
    """
    Detect which columns/features are available in this database.

    Returns dict with capability flags for various macOS version features.
    """
    capabilities = {
        'has_date_edited': False,
        'has_date_retracted': False,
        'has_thread_originator': False,
        'has_associated_emoji': False,
        'has_schedule_fields': False,
    }

    cursor = conn.execute("PRAGMA table_info(message)")
    columns = {row['name'] for row in cursor.fetchall()}

    capabilities['has_date_edited'] = 'date_edited' in columns
    capabilities['has_date_retracted'] = 'date_retracted' in columns
    capabilities['has_thread_originator'] = 'thread_originator_guid' in columns
    capabilities['has_associated_emoji'] = 'associated_message_emoji' in columns
    capabilities['has_schedule_fields'] = 'schedule_type' in columns

    return capabilities


def get_table_info(conn: sqlite3.Connection, table_name: str) -> list[dict]:
    """Get column information for a table."""
    cursor = conn.execute(f"PRAGMA table_info({table_name})")
    return [dict(row) for row in cursor.fetchall()]


def get_database_stats(conn: sqlite3.Connection) -> dict:
    """Get basic statistics about the database."""
    stats = {}

    # Count chats
    cursor = conn.execute("SELECT COUNT(*) as count FROM chat")
    stats['chat_count'] = cursor.fetchone()['count']

    # Count messages
    cursor = conn.execute("SELECT COUNT(*) as count FROM message")
    stats['message_count'] = cursor.fetchone()['count']

    # Count handles
    cursor = conn.execute("SELECT COUNT(*) as count FROM handle")
    stats['handle_count'] = cursor.fetchone()['count']

    # Count attachments
    cursor = conn.execute("SELECT COUNT(*) as count FROM attachment")
    stats['attachment_count'] = cursor.fetchone()['count']

    # Get date range
    cursor = conn.execute("""
        SELECT MIN(date) as min_date, MAX(date) as max_date
        FROM message
        WHERE date > 0
    """)
    row = cursor.fetchone()
    if row['min_date']:
        stats['earliest_message'] = apple_to_datetime(row['min_date'])
        stats['latest_message'] = apple_to_datetime(row['max_date'])

    return stats


def check_wal_mode(conn: sqlite3.Connection) -> str:
    """Check the journal mode of the database."""
    cursor = conn.execute("PRAGMA journal_mode")
    return cursor.fetchone()[0]
