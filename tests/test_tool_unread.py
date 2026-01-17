"""Tests for get_unread tool."""

import pytest
import sqlite3


@pytest.fixture
def unread_db(mock_db_path):
    """Create a mock database with unread message data for testing."""
    conn = sqlite3.connect(mock_db_path)

    # Add is_read column to message table (it's in the default schema but we need data)
    conn.executescript("""
        -- Drop and recreate message table with is_read column
        DROP TABLE IF EXISTS message;
        CREATE TABLE message (
            ROWID INTEGER PRIMARY KEY,
            guid TEXT UNIQUE,
            text TEXT,
            attributedBody BLOB,
            handle_id INTEGER,
            date INTEGER,
            date_read INTEGER,
            is_from_me INTEGER,
            is_read INTEGER DEFAULT 1,
            associated_message_type INTEGER DEFAULT 0,
            associated_message_guid TEXT,
            cache_has_attachments INTEGER DEFAULT 0,
            FOREIGN KEY (handle_id) REFERENCES handle(ROWID)
        );

        INSERT INTO handle (ROWID, id, service) VALUES
            (1, '+19175551234', 'iMessage'),
            (2, '+15625559876', 'iMessage'),
            (3, 'test@example.com', 'iMessage');

        INSERT INTO chat (ROWID, guid, display_name, service_name) VALUES
            (1, 'iMessage;+;chat123', NULL, 'iMessage'),
            (2, 'iMessage;+;chat456', 'Test Group', 'iMessage'),
            (3, 'iMessage;+;chat789', 'Empty Chat', 'iMessage');

        INSERT INTO chat_handle_join (chat_id, handle_id) VALUES
            (1, 1),
            (2, 1),
            (2, 2),
            (3, 3);

        -- Messages: Apple epoch nanoseconds (2026-01-16 = ~789100000000000000)
        -- Unread messages: is_read = 0 AND is_from_me = 0
        -- Read messages: is_read = 1 OR is_from_me = 1
        INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, is_read, associated_message_type) VALUES
            -- Chat 1: 2 unread, 1 read
            (1, 'msg1', 'Hello world', 1, 789100000000000000, 0, 0, 0),  -- Unread
            (2, 'msg2', 'How are you?', NULL, 789100100000000000, 1, 1, 0),  -- From me (read)
            (3, 'msg3', 'Unread message 2', 1, 789100200000000000, 0, 0, 0),  -- Unread
            -- Chat 2: 1 unread, 2 read
            (4, 'msg4', 'Group message', 1, 789100300000000000, 0, 0, 0),  -- Unread
            (5, 'msg5', 'Another message', 2, 789100400000000000, 0, 1, 0),  -- Read
            (6, 'msg6', 'My response', NULL, 789100500000000000, 1, 1, 0);  -- From me

        INSERT INTO chat_message_join (chat_id, message_id) VALUES
            (1, 1),
            (1, 2),
            (1, 3),
            (2, 4),
            (2, 5),
            (2, 6);
    """)
    conn.close()

    return mock_db_path


def test_get_unread_messages_format(unread_db):
    """Test default messages format returns correct structure."""
    from imessage_max.tools.get_unread import get_unread_impl

    result = get_unread_impl(db_path=str(unread_db))

    assert "error" not in result
    assert "unread_messages" in result
    assert "people" in result
    assert "total_unread" in result
    assert "chats_with_unread" in result
    assert "more" in result

    # Should have 3 unread messages total
    assert result["total_unread"] == 3
    assert result["chats_with_unread"] == 2


def test_get_unread_summary_format(unread_db):
    """Test summary format returns breakdown by chat."""
    from imessage_max.tools.get_unread import get_unread_impl

    result = get_unread_impl(format="summary", db_path=str(unread_db))

    assert "error" not in result
    assert "summary" in result
    assert "total_unread" in result["summary"]
    assert "chats_with_unread" in result["summary"]
    assert "breakdown" in result["summary"]

    # Should have breakdown for each chat with unread
    assert len(result["summary"]["breakdown"]) == 2

    # Each breakdown should have required fields
    for item in result["summary"]["breakdown"]:
        assert "chat_id" in item
        assert "chat_name" in item
        assert "unread_count" in item
        assert "oldest_unread" in item


def test_get_unread_specific_chat(unread_db):
    """Test filter to specific chat_id works."""
    from imessage_max.tools.get_unread import get_unread_impl

    result = get_unread_impl(chat_id="chat1", db_path=str(unread_db))

    assert "error" not in result
    assert "unread_messages" in result

    # Chat 1 has 2 unread messages
    assert result["total_unread"] == 2
    assert result["chats_with_unread"] == 1

    # All messages should be from chat1
    for msg in result["unread_messages"]:
        assert msg["chat"]["id"] == "chat1"


