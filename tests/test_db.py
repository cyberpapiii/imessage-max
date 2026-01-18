"""Tests for database connection management."""

import pytest
import sqlite3
from datetime import datetime, timezone
from imessage_max.db import (
    get_db_connection,
    DB_PATH,
    apple_to_datetime,
    datetime_to_apple,
    APPLE_EPOCH,
    check_database_access,
    DatabaseAccessError,
)


def test_get_db_connection_with_mock(mock_db_path):
    """Test connection manager with mock database."""
    with get_db_connection(mock_db_path) as conn:
        assert conn is not None
        # Verify read-only mode
        cursor = conn.execute("SELECT 1")
        assert cursor.fetchone()[0] == 1


def test_connection_closes_after_context(mock_db_path):
    """Test that connection is closed after context exit."""
    with get_db_connection(mock_db_path) as conn:
        pass
    # Connection should be closed - this should raise
    with pytest.raises(sqlite3.ProgrammingError):
        conn.execute("SELECT 1")


def test_get_db_connection_nonexistent():
    """Test error handling for missing database."""
    with pytest.raises(FileNotFoundError):
        with get_db_connection("/nonexistent/path/chat.db") as conn:
            pass


def test_apple_to_datetime():
    """Test Apple epoch to datetime conversion."""
    # 2026-01-16 00:00:00 UTC is 790214400 seconds after 2001-01-01
    apple_ts = 790214400 * 1_000_000_000
    dt = apple_to_datetime(apple_ts)
    assert dt.year == 2026
    assert dt.month == 1
    assert dt.day == 16


def test_datetime_to_apple():
    """Test datetime to Apple epoch conversion."""
    dt = datetime(2026, 1, 16, 0, 0, 0, tzinfo=timezone.utc)
    apple_ts = datetime_to_apple(dt)
    # Convert back to verify
    result = apple_to_datetime(apple_ts)
    assert result == dt


def test_apple_to_datetime_none():
    """Test handling of None timestamp."""
    assert apple_to_datetime(None) is None


def test_check_database_access_accessible(mock_db_path):
    """Test check_database_access returns accessible for valid database."""
    accessible, status = check_database_access(mock_db_path)
    assert accessible is True
    assert status == "accessible"


def test_check_database_access_not_found():
    """Test check_database_access returns not_found for missing database."""
    accessible, status = check_database_access("/nonexistent/path/chat.db")
    assert accessible is False
    assert status == "database_not_found"


def test_database_access_error_has_helpful_message():
    """Test DatabaseAccessError includes helpful instructions."""
    error = DatabaseAccessError("/path/to/chat.db")
    assert "FULL DISK ACCESS REQUIRED" in str(error)
    assert "System Settings" in str(error)
    assert "Privacy & Security" in str(error)
    assert "diagnose" in str(error)
