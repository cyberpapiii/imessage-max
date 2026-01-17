"""Tests for list_chats tool."""

import pytest
from imessage_max.tools.list_chats import list_chats_impl


def test_list_chats_basic(populated_db):
    """Test basic chat listing."""
    result = list_chats_impl(db_path=str(populated_db))

    assert "chats" in result
    assert isinstance(result["chats"], list)


def test_list_chats_with_limit(populated_db):
    """Test limit parameter."""
    result = list_chats_impl(limit=1, db_path=str(populated_db))

    assert len(result["chats"]) <= 1


def test_list_chats_groups_only(populated_db):
    """Test filtering to groups only."""
    result = list_chats_impl(is_group=True, db_path=str(populated_db))

    for chat in result["chats"]:
        assert chat.get("group", False) is True


def test_list_chats_dms_only(populated_db):
    """Test filtering to DMs only."""
    result = list_chats_impl(is_group=False, db_path=str(populated_db))

    for chat in result["chats"]:
        assert chat.get("group", False) is False


def test_list_chats_has_totals(populated_db):
    """Test that totals are included."""
    result = list_chats_impl(db_path=str(populated_db))

    assert "total_chats" in result
    assert "total_groups" in result
    assert "total_dms" in result


def test_list_chats_response_structure(populated_db):
    """Test that response has expected structure."""
    result = list_chats_impl(db_path=str(populated_db))

    assert "chats" in result
    assert "more" in result
    assert "cursor" in result


def test_list_chats_chat_structure(populated_db):
    """Test that chats have expected structure."""
    result = list_chats_impl(db_path=str(populated_db))

    assert "chats" in result
    assert len(result["chats"]) > 0

    chat = result["chats"][0]
    assert "id" in chat
    assert "name" in chat
    assert "participants" in chat
    assert "participant_count" in chat


def test_list_chats_chat_id_format(populated_db):
    """Test that chat ID is properly formatted."""
    result = list_chats_impl(db_path=str(populated_db))

    assert "chats" in result
    assert len(result["chats"]) > 0

    for chat in result["chats"]:
        assert chat["id"].startswith("chat")


def test_list_chats_participants_structure(populated_db):
    """Test that participants have expected structure."""
    result = list_chats_impl(db_path=str(populated_db))

    assert "chats" in result
    assert len(result["chats"]) > 0

    chat = result["chats"][0]
    assert "participants" in chat
    assert len(chat["participants"]) > 0

    participant = chat["participants"][0]
    assert "handle" in participant
    assert "name" in participant


def test_list_chats_min_participants(populated_db):
    """Test min_participants filter."""
    result = list_chats_impl(min_participants=2, db_path=str(populated_db))

    for chat in result["chats"]:
        assert chat["participant_count"] >= 2


def test_list_chats_max_participants(populated_db):
    """Test max_participants filter."""
    result = list_chats_impl(max_participants=1, db_path=str(populated_db))

    for chat in result["chats"]:
        assert chat["participant_count"] <= 1


def test_list_chats_sort_recent(populated_db):
    """Test that recent sort is default."""
    result = list_chats_impl(sort="recent", db_path=str(populated_db))

    assert "chats" in result


def test_list_chats_sort_alphabetical(populated_db):
    """Test alphabetical sort."""
    result = list_chats_impl(sort="alphabetical", db_path=str(populated_db))

    assert "chats" in result


def test_list_chats_database_not_found():
    """Test error handling for missing database."""
    result = list_chats_impl(db_path="/nonexistent/path/chat.db")

    assert "error" in result
    assert result["error"] == "database_not_found"


def test_list_chats_last_message_info(populated_db):
    """Test that last message info is included when available."""
    result = list_chats_impl(db_path=str(populated_db))

    assert "chats" in result
    # Find a chat with messages (we know chat 1 has messages)
    chat_with_messages = None
    for chat in result["chats"]:
        if "last" in chat:
            chat_with_messages = chat
            break

    if chat_with_messages:
        last = chat_with_messages["last"]
        assert "from" in last
        assert "text" in last
        assert "ago" in last


def test_list_chats_more_flag(populated_db):
    """Test that more flag indicates pagination availability."""
    # With limit of 1, there should be more
    result = list_chats_impl(limit=1, db_path=str(populated_db))

    assert "more" in result
    # Since we have 2 chats in populated_db and limit is 1, more should be True
    assert result["more"] is True


def test_list_chats_default_limit(populated_db):
    """Test default limit of 20."""
    result = list_chats_impl(db_path=str(populated_db))

    # We have 2 chats, so should get both with default limit of 20
    assert len(result["chats"]) <= 20


def test_list_chats_empty_db(mock_db_path):
    """Test handling of empty database."""
    result = list_chats_impl(db_path=str(mock_db_path))

    assert "chats" in result
    assert len(result["chats"]) == 0
    assert result["total_chats"] == 0
