"""Tests for find_chat tool."""

import pytest
from imessage_max.tools.find_chat import find_chat_impl


def test_find_chat_by_participants(populated_db):
    """Test finding chat by participant handles."""
    result = find_chat_impl(
        participants=["+19175551234"],
        db_path=str(populated_db),
    )

    assert "chats" in result
    assert len(result["chats"]) > 0


def test_find_chat_by_name(populated_db):
    """Test finding chat by display name."""
    result = find_chat_impl(
        name="Test Group",
        db_path=str(populated_db),
    )

    assert "chats" in result
    assert len(result["chats"]) > 0
    assert result["chats"][0]["name"] == "Test Group"


def test_find_chat_requires_parameter(populated_db):
    """Test that at least one search param is required."""
    result = find_chat_impl(db_path=str(populated_db))

    assert "error" in result


def test_find_chat_no_results(populated_db):
    """Test handling of no matches."""
    result = find_chat_impl(
        name="NonexistentChat12345",
        db_path=str(populated_db),
    )

    assert "chats" in result
    assert len(result["chats"]) == 0


def test_find_chat_by_partial_name(populated_db):
    """Test finding chat by partial name match."""
    result = find_chat_impl(
        name="Test",
        db_path=str(populated_db),
    )

    assert "chats" in result
    assert len(result["chats"]) > 0
    assert "Test" in result["chats"][0]["name"]


def test_find_chat_by_content(populated_db):
    """Test finding chat by message content."""
    result = find_chat_impl(
        contains_recent="Hello world",
        db_path=str(populated_db),
    )

    assert "chats" in result
    assert len(result["chats"]) > 0


def test_find_chat_with_limit(populated_db):
    """Test that limit parameter is respected."""
    result = find_chat_impl(
        participants=["+19175551234"],
        limit=1,
        db_path=str(populated_db),
    )

    assert "chats" in result
    assert len(result["chats"]) <= 1


def test_find_chat_filter_by_group(populated_db):
    """Test filtering by group chat."""
    result = find_chat_impl(
        name="Test",
        is_group=True,
        db_path=str(populated_db),
    )

    assert "chats" in result
    # The Test Group has 2 participants so it's a group
    for chat in result["chats"]:
        if "group" in chat:
            assert chat["group"] is True


def test_find_chat_filter_by_dm(populated_db):
    """Test filtering by DM (non-group)."""
    result = find_chat_impl(
        participants=["+19175551234"],
        is_group=False,
        db_path=str(populated_db),
    )

    assert "chats" in result
    # DMs should not have group=True
    for chat in result["chats"]:
        assert chat.get("group", False) is False


def test_find_chat_response_structure(populated_db):
    """Test that response has expected structure."""
    result = find_chat_impl(
        name="Test Group",
        db_path=str(populated_db),
    )

    assert "chats" in result
    assert "more" in result

    if result["chats"]:
        chat = result["chats"][0]
        assert "id" in chat
        assert "name" in chat
        assert "participants" in chat
        assert "match" in chat


def test_find_chat_participants_structure(populated_db):
    """Test that participants have expected structure."""
    result = find_chat_impl(
        name="Test Group",
        db_path=str(populated_db),
    )

    assert "chats" in result
    assert len(result["chats"]) > 0

    chat = result["chats"][0]
    assert "participants" in chat
    assert len(chat["participants"]) > 0

    participant = chat["participants"][0]
    assert "handle" in participant


def test_find_chat_database_not_found():
    """Test error handling for missing database."""
    result = find_chat_impl(
        name="Test",
        db_path="/nonexistent/path/chat.db",
    )

    assert "error" in result
    assert result["error"] == "database_not_found"


def test_find_chat_validation_error_message(populated_db):
    """Test that validation error has proper message."""
    result = find_chat_impl(db_path=str(populated_db))

    assert "error" in result
    assert result["error"] == "validation_error"
    assert "message" in result


def test_find_chat_returns_chat_id(populated_db):
    """Test that chat ID is properly formatted."""
    result = find_chat_impl(
        name="Test Group",
        db_path=str(populated_db),
    )

    assert "chats" in result
    assert len(result["chats"]) > 0

    chat = result["chats"][0]
    assert chat["id"].startswith("chat")
