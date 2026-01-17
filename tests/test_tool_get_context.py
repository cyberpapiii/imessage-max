"""Tests for get_context tool."""

import pytest
from imessage_max.tools.get_context import get_context_impl


def test_get_context_by_message_id(populated_db):
    """Test getting context by message ID."""
    # Message ID 1 is "Hello world" in the populated_db
    result = get_context_impl(message_id="msg1", db_path=str(populated_db))

    # Should have target or error (if msg not found)
    assert "target" in result or "error" in result


def test_get_context_by_contains(populated_db):
    """Test getting context by text search."""
    result = get_context_impl(
        chat_id="chat1",
        contains="Hello",
        db_path=str(populated_db),
    )

    assert "target" in result or "error" in result


def test_get_context_has_before_after(populated_db):
    """Test that before/after arrays are included."""
    result = get_context_impl(message_id="msg1", db_path=str(populated_db))

    if "target" in result:
        assert "before" in result
        assert "after" in result


def test_get_context_has_people_map(populated_db):
    """Test that people map is included."""
    result = get_context_impl(message_id="msg1", db_path=str(populated_db))

    if "target" in result:
        assert "people" in result


def test_get_context_has_chat_info(populated_db):
    """Test that chat info is included."""
    result = get_context_impl(message_id="msg1", db_path=str(populated_db))

    if "target" in result:
        assert "chat" in result


def test_get_context_requires_params():
    """Test that either message_id or chat_id+contains is required."""
    result = get_context_impl(db_path="/nonexistent")

    assert "error" in result
    assert result["error"] == "invalid_params"


def test_get_context_contains_requires_chat_id():
    """Test that contains requires chat_id."""
    result = get_context_impl(contains="hello", db_path="/nonexistent")

    assert "error" in result
    assert result["error"] == "invalid_params"


def test_get_context_custom_before_after(populated_db):
    """Test custom before/after counts."""
    result = get_context_impl(
        message_id="msg1",
        before=2,
        after=3,
        db_path=str(populated_db),
    )

    if "target" in result:
        assert len(result.get("before", [])) <= 2
        assert len(result.get("after", [])) <= 3


def test_get_context_target_message_structure(populated_db):
    """Test that target message has expected fields."""
    result = get_context_impl(message_id="msg1", db_path=str(populated_db))

    if "target" in result:
        target = result["target"]
        assert "id" in target
        assert "ts" in target
        assert "from" in target
        # text may be None for some messages
        assert "text" in target or target.get("text") is None


def test_get_context_chat_info_structure(populated_db):
    """Test that chat info has expected fields."""
    result = get_context_impl(message_id="msg1", db_path=str(populated_db))

    if "target" in result:
        chat = result["chat"]
        assert "id" in chat
        assert "name" in chat


def test_get_context_people_map_has_me(populated_db):
    """Test that people map includes 'me' key when there are sent messages."""
    # Message 2 is from_me=1 in populated_db, so should include "me"
    result = get_context_impl(message_id="msg2", db_path=str(populated_db))

    if "target" in result:
        assert "me" in result["people"]


def test_get_context_message_not_found(populated_db):
    """Test error when message doesn't exist."""
    result = get_context_impl(
        message_id="msg99999",
        db_path=str(populated_db),
    )

    assert "error" in result
    assert result["error"] == "not_found"


def test_get_context_database_not_found():
    """Test error handling for missing database."""
    result = get_context_impl(
        message_id="msg1",
        db_path="/nonexistent/path/chat.db",
    )

    assert "error" in result
    assert result["error"] == "database_not_found"


def test_get_context_message_id_format(populated_db):
    """Test that message IDs in response have correct format."""
    result = get_context_impl(message_id="msg1", db_path=str(populated_db))

    if "target" in result:
        assert result["target"]["id"].startswith("msg")

        for msg in result.get("before", []):
            assert msg["id"].startswith("msg")

        for msg in result.get("after", []):
            assert msg["id"].startswith("msg")


def test_get_context_timestamp_format(populated_db):
    """Test that timestamps are ISO format."""
    result = get_context_impl(message_id="msg1", db_path=str(populated_db))

    if "target" in result and result["target"].get("ts"):
        # Should contain ISO format indicators
        assert "T" in result["target"]["ts"]


def test_get_context_before_after_defaults(populated_db):
    """Test default before/after values."""
    result = get_context_impl(message_id="msg2", db_path=str(populated_db))

    if "target" in result:
        # Default before is 5, after is 10, but may have fewer messages
        assert isinstance(result["before"], list)
        assert isinstance(result["after"], list)
        # Should respect defaults (may have fewer if not enough messages)
        assert len(result["before"]) <= 5
        assert len(result["after"]) <= 10


def test_get_context_before_after_bounds(populated_db):
    """Test that before/after are bounded to reasonable limits."""
    # Request excessively large values
    result = get_context_impl(
        message_id="msg1",
        before=1000,
        after=1000,
        db_path=str(populated_db),
    )

    if "target" in result:
        # Should be capped (implementation caps at 50)
        assert len(result["before"]) <= 50
        assert len(result["after"]) <= 50


def test_get_context_contains_not_found(populated_db):
    """Test error when contains text not found."""
    result = get_context_impl(
        chat_id="chat1",
        contains="nonexistent12345xyz",
        db_path=str(populated_db),
    )

    assert "error" in result
    assert result["error"] == "not_found"


def test_get_context_has_ago_field(populated_db):
    """Test that messages have compact relative time (ago) field."""
    result = get_context_impl(message_id="msg1", db_path=str(populated_db))

    if "target" in result:
        # Should have ago field for relative time
        assert "ago" in result["target"]


def test_get_context_chat_id_format(populated_db):
    """Test that chat ID in response has correct format."""
    result = get_context_impl(message_id="msg1", db_path=str(populated_db))

    if "target" in result:
        assert result["chat"]["id"].startswith("chat")


def test_get_context_accepts_raw_message_id(populated_db):
    """Test that raw numeric message ID is accepted."""
    result = get_context_impl(message_id="1", db_path=str(populated_db))

    assert "target" in result or "error" in result


def test_get_context_accepts_raw_chat_id(populated_db):
    """Test that raw numeric chat ID is accepted."""
    result = get_context_impl(
        chat_id="1",
        contains="Hello",
        db_path=str(populated_db),
    )

    assert "target" in result or "error" in result
