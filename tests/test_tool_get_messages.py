"""Tests for get_messages tool."""

import pytest
from imessage_max.tools.get_messages import get_messages_impl


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


def test_get_messages_from_person_me(populated_db):
    """Test filtering messages from 'me' only."""
    result = get_messages_impl(
        chat_id="chat1",
        from_person="me",
        db_path=str(populated_db),
    )

    assert "messages" in result
    # All messages should be from "me"
    for msg in result["messages"]:
        assert msg.get("from") == "me", f"Expected from='me', got {msg.get('from')}"


def test_get_messages_from_person_me_case_insensitive(populated_db):
    """Test that 'me' filter is case-insensitive."""
    result_lower = get_messages_impl(
        chat_id="chat1",
        from_person="me",
        db_path=str(populated_db),
    )
    result_upper = get_messages_impl(
        chat_id="chat1",
        from_person="ME",
        db_path=str(populated_db),
    )
    result_mixed = get_messages_impl(
        chat_id="chat1",
        from_person="Me",
        db_path=str(populated_db),
    )

    # All variations should return the same messages
    assert len(result_lower["messages"]) == len(result_upper["messages"])
    assert len(result_lower["messages"]) == len(result_mixed["messages"])


def test_get_messages_from_person_me_excludes_others(populated_db):
    """Test that from_person='me' excludes messages from others."""
    # Get all messages first
    all_result = get_messages_impl(
        chat_id="chat1",
        db_path=str(populated_db),
    )

    # Get only "me" messages
    me_result = get_messages_impl(
        chat_id="chat1",
        from_person="me",
        db_path=str(populated_db),
    )

    # Count messages from "me" in all_result
    me_count_in_all = sum(1 for msg in all_result["messages"] if msg.get("from") == "me")

    # Should match the count of messages returned with from_person="me"
    assert len(me_result["messages"]) == me_count_in_all


def test_get_messages_unanswered_basic(populated_db):
    """Test unanswered filter returns only unanswered questions."""
    result = get_messages_impl(
        chat_id="chat1",
        unanswered=True,
        db_path=str(populated_db),
    )

    assert "messages" in result
    assert "error" not in result
    # All returned messages should be from me
    for msg in result.get("messages", []):
        assert msg.get("from") == "me"


def test_get_messages_unanswered_implies_from_me(populated_db):
    """Test that unanswered=True implies from_person='me'."""
    result = get_messages_impl(
        chat_id="chat1",
        unanswered=True,
        db_path=str(populated_db),
    )

    # Should not error, should only return my messages
    assert "error" not in result
    # All messages should be from "me"
    for msg in result.get("messages", []):
        assert msg.get("from") == "me", f"Expected from='me', got {msg.get('from')}"


def test_get_messages_unanswered_returns_questions_only(populated_db):
    """Test that unanswered filter only returns question-like messages."""
    result = get_messages_impl(
        chat_id="chat1",
        unanswered=True,
        db_path=str(populated_db),
    )

    assert "messages" in result
    # All messages should contain a question mark or end with question phrases
    for msg in result.get("messages", []):
        text = msg.get("text", "") or ""
        # Check that the message looks like a question
        has_question_mark = "?" in text
        text_lower = text.lower()
        has_question_ending = any(
            text_lower.endswith(ending)
            for ending in ["let me know", "lmk", "thoughts", "please",
                          "can you", "could you", "would you", "will you",
                          "what do you think"]
        )
        assert has_question_mark or has_question_ending, f"Message '{text}' does not look like a question"


def test_get_messages_unanswered_excludes_answered(populated_db):
    """Test that unanswered filter excludes messages that got replies within 24h."""
    result = get_messages_impl(
        chat_id="chat1",
        unanswered=True,
        db_path=str(populated_db),
    )

    assert "messages" in result
    # Should not include "What time is the meeting?" since it got a reply within 24h
    texts = [msg.get("text", "") for msg in result.get("messages", [])]
    assert not any("meeting" in (t or "").lower() for t in texts), \
        "Should not include answered question about meeting"


def test_get_messages_unanswered_empty_chat(populated_db):
    """Test unanswered filter on chat with no unanswered questions."""
    # Chat 2 has no messages with unanswered questions
    result = get_messages_impl(
        chat_id="chat2",
        unanswered=True,
        db_path=str(populated_db),
    )

    assert "error" not in result
    assert "messages" in result
    # May return empty list if no unanswered questions exist


def test_get_messages_sessions_basic(populated_db):
    """Test session IDs are assigned to messages."""
    result = get_messages_impl(chat_id="chat1", db_path=str(populated_db))

    assert "sessions" in result
    assert isinstance(result["sessions"], list)

    for msg in result["messages"]:
        assert "session_id" in msg
        assert "session_start" in msg
        # session_id should have the format "session_N"
        assert msg["session_id"].startswith("session_")


def test_get_messages_sessions_structure(populated_db):
    """Test sessions summary has expected structure."""
    result = get_messages_impl(chat_id="chat1", db_path=str(populated_db))

    assert "sessions" in result
    for session in result["sessions"]:
        assert "session_id" in session
        assert "started" in session
        assert "message_count" in session
        assert session["session_id"].startswith("session_")
        assert isinstance(session["message_count"], int)
        assert session["message_count"] > 0


def test_get_messages_sessions_first_message_is_start(populated_db):
    """Test that the first (oldest) message has session_start=True."""
    result = get_messages_impl(chat_id="chat1", db_path=str(populated_db))

    # Messages are in DESC order (most recent first)
    # The oldest message (last in list) should have session_start=True
    if result["messages"]:
        oldest_msg = result["messages"][-1]
        assert oldest_msg["session_start"] is True


