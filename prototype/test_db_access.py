#!/usr/bin/env python3
"""
Test 1: Database Access Verification

Tests:
- Open connection with mode=ro
- Execute basic query
- Verify Messages.app remains running
- Test connection lifecycle (open/close patterns)
- Check WAL mode behavior
"""

import subprocess
import time
import sys
import os

# Add parent to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from prototype.utils.db import (
    get_db_connection,
    detect_schema_capabilities,
    get_database_stats,
    check_wal_mode,
    apple_to_datetime,
    DB_PATH
)


def check_messages_app_running() -> bool:
    """Check if Messages.app is currently running."""
    result = subprocess.run(
        ['pgrep', '-x', 'Messages'],
        capture_output=True
    )
    return result.returncode == 0


def test_database_exists():
    """Test 1.1: Verify chat.db exists and is readable."""
    print("\n--- Test 1.1: Database Exists ---")

    if not os.path.exists(DB_PATH):
        print(f"FAIL: Database not found at {DB_PATH}")
        print("Make sure Full Disk Access is granted to Terminal/Python")
        return False

    size = os.path.getsize(DB_PATH)
    print(f"PASS: Database found at {DB_PATH}")
    print(f"      Size: {size / 1024 / 1024:.2f} MB")
    return True


def test_readonly_connection():
    """Test 1.2: Open read-only connection and execute basic query."""
    print("\n--- Test 1.2: Read-Only Connection ---")

    try:
        with get_db_connection() as conn:
            # Execute simple query
            cursor = conn.execute("SELECT COUNT(*) as cnt FROM message")
            row = cursor.fetchone()
            count = row['cnt']

            print(f"PASS: Connected successfully")
            print(f"      Message count: {count:,}")
            return True
    except Exception as e:
        print(f"FAIL: {e}")
        return False


def test_messages_app_survival():
    """Test 1.3: Verify Messages.app remains running after DB access."""
    print("\n--- Test 1.3: Messages.app Survival ---")

    was_running = check_messages_app_running()
    print(f"      Messages.app running before: {was_running}")

    # Perform multiple database operations
    try:
        for i in range(5):
            with get_db_connection() as conn:
                cursor = conn.execute("SELECT COUNT(*) FROM chat")
                cursor.fetchone()
            time.sleep(0.1)  # Brief pause between connections
    except Exception as e:
        print(f"FAIL: Database error: {e}")
        return False

    is_running = check_messages_app_running()
    print(f"      Messages.app running after: {is_running}")

    if was_running and not is_running:
        print("FAIL: Messages.app was terminated!")
        return False

    print("PASS: Messages.app survived database access")
    return True


def test_connection_lifecycle():
    """Test 1.4: Test rapid open/close cycles."""
    print("\n--- Test 1.4: Connection Lifecycle ---")

    try:
        start = time.time()
        for i in range(10):
            with get_db_connection() as conn:
                cursor = conn.execute("SELECT 1")
                cursor.fetchone()
        elapsed = time.time() - start

        print(f"PASS: 10 connection cycles completed")
        print(f"      Total time: {elapsed:.3f}s ({elapsed/10*1000:.1f}ms per cycle)")
        return True
    except Exception as e:
        print(f"FAIL: {e}")
        return False


def test_wal_mode():
    """Test 1.5: Check WAL mode status."""
    print("\n--- Test 1.5: WAL Mode ---")

    try:
        with get_db_connection() as conn:
            mode = check_wal_mode(conn)
            print(f"PASS: Journal mode is '{mode}'")

            if mode.lower() == 'wal':
                print("      WAL mode is active - be cautious with connection management")
            return True
    except Exception as e:
        print(f"FAIL: {e}")
        return False


def test_schema_detection():
    """Test 1.6: Detect available schema features."""
    print("\n--- Test 1.6: Schema Detection ---")

    try:
        with get_db_connection() as conn:
            caps = detect_schema_capabilities(conn)

            print("PASS: Schema capabilities detected:")
            for key, value in caps.items():
                status = "available" if value else "not available"
                print(f"      {key}: {status}")
            return True
    except Exception as e:
        print(f"FAIL: {e}")
        return False


def test_database_stats():
    """Test 1.7: Get database statistics."""
    print("\n--- Test 1.7: Database Statistics ---")

    try:
        with get_db_connection() as conn:
            stats = get_database_stats(conn)

            print("PASS: Database statistics:")
            print(f"      Chats: {stats['chat_count']:,}")
            print(f"      Messages: {stats['message_count']:,}")
            print(f"      Handles: {stats['handle_count']:,}")
            print(f"      Attachments: {stats['attachment_count']:,}")

            if 'earliest_message' in stats:
                print(f"      Date range: {stats['earliest_message'].date()} to {stats['latest_message'].date()}")
            return True
    except Exception as e:
        print(f"FAIL: {e}")
        return False


def test_sample_messages():
    """Test 1.8: Retrieve sample messages."""
    print("\n--- Test 1.8: Sample Messages ---")

    try:
        with get_db_connection() as conn:
            cursor = conn.execute("""
                SELECT
                    m.ROWID,
                    m.guid,
                    m.text,
                    m.date,
                    m.is_from_me,
                    h.id as handle
                FROM message m
                LEFT JOIN handle h ON m.handle_id = h.ROWID
                WHERE m.text IS NOT NULL
                    AND m.associated_message_type = 0
                ORDER BY m.date DESC
                LIMIT 5
            """)

            rows = cursor.fetchall()
            print(f"PASS: Retrieved {len(rows)} recent messages:")

            for row in rows:
                dt = apple_to_datetime(row['date'])
                sender = "me" if row['is_from_me'] else (row['handle'] or "unknown")
                text_preview = (row['text'] or "")[:50]
                if len(row['text'] or "") > 50:
                    text_preview += "..."
                print(f"      [{dt.strftime('%Y-%m-%d %H:%M')}] {sender}: {text_preview}")
            return True
    except Exception as e:
        print(f"FAIL: {e}")
        return False


def run_all_tests():
    """Run all database access tests."""
    print("=" * 60)
    print("TEST 1: DATABASE ACCESS VERIFICATION")
    print("=" * 60)

    tests = [
        test_database_exists,
        test_readonly_connection,
        test_messages_app_survival,
        test_connection_lifecycle,
        test_wal_mode,
        test_schema_detection,
        test_database_stats,
        test_sample_messages,
    ]

    passed = 0
    failed = 0

    for test in tests:
        try:
            if test():
                passed += 1
            else:
                failed += 1
        except Exception as e:
            print(f"FAIL: Unexpected error in {test.__name__}: {e}")
            failed += 1

    print("\n" + "=" * 60)
    print(f"RESULTS: {passed} passed, {failed} failed")
    print("=" * 60)

    return failed == 0


if __name__ == "__main__":
    success = run_all_tests()
    sys.exit(0 if success else 1)
