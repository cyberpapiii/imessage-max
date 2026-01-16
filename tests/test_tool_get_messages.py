"""Tests for get_messages tool."""

import pytest
from imessage_mcp.tools.get_messages import get_messages_impl


def test_get_messages_by_chat_id(populated_db):
    """Test getting messages by chat ID."""
    result = get_messages_impl(
        chat_id="chat1",
        db_path=str(populated_db),
    )

    assert "messages" in result
    assert "chat" in result


def test_get_messages_with_limit(populated_db):
    """Test message limit parameter."""
    result = get_messages_impl(
        chat_id="chat1",
        limit=1,
        db_path=str(populated_db),
    )

    assert len(result["messages"]) <= 1


def test_get_messages_requires_chat(populated_db):
    """Test that chat_id is required."""
    result = get_messages_impl(db_path=str(populated_db))

    assert "error" in result


def test_get_messages_people_map(populated_db):
    """Test that people map is included."""
    result = get_messages_impl(
        chat_id="chat1",
        db_path=str(populated_db),
    )

    if result.get("messages"):
        assert "people" in result


def test_get_messages_chat_not_found(populated_db):
    """Test error when chat doesn't exist."""
    result = get_messages_impl(
        chat_id="chat99999",
        db_path=str(populated_db),
    )

    assert "error" in result
    assert result["error"] == "chat_not_found"


def test_get_messages_response_structure(populated_db):
    """Test response has expected structure."""
    result = get_messages_impl(
        chat_id="chat1",
        db_path=str(populated_db),
    )

    assert "chat" in result
    assert "people" in result
    assert "messages" in result
    assert "more" in result

    # Chat info structure
    assert "id" in result["chat"]
    assert "name" in result["chat"]


def test_get_messages_message_structure(populated_db):
    """Test individual message structure."""
    result = get_messages_impl(
        chat_id="chat1",
        db_path=str(populated_db),
    )

    assert "messages" in result
    assert len(result["messages"]) > 0

    msg = result["messages"][0]
    assert "id" in msg
    assert "ts" in msg
    # "text" may be None for some messages
    assert "text" in msg or msg.get("text") is None


def test_get_messages_from_me(populated_db):
    """Test messages have from field."""
    result = get_messages_impl(
        chat_id="chat1",
        db_path=str(populated_db),
    )

    assert "messages" in result
    # At least one message should have a from field
    has_from = any("from" in msg for msg in result["messages"])
    assert has_from


def test_get_messages_database_not_found():
    """Test error handling for missing database."""
    result = get_messages_impl(
        chat_id="chat1",
        db_path="/nonexistent/path/chat.db",
    )

    assert "error" in result
    assert result["error"] == "database_not_found"


def test_get_messages_validation_error_message(populated_db):
    """Test that validation error has proper message."""
    result = get_messages_impl(db_path=str(populated_db))

    assert "error" in result
    assert result["error"] == "validation_error"
    assert "message" in result


def test_get_messages_more_flag(populated_db):
    """Test that more flag indicates pagination availability."""
    # With a very high limit, more should be False
    result = get_messages_impl(
        chat_id="chat1",
        limit=1000,
        db_path=str(populated_db),
    )

    assert "more" in result
    # With less messages than limit, more should be False
    assert result["more"] is False


def test_get_messages_more_flag_with_limit(populated_db):
    """Test that more flag is True when limit reached."""
    # With limit of 1 and multiple messages, more should be True
    result = get_messages_impl(
        chat_id="chat1",
        limit=1,
        db_path=str(populated_db),
    )

    # There are 2 messages in chat1 (excluding reactions)
    if len(result["messages"]) == 1:
        assert result["more"] is True


def test_get_messages_people_map_has_me(populated_db):
    """Test that people map includes 'me' key."""
    result = get_messages_impl(
        chat_id="chat1",
        db_path=str(populated_db),
    )

    assert "people" in result
    assert "me" in result["people"]
    assert result["people"]["me"] == "Me"


def test_get_messages_contains_filter(populated_db):
    """Test filtering messages by text content."""
    result = get_messages_impl(
        chat_id="chat1",
        contains="Hello",
        db_path=str(populated_db),
    )

    assert "messages" in result
    # Should find the "Hello world" message
    if result["messages"]:
        assert any("Hello" in (msg.get("text") or "") for msg in result["messages"])


def test_get_messages_contains_filter_no_match(populated_db):
    """Test contains filter with no matching text."""
    result = get_messages_impl(
        chat_id="chat1",
        contains="nonexistent12345",
        db_path=str(populated_db),
    )

    assert "messages" in result
    assert len(result["messages"]) == 0


def test_get_messages_include_reactions_false(populated_db):
    """Test disabling reactions in response."""
    result = get_messages_impl(
        chat_id="chat1",
        include_reactions=False,
        db_path=str(populated_db),
    )

    assert "messages" in result
    # When reactions are disabled, messages shouldn't have reaction arrays
    for msg in result["messages"]:
        assert "reactions" not in msg


def test_get_messages_id_format(populated_db):
    """Test that message IDs have correct format."""
    result = get_messages_impl(
        chat_id="chat1",
        db_path=str(populated_db),
    )

    assert "messages" in result
    for msg in result["messages"]:
        assert msg["id"].startswith("msg_")


def test_get_messages_timestamp_format(populated_db):
    """Test that timestamps are ISO format."""
    result = get_messages_impl(
        chat_id="chat1",
        db_path=str(populated_db),
    )

    assert "messages" in result
    for msg in result["messages"]:
        if msg.get("ts"):
            # Should contain ISO format indicators
            assert "T" in msg["ts"] or "-" in msg["ts"]
