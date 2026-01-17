"""Tests for list_attachments tool."""

import pytest
from imessage_max.tools.list_attachments import list_attachments_impl


def test_list_attachments_basic(attachments_db):
    """Test basic attachment listing."""
    result = list_attachments_impl(db_path=str(attachments_db))

    assert "attachments" in result
    assert isinstance(result["attachments"], list)


def test_list_attachments_has_people_map(attachments_db):
    """Test people map is included."""
    result = list_attachments_impl(db_path=str(attachments_db))

    assert "people" in result


def test_list_attachments_has_total(attachments_db):
    """Test total count is included."""
    result = list_attachments_impl(db_path=str(attachments_db))

    assert "total" in result


def test_list_attachments_with_limit(attachments_db):
    """Test limit parameter."""
    result = list_attachments_impl(limit=2, db_path=str(attachments_db))

    assert len(result.get("attachments", [])) <= 2


def test_list_attachments_type_filter_image(attachments_db):
    """Test type filter for images."""
    result = list_attachments_impl(type="image", db_path=str(attachments_db))

    for att in result.get("attachments", []):
        assert att.get("type") == "image"


def test_list_attachments_type_filter_video(attachments_db):
    """Test type filter for videos."""
    result = list_attachments_impl(type="video", db_path=str(attachments_db))

    for att in result.get("attachments", []):
        assert att.get("type") == "video"


def test_list_attachments_type_filter_any(attachments_db):
    """Test type filter with 'any' returns all types."""
    result = list_attachments_impl(type="any", db_path=str(attachments_db))

    assert "attachments" in result
    # Should return all attachments regardless of type
    assert len(result["attachments"]) > 0


def test_list_attachments_sort_recent(attachments_db):
    """Test recent_first sort."""
    result = list_attachments_impl(sort="recent_first", db_path=str(attachments_db))

    assert "attachments" in result


def test_list_attachments_sort_oldest(attachments_db):
    """Test oldest_first sort."""
    result = list_attachments_impl(sort="oldest_first", db_path=str(attachments_db))

    assert "attachments" in result


def test_list_attachments_sort_largest(attachments_db):
    """Test largest_first sort."""
    result = list_attachments_impl(sort="largest_first", db_path=str(attachments_db))

    assert "attachments" in result
    # Verify sorted by size descending
    attachments = result.get("attachments", [])
    if len(attachments) >= 2:
        sizes = [att.get("size") or 0 for att in attachments]
        assert sizes == sorted(sizes, reverse=True)


def test_list_attachments_database_not_found():
    """Test database not found error."""
    result = list_attachments_impl(db_path="/nonexistent/path/chat.db")

    assert "error" in result
    assert result["error"] == "database_not_found"


def test_list_attachments_has_more_flag(attachments_db):
    """Test more flag is included."""
    result = list_attachments_impl(db_path=str(attachments_db))

    assert "more" in result


def test_list_attachments_attachment_structure(attachments_db):
    """Test individual attachment structure."""
    result = list_attachments_impl(db_path=str(attachments_db))

    assert "attachments" in result
    if result["attachments"]:
        att = result["attachments"][0]
        # Check required fields
        assert "id" in att
        assert "type" in att
        assert "mime" in att
        assert "size" in att
        assert "size_human" in att
        assert "ts" in att
        assert "from" in att
        assert "chat" in att
        assert "msg_id" in att


def test_list_attachments_id_format(attachments_db):
    """Test attachment IDs have correct format."""
    result = list_attachments_impl(db_path=str(attachments_db))

    for att in result.get("attachments", []):
        assert att["id"].startswith("att")


def test_list_attachments_chat_id_format(attachments_db):
    """Test chat IDs have correct format."""
    result = list_attachments_impl(db_path=str(attachments_db))

    for att in result.get("attachments", []):
        assert att["chat"].startswith("chat")


def test_list_attachments_msg_id_format(attachments_db):
    """Test message IDs have correct format."""
    result = list_attachments_impl(db_path=str(attachments_db))

    for att in result.get("attachments", []):
        assert att["msg_id"].startswith("msg")


def test_list_attachments_size_human_format(attachments_db):
    """Test human readable size format."""
    result = list_attachments_impl(db_path=str(attachments_db))

    for att in result.get("attachments", []):
        size_human = att.get("size_human", "")
        # Should contain a unit
        assert any(unit in size_human for unit in ["B", "KB", "MB", "GB"])


def test_list_attachments_chat_filter(attachments_db):
    """Test filtering by chat_id."""
    result = list_attachments_impl(chat_id="chat1", db_path=str(attachments_db))

    for att in result.get("attachments", []):
        assert att["chat"] == "chat1"


def test_list_attachments_from_me(attachments_db):
    """Test filtering attachments from 'me'."""
    result = list_attachments_impl(from_person="me", db_path=str(attachments_db))

    for att in result.get("attachments", []):
        assert att["from"] == "me"


def test_list_attachments_people_map_has_me(attachments_db):
    """Test that people map includes 'me' when applicable."""
    result = list_attachments_impl(db_path=str(attachments_db))

    # Get all "from" values
    froms = [att.get("from") for att in result.get("attachments", [])]

    # If there are messages from me, people map should include 'me'
    if "me" in froms:
        assert "me" in result["people"]
        assert result["people"]["me"]["is_me"] is True


def test_list_attachments_empty_database(mock_db_path):
    """Test with database that has no attachments."""
    result = list_attachments_impl(db_path=str(mock_db_path))

    assert "attachments" in result
    assert result["attachments"] == []
    assert result["total"] == 0


def test_list_attachments_invalid_sort(attachments_db):
    """Test that invalid sort defaults to recent_first."""
    result = list_attachments_impl(sort="invalid_sort", db_path=str(attachments_db))

    # Should not error, just use default
    assert "attachments" in result


def test_list_attachments_invalid_type(attachments_db):
    """Test that invalid type filter is handled."""
    result = list_attachments_impl(type="invalid_type", db_path=str(attachments_db))

    # Should not error, just return results (treating as "any")
    assert "attachments" in result


def test_list_attachments_limit_boundaries(attachments_db):
    """Test limit boundaries (min 1, max 100)."""
    # Test min boundary
    result = list_attachments_impl(limit=0, db_path=str(attachments_db))
    assert "attachments" in result

    # Test max boundary
    result = list_attachments_impl(limit=200, db_path=str(attachments_db))
    assert len(result.get("attachments", [])) <= 100


def test_list_attachments_from_person_special_chars(attachments_db):
    """Test that special LIKE characters in from_person are escaped."""
    result = list_attachments_impl(from_person="100%_test", db_path=str(attachments_db))
    # Should not cause SQL errors
    assert "error" not in result


def test_list_attachments_invalid_chat_id_format(attachments_db):
    """Test that invalid chat_id format returns an error."""
    result = list_attachments_impl(chat_id="chat_invalid", db_path=str(attachments_db))
    assert "error" in result
    assert result["error"] == "invalid_id"
