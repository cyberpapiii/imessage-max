"""Database connection utilities for iMessage chat.db."""

import sqlite3
import os
from contextlib import contextmanager
from datetime import datetime, timezone, timedelta
from typing import Generator

# Default database path
DB_PATH = os.path.expanduser("~/Library/Messages/chat.db")


class DatabaseAccessError(Exception):
    """Raised when iMessage database cannot be accessed due to permissions."""

    def __init__(self, db_path: str, original_error: Exception | None = None):
        self.db_path = db_path
        self.original_error = original_error

        # Determine the process that needs Full Disk Access
        import sys
        executable = sys.executable or "your Python interpreter"

        self.message = f"""
╔══════════════════════════════════════════════════════════════════════════════╗
║                         FULL DISK ACCESS REQUIRED                            ║
╚══════════════════════════════════════════════════════════════════════════════╝

iMessage Max cannot access the iMessage database at:
  {db_path}

This is because macOS requires Full Disk Access to read iMessage data.

┌─────────────────────────────────────────────────────────────────────────────┐
│  HOW TO FIX:                                                                │
│                                                                             │
│  1. Open System Settings → Privacy & Security → Full Disk Access           │
│  2. Click the + button                                                      │
│  3. Navigate to and add:                                                    │
│     {executable:<63} │
│  4. Restart the application                                                 │
│                                                                             │
│  TIP: Press Cmd+Shift+G in the file dialog to enter the path directly.     │
└─────────────────────────────────────────────────────────────────────────────┘

If you're using Claude Desktop with UV, also add:
  ~/.local/bin/uvx

Run the 'diagnose' tool after granting permission to verify setup.
"""
        super().__init__(self.message)


def check_database_access(db_path: str = DB_PATH) -> tuple[bool, str]:
    """
    Check if the iMessage database is accessible.

    Returns:
        Tuple of (accessible, status_message)
    """
    if not os.path.exists(db_path):
        return False, "database_not_found"

    try:
        # Try to actually open and read from the database
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=2.0)
        cursor = conn.execute("SELECT COUNT(*) FROM chat LIMIT 1")
        cursor.fetchone()
        conn.close()
        return True, "accessible"
    except sqlite3.OperationalError as e:
        error_str = str(e).lower()
        if "unable to open" in error_str or "permission denied" in error_str:
            return False, "permission_denied"
        return False, f"database_error: {e}"
    except Exception as e:
        return False, f"unknown_error: {e}"

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

    Raises:
        DatabaseAccessError: If database cannot be accessed (usually missing Full Disk Access)
        FileNotFoundError: If database file doesn't exist (iMessage not set up)
    """
    if not os.path.exists(db_path):
        raise FileNotFoundError(
            f"iMessage database not found at {db_path}. "
            f"Make sure iMessage is set up and has sent/received at least one message."
        )

    try:
        conn = sqlite3.connect(
            f"file:{db_path}?mode=ro",
            uri=True,
            timeout=5.0
        )
    except sqlite3.OperationalError as e:
        # Permission denied or unable to open = Full Disk Access issue
        raise DatabaseAccessError(db_path, e) from e

    conn.row_factory = sqlite3.Row

    try:
        conn.execute("PRAGMA query_only = ON")
        conn.execute("PRAGMA busy_timeout = 1000")
    except sqlite3.OperationalError as e:
        conn.close()
        raise DatabaseAccessError(db_path, e) from e

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