def test_get_unread_limit(unread_db):
    """Test limit parameter constrains results."""
    from imessage_max.tools.get_unread import get_unread_impl

    result = get_unread_impl(limit=1, db_path=str(unread_db))

    assert "error" not in result
    assert len(result["unread_messages"]) == 1
    # total_unread should still show full count
    assert result["total_unread"] == 3
    # more flag should be True since there are more messages
    assert result["more"] is True


def test_get_unread_empty(unread_db):
    """Test returns empty results when no unread messages."""
    from imessage_max.tools.get_unread import get_unread_impl

    # Chat 3 has no messages, so no unread
    result = get_unread_impl(chat_id="chat3", db_path=str(unread_db))

    assert "error" not in result
    assert result["unread_messages"] == []
    assert result["total_unread"] == 0
    assert result["chats_with_unread"] == 0
    assert result["more"] is False


def test_get_unread_people_map(unread_db):
    """Test people map contains sender info."""
    from imessage_max.tools.get_unread import get_unread_impl

    result = get_unread_impl(db_path=str(unread_db))

    assert "error" not in result
    assert "people" in result

    # People map should contain at least one entry for sender
    assert len(result["people"]) > 0

    # Each unread message should have a 'from' that exists in people map
    for msg in result["unread_messages"]:
        if "from" in msg["message"]:
            from_key = msg["message"]["from"]
            assert from_key in result["people"]


def test_get_unread_invalid_chat_id(unread_db):
    """Test invalid chat_id format returns error."""
    from imessage_max.tools.get_unread import get_unread_impl

    result = get_unread_impl(chat_id="invalid_chat_id_format", db_path=str(unread_db))

    assert "error" in result
    assert result["error"] == "chat_not_found"


def test_get_unread_message_structure(unread_db):
    """Test individual unread message structure."""
    from imessage_max.tools.get_unread import get_unread_impl

    result = get_unread_impl(db_path=str(unread_db))

    assert "unread_messages" in result
    assert len(result["unread_messages"]) > 0

    msg_item = result["unread_messages"][0]

    # Should have message and chat info
    assert "message" in msg_item
    assert "chat" in msg_item

    # Message structure
    assert "id" in msg_item["message"]
    assert "ts" in msg_item["message"]
    assert "ago" in msg_item["message"]
    assert "from" in msg_item["message"]
    assert "text" in msg_item["message"]

    # Chat structure
    assert "id" in msg_item["chat"]
    assert "name" in msg_item["chat"]


def test_get_unread_sorted_oldest_first(unread_db):
    """Test unread messages are sorted oldest first."""
    from imessage_max.tools.get_unread import get_unread_impl

    result = get_unread_impl(db_path=str(unread_db))

    assert "unread_messages" in result
    assert len(result["unread_messages"]) >= 2

    # Messages should be sorted by date ascending (oldest first)
    timestamps = [msg["message"]["ts"] for msg in result["unread_messages"]]
    assert timestamps == sorted(timestamps)


def test_get_unread_max_limit(unread_db):
    """Test limit is clamped to max 100."""
    from imessage_max.tools.get_unread import get_unread_impl

    # Request more than max, should be clamped
    result = get_unread_impl(limit=500, db_path=str(unread_db))

    assert "error" not in result
    # Should still work, just clamped to 100


def test_get_unread_database_not_found():
    """Test error handling for missing database."""
    from imessage_max.tools.get_unread import get_unread_impl

    result = get_unread_impl(db_path="/nonexistent/path/chat.db")

    assert "error" in result
    assert result["error"] == "database_not_found"


def test_get_unread_summary_sorted_by_count(unread_db):
    """Test summary breakdown is sorted by unread count descending."""
    from imessage_max.tools.get_unread import get_unread_impl

    result = get_unread_impl(format="summary", db_path=str(unread_db))

    assert "summary" in result
    breakdown = result["summary"]["breakdown"]

    # First chat should have more unread than second
    if len(breakdown) >= 2:
        assert breakdown[0]["unread_count"] >= breakdown[1]["unread_count"]


def test_get_unread_chat_id_special_chars(unread_db):
    """Test that special LIKE characters in chat_id are escaped."""
    from imessage_max.tools.get_unread import get_unread_impl

    result = get_unread_impl(chat_id="100%_test", db_path=str(unread_db))
    # Should not cause SQL errors
    assert "error" not in result or result.get("error") == "chat_not_found"
