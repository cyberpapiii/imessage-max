"""Tests for search tool."""

import pytest
from imessage_max.tools.search import search_impl


def test_search_basic(populated_db):
    """Test basic text search."""
    result = search_impl(query="Hello", db_path=str(populated_db))

    assert "results" in result
    assert isinstance(result["results"], list)


def test_search_with_limit(populated_db):
    """Test limit parameter."""
    result = search_impl(query="Hello", limit=2, db_path=str(populated_db))

    assert len(result.get("results", [])) <= 2


def test_search_has_people_map(populated_db):
    """Test people map is included."""
    result = search_impl(query="Hello", db_path=str(populated_db))

    assert "people" in result


def test_search_grouped_format(populated_db):
    """Test grouped_by_chat format."""
    result = search_impl(query="Hello", format="grouped_by_chat", db_path=str(populated_db))

    assert "chats" in result
    assert "chat_count" in result


def test_search_with_since(populated_db):
    """Test time filtering."""
    result = search_impl(query="Hello", since="7d", db_path=str(populated_db))

    assert "results" in result


def test_search_no_results(populated_db):
    """Test empty results."""
    result = search_impl(query="xyznonexistent123", db_path=str(populated_db))

    assert result.get("total", 0) == 0


def test_search_has_total(populated_db):
    """Test total count included."""
    result = search_impl(query="Hello", db_path=str(populated_db))

    assert "total" in result


def test_search_input_validation():
    """Test empty query returns error."""
    result = search_impl(query="", db_path="/nonexistent")

    assert "error" in result


def test_search_empty_whitespace_query():
    """Test whitespace-only query returns error."""
    result = search_impl(query="   ", db_path="/nonexistent")

    assert "error" in result
    assert result["error"] == "invalid_query"


def test_search_limit_capped_at_100(populated_db):
    """Test limit is capped at 100."""
    result = search_impl(query="Hello", limit=500, db_path=str(populated_db))

    # Should not error, limit internally capped
    assert "results" in result or "error" not in result


def test_search_from_me(populated_db):
    """Test filtering by 'me' sender."""
    result = search_impl(query="How", from_person="me", db_path=str(populated_db))

    assert "results" in result
    # "How are you?" is from_me=1 in test data
    if result.get("results"):
        for msg in result["results"]:
            assert msg.get("from") == "me"


def test_search_oldest_first_sort(populated_db):
    """Test oldest_first sort order."""
    result = search_impl(query="Hello", sort="oldest_first", db_path=str(populated_db))

    assert "results" in result


def test_search_invalid_sort_defaults_to_recent(populated_db):
    """Test invalid sort defaults to recent_first."""
    result = search_impl(query="Hello", sort="invalid_sort", db_path=str(populated_db))

    # Should not error, invalid sort defaults to recent_first
    assert "results" in result or "chats" in result


def test_search_database_not_found():
    """Test database not found error."""
    result = search_impl(query="test", db_path="/nonexistent/path/chat.db")

    assert "error" in result
    assert result["error"] == "database_not_found"


def test_search_in_chat_filter(populated_db):
    """Test searching within specific chat."""
    result = search_impl(query="Hello", in_chat="chat1", db_path=str(populated_db))

    assert "results" in result
    # All results should be from chat1
    for msg in result.get("results", []):
        assert msg.get("chat") == "chat1"


def test_search_result_structure(populated_db):
    """Test search result has expected fields."""
    result = search_impl(query="Hello", db_path=str(populated_db))

    if result.get("results"):
        msg = result["results"][0]
        assert "id" in msg
        assert "ts" in msg
        assert "text" in msg
        assert "chat" in msg


def test_search_grouped_response_structure(populated_db):
    """Test grouped response has expected fields."""
    result = search_impl(query="Hello", format="grouped_by_chat", db_path=str(populated_db))

    assert "chats" in result
    assert "people" in result
    assert "total" in result
    assert "chat_count" in result
    assert "query" in result

    if result.get("chats"):
        chat = result["chats"][0]
        assert "id" in chat
        assert "match_count" in chat
        assert "sample_messages" in chat


def test_search_more_flag(populated_db):
    """Test 'more' flag is present in response."""
    result = search_impl(query="Hello", db_path=str(populated_db))

    assert "more" in result


def test_search_cursor_field(populated_db):
    """Test cursor field is present in response."""
    result = search_impl(query="Hello", db_path=str(populated_db))

    assert "cursor" in result


def test_search_unanswered(populated_db):
    """Test search with unanswered filter."""
    result = search_impl(
        query="?",
        unanswered=True,
        db_path=str(populated_db),
    )

    assert "error" not in result
    assert "results" in result
    # All results should be from "me"
    for msg in result.get("results", []):
        assert msg.get("from") == "me"


def test_search_unanswered_implies_from_me(populated_db):
    """Test that unanswered=True forces from_me filter."""
    result = search_impl(
        query="help",
        unanswered=True,
        db_path=str(populated_db),
    )

    assert "error" not in result
    # All results should be from "me"
    for msg in result.get("results", []):
        assert msg.get("from") == "me", f"Expected from='me', got {msg.get('from')}"


def test_search_unanswered_returns_questions(populated_db):
    """Test that unanswered filter only returns question-like messages."""
    result = search_impl(
        query="?",
        unanswered=True,
        db_path=str(populated_db),
    )

    assert "results" in result
    # All messages should look like questions
    for msg in result.get("results", []):
        text = msg.get("text", "") or ""
        has_question_mark = "?" in text
        text_lower = text.lower()
        has_question_ending = any(
            text_lower.endswith(ending)
            for ending in ["let me know", "lmk", "thoughts", "please",
                          "can you", "could you", "would you", "will you",
                          "what do you think"]
        )
        assert has_question_mark or has_question_ending, f"Message '{text}' does not look like a question"


def test_search_unanswered_excludes_answered(populated_db):
    """Test that unanswered filter excludes messages with replies within 24h."""
    result = search_impl(
        query="time",
        unanswered=True,
        db_path=str(populated_db),
    )

    # Should not include "What time is the meeting?" since it got a quick reply
    texts = [msg.get("text", "") for msg in result.get("results", [])]
    assert not any("meeting" in (t or "").lower() for t in texts), \
        "Should not include answered question about meeting"


def test_search_unanswered_with_grouped_format(populated_db):
    """Test unanswered filter with grouped_by_chat format."""
    result = search_impl(
        query="?",
        unanswered=True,
        format="grouped_by_chat",
        db_path=str(populated_db),
    )

    assert "error" not in result
    assert "chats" in result
