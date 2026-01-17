"""Tests for get_active_conversations tool."""

import pytest
from imessage_max.tools.get_active import get_active_conversations_impl


def test_get_active_basic(populated_db):
    """Test basic active conversations listing."""
    result = get_active_conversations_impl(db_path=str(populated_db))

    assert "conversations" in result
    assert isinstance(result["conversations"], list)


def test_get_active_has_window_hours(populated_db):
    """Test that window_hours is included."""
    result = get_active_conversations_impl(db_path=str(populated_db))

    assert "window_hours" in result


def test_get_active_default_window_hours(populated_db):
    """Test that default window_hours is 24."""
    result = get_active_conversations_impl(db_path=str(populated_db))

    assert result.get("window_hours") == 24


def test_get_active_custom_hours(populated_db):
    """Test custom hours parameter."""
    result = get_active_conversations_impl(hours=48, db_path=str(populated_db))

    assert result.get("window_hours") == 48


def test_get_active_groups_only(populated_db):
    """Test filtering to groups only."""
    result = get_active_conversations_impl(is_group=True, db_path=str(populated_db))

    for conv in result.get("conversations", []):
        assert conv.get("group", False) is True


def test_get_active_dms_only(populated_db):
    """Test filtering to DMs only."""
    result = get_active_conversations_impl(is_group=False, db_path=str(populated_db))

    for conv in result.get("conversations", []):
        assert conv.get("group", False) is False


def test_get_active_has_activity_summary(populated_db):
    """Test that activity summary is included."""
    result = get_active_conversations_impl(db_path=str(populated_db))

    for conv in result.get("conversations", []):
        assert "activity" in conv


def test_get_active_activity_fields(populated_db):
    """Test that activity has expected fields."""
    result = get_active_conversations_impl(db_path=str(populated_db))

    for conv in result.get("conversations", []):
        activity = conv.get("activity", {})
        assert "exchanges" in activity
        assert "my_msgs" in activity
        assert "their_msgs" in activity


def test_get_active_has_awaiting_reply(populated_db):
    """Test that awaiting_reply flag is included."""
    result = get_active_conversations_impl(db_path=str(populated_db))

    for conv in result.get("conversations", []):
        assert "awaiting_reply" in conv


def test_get_active_has_total(populated_db):
    """Test that total is included."""
    result = get_active_conversations_impl(db_path=str(populated_db))

    assert "total" in result


def test_get_active_has_more(populated_db):
    """Test that more flag is included."""
    result = get_active_conversations_impl(db_path=str(populated_db))

    assert "more" in result


def test_get_active_response_structure(populated_db):
    """Test that response has expected structure."""
    result = get_active_conversations_impl(db_path=str(populated_db))

    assert "conversations" in result
    assert "total" in result
    assert "window_hours" in result
    assert "more" in result
    assert "cursor" in result


def test_get_active_conversation_structure(populated_db):
    """Test that conversations have expected structure."""
    result = get_active_conversations_impl(db_path=str(populated_db))

    for conv in result.get("conversations", []):
        assert "id" in conv
        assert "name" in conv
        assert "participants" in conv
        assert "activity" in conv
        assert "awaiting_reply" in conv


def test_get_active_chat_id_format(populated_db):
    """Test that chat ID is properly formatted."""
    result = get_active_conversations_impl(db_path=str(populated_db))

    for conv in result.get("conversations", []):
        assert conv["id"].startswith("chat")


def test_get_active_participants_structure(populated_db):
    """Test that participants have expected structure."""
    result = get_active_conversations_impl(db_path=str(populated_db))

    for conv in result.get("conversations", []):
        for participant in conv.get("participants", []):
            assert "handle" in participant
            assert "name" in participant


def test_get_active_with_limit(populated_db):
    """Test limit parameter."""
    result = get_active_conversations_impl(limit=1, db_path=str(populated_db))

    assert len(result.get("conversations", [])) <= 1


def test_get_active_min_exchanges_filter(populated_db):
    """Test min_exchanges filter."""
    result = get_active_conversations_impl(min_exchanges=1, db_path=str(populated_db))

    for conv in result.get("conversations", []):
        assert conv["activity"]["exchanges"] >= 1


def test_get_active_high_min_exchanges(populated_db):
    """Test that high min_exchanges returns empty or few results."""
    result = get_active_conversations_impl(min_exchanges=100, db_path=str(populated_db))

    # With min_exchanges=100, should return no conversations from test data
    assert len(result.get("conversations", [])) == 0


def test_get_active_database_not_found():
    """Test database not found error."""
    result = get_active_conversations_impl(db_path="/nonexistent/path/chat.db")

    assert "error" in result
    assert result["error"] == "database_not_found"


def test_get_active_empty_db(mock_db_path):
    """Test handling of empty database."""
    result = get_active_conversations_impl(db_path=str(mock_db_path))

    assert "conversations" in result
    assert len(result["conversations"]) == 0
    assert result["total"] == 0


def test_get_active_input_validation_hours(populated_db):
    """Test that hours parameter is validated."""
    # Test minimum clamping
    result = get_active_conversations_impl(hours=0, db_path=str(populated_db))
    assert result.get("window_hours") == 1  # Should be clamped to 1

    # Test maximum clamping
    result = get_active_conversations_impl(hours=1000, db_path=str(populated_db))
    assert result.get("window_hours") == 168  # Should be clamped to 168 (1 week)


def test_get_active_input_validation_min_exchanges(populated_db):
    """Test that min_exchanges parameter is validated."""
    # Test minimum clamping
    result = get_active_conversations_impl(min_exchanges=0, db_path=str(populated_db))
    # Should complete without error
    assert "conversations" in result


def test_get_active_input_validation_limit(populated_db):
    """Test that limit parameter is validated."""
    # Test minimum clamping
    result = get_active_conversations_impl(limit=0, db_path=str(populated_db))
    # Should complete without error, limit clamped to 1
    assert "conversations" in result

    # Test maximum clamping
    result = get_active_conversations_impl(limit=1000, db_path=str(populated_db))
    # Should complete without error
    assert "conversations" in result
