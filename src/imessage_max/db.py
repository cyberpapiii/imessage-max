"""Database connection utilities for iMessage chat.db."""

import sqlite3
import os
from contextlib import contextmanager
from datetime import datetime, timezone, timedelta
from typing import Generator

# Default database path
DB_PATH = os.path.expanduser("~/Library/Messages/chat.db")

# Apple epoch (2001-01-01 00:00:00 UTC)
APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)


def apple_to_datetime(apple_timestamp: int | None) -> datetime | None:
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

    Connection is closed immediately after use to prevent
    macOS Tahoe from terminating Messages.app.
    """
    if not os.path.exists(db_path):
        raise FileNotFoundError(f"Database not found: {db_path}")

    conn = sqlite3.connect(
        f"file:{db_path}?mode=ro",
        uri=True,
        timeout=5.0
    )
    conn.row_factory = sqlite3.Row

    conn.execute("PRAGMA query_only = ON")
    conn.execute("PRAGMA busy_timeout = 1000")

    try:
        yield conn
    finally:
        conn.close()


def escape_like(s: str) -> str:
    """Escape SQL LIKE special characters.

    Use with ESCAPE '\\\\' clause in SQL:
        WHERE column LIKE ? ESCAPE '\\\\'

    Args:
        s: String to escape

    Returns:
        Escaped string safe for LIKE patterns
    """
    return s.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def detect_schema_capabilities(conn: sqlite3.Connection) -> dict:
    """Detect which columns/features are available in this database."""
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