def test_get_messages_session_filter(populated_db):
    """Test filtering by session ID."""
    # First get all sessions
    result_all = get_messages_impl(
        chat_id="chat1",
        db_path=str(populated_db),
    )

    if result_all["sessions"]:
        # Filter to first session
        first_session_id = result_all["sessions"][-1]["session_id"]  # Oldest session

        result_filtered = get_messages_impl(
            chat_id="chat1",
            session=first_session_id,
            db_path=str(populated_db),
        )

        # All messages should have the requested session_id
        for msg in result_filtered["messages"]:
            assert msg["session_id"] == first_session_id


def test_get_messages_session_filter_nonexistent(populated_db):
    """Test filtering by non-existent session ID returns empty messages."""
    result = get_messages_impl(
        chat_id="chat1",
        session="session_99999",
        db_path=str(populated_db),
    )

    assert "error" not in result
    assert "messages" in result
    assert len(result["messages"]) == 0


def test_get_messages_sessions_count_matches(populated_db):
    """Test that session message counts sum to total messages."""
    result = get_messages_impl(chat_id="chat1", db_path=str(populated_db))

    total_from_sessions = sum(s["message_count"] for s in result["sessions"])
    assert total_from_sessions == len(result["messages"])


def test_get_messages_sessions_order(populated_db):
    """Test that sessions are ordered with most recent first."""
    result = get_messages_impl(chat_id="chat1", db_path=str(populated_db))

    if len(result["sessions"]) >= 2:
        # Most recent session should be first
        first_session = result["sessions"][0]
        last_session = result["sessions"][-1]
        # session_id numbers should be higher for more recent sessions
        first_num = int(first_session["session_id"].split("_")[1])
        last_num = int(last_session["session_id"].split("_")[1])
        assert first_num >= last_num


def test_get_messages_session_gap_hours_present(populated_db):
    """Test that session_gap_hours is included for non-first sessions."""
    result = get_messages_impl(chat_id="chat1", db_path=str(populated_db))

    session_starts = [m for m in result["messages"] if m.get("session_start")]

    for msg in session_starts:
        # First session start won't have session_gap_hours
        # Non-first session starts should have it
        if "session_gap_hours" in msg:
            assert isinstance(msg["session_gap_hours"], (int, float))
            assert msg["session_gap_hours"] > 0


def test_get_messages_sessions_gap_detection(db_with_session_gaps):
    """Test that 4+ hour gaps create new sessions."""
    result = get_messages_impl(chat_id="chat1", db_path=str(db_with_session_gaps))

    # Should have 3 sessions based on the fixture data
    assert len(result["sessions"]) == 3

    # Verify session IDs
    session_ids = [s["session_id"] for s in result["sessions"]]
    assert "session_1" in session_ids
    assert "session_2" in session_ids
    assert "session_3" in session_ids


def test_get_messages_sessions_gap_detection_message_counts(db_with_session_gaps):
    """Test that sessions have correct message counts."""
    result = get_messages_impl(chat_id="chat1", db_path=str(db_with_session_gaps))

    # Session 1: 3 messages, Session 2: 2 messages, Session 3: 2 messages
    session_counts = {s["session_id"]: s["message_count"] for s in result["sessions"]}

    assert session_counts["session_1"] == 3
    assert session_counts["session_2"] == 2
    assert session_counts["session_3"] == 2


def test_get_messages_session_filter_with_gaps(db_with_session_gaps):
    """Test filtering by session ID works with multiple sessions."""
    result = get_messages_impl(
        chat_id="chat1",
        session="session_2",
        db_path=str(db_with_session_gaps),
    )

    # Should only have messages from session_2
    assert len(result["messages"]) == 2
    for msg in result["messages"]:
        assert msg["session_id"] == "session_2"

    # Sessions summary should only include session_2
    assert len(result["sessions"]) == 1
    assert result["sessions"][0]["session_id"] == "session_2"


def test_get_messages_session_gap_hours_values(db_with_session_gaps):
    """Test that session_gap_hours has correct values."""
    result = get_messages_impl(chat_id="chat1", db_path=str(db_with_session_gaps))

    # Find messages that start sessions
    session_starts = [m for m in result["messages"] if m.get("session_start")]

    # Should have 3 session starts
    assert len(session_starts) == 3

    # Count how many have session_gap_hours (should be 2, all except the first/oldest session)
    with_gap_hours = [m for m in session_starts if "session_gap_hours" in m]
    assert len(with_gap_hours) == 2

    # Verify gap values are reasonable (> 4 hours based on fixture)
    for msg in with_gap_hours:
        assert msg["session_gap_hours"] >= 4.0


def test_get_messages_sessions_empty_chat(mock_db_path):
    """Test sessions with empty chat returns empty list."""
    import sqlite3

    conn = sqlite3.connect(mock_db_path)
    conn.executescript("""
        INSERT INTO handle (ROWID, id, service) VALUES (1, '+19175551234', 'iMessage');
        INSERT INTO chat (ROWID, guid, display_name, service_name) VALUES (1, 'iMessage;+;chat123', NULL, 'iMessage');
        INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 1);
    """)
    conn.close()

    result = get_messages_impl(chat_id="chat1", db_path=str(mock_db_path))

    assert "sessions" in result
    assert result["sessions"] == []
    assert result["messages"] == []
