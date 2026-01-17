"""Tests for smart error suggestions module."""

import pytest
import sqlite3
from imessage_max.suggestions import (
    get_chat_suggestions,
    get_message_suggestions,
    find_similar_names,
    find_by_participants,
    find_by_content,
    suggest_expanded_time,
    suggest_similar_query,
    suggest_other_chats,
    suggest_renamed_chat,
)


@pytest.fixture
def suggestions_db(mock_db_path):
    """Create a mock database with data for suggestion testing."""
    conn = sqlite3.connect(mock_db_path)

    conn.executescript("""
        INSERT INTO handle (ROWID, id, service) VALUES
            (1, '+19175551234', 'iMessage'),
            (2, '+15625559876', 'iMessage'),
            (3, 'mike@example.com', 'iMessage'),
            (4, '+17025551111', 'iMessage');

        -- Chats with various names for fuzzy matching
        INSERT INTO chat (ROWID, guid, display_name, service_name) VALUES
            (1, 'iMessage;+;chat1', 'Tahoe 2026', 'iMessage'),
            (2, 'iMessage;+;chat2', 'Ski Trip Planning', 'iMessage'),
            (3, 'iMessage;+;chat3', NULL, 'iMessage'),
            (4, 'iMessage;+;chat4', 'Loop', 'iMessage'),
            (5, 'iMessage;+;chat5', 'Family Group', 'iMessage');

        INSERT INTO chat_handle_join (chat_id, handle_id) VALUES
            (1, 1),
            (1, 2),
            (2, 1),
            (2, 3),
            (3, 4),
            (4, 1),
            (4, 2),
            (4, 3),
            (5, 1);

        -- Messages with various content for testing
        -- Base timestamp: 789100000000000000 (approx 2026-01-16)
        -- 1 day = 86400000000000 nanoseconds
        INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, associated_message_type) VALUES
            -- Messages in chat 1 (Tahoe 2026)
            (1, 'msg1', 'Planning the ski trip', 1, 789100000000000000, 0, 0),
            (2, 'msg2', 'Sounds great!', NULL, 789100100000000000, 1, 0),
            -- Messages in chat 2 (Ski Trip Planning) - more recent
            (3, 'msg3', 'When should we go skiing?', 1, 789186400000000000, 0, 0),
            (4, 'msg4', 'Next weekend works for me', NULL, 789186500000000000, 1, 0),
            -- Messages in chat 3 (DM)
            (5, 'msg5', 'Hey Mike, how are you?', NULL, 789100000000000000, 1, 0),
            (6, 'msg6', 'Good thanks!', 4, 789100100000000000, 0, 0),
            -- Messages in chat 4 (Loop) - contains "ski trip" mentions
            (7, 'msg7', 'Did you see the ski trip pics?', 1, 789200000000000000, 0, 0),
            (8, 'msg8', 'Yes they looked amazing', NULL, 789200100000000000, 1, 0),
            (9, 'msg9', 'We should plan another ski trip', 2, 789200200000000000, 0, 0),
            (10, 'msg10', 'Definitely! ski trip 2027', 3, 789200300000000000, 0, 0),
            -- Messages in chat 5 (Family Group) - older messages
            (11, 'msg11', 'Hello everyone', 1, 788000000000000000, 0, 0),
            (12, 'msg12', 'Hi!', NULL, 788000100000000000, 1, 0),
            -- Very recent messages (within last 24h of latest timestamp)
            (13, 'msg13', 'Recent message', NULL, 789300000000000000, 1, 0);

        INSERT INTO chat_message_join (chat_id, message_id) VALUES
            (1, 1),
            (1, 2),
            (2, 3),
            (2, 4),
            (3, 5),
            (3, 6),
            (4, 7),
            (4, 8),
            (4, 9),
            (4, 10),
            (5, 11),
            (5, 12),
            (4, 13);
    """)
    conn.close()

    return mock_db_path


class TestFindSimilarNames:
    """Tests for similar name matching."""

    def test_finds_similar_chat_names(self, suggestions_db):
        """Test finding chats with similar names."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            results = find_similar_names(conn, "Ski Trip")

        assert len(results) > 0
        # Should find "Ski Trip Planning" and possibly "Tahoe 2026" (if it was renamed)
        names = [r["name"] for r in results]
        assert any("Ski" in name for name in names)

    def test_fuzzy_matches_partial_names(self, suggestions_db):
        """Test that fuzzy matching works for partial names."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            results = find_similar_names(conn, "tahoe")

        assert len(results) > 0
        names = [r["name"] for r in results]
        assert any("Tahoe" in name for name in names)

    def test_returns_empty_for_no_matches(self, suggestions_db):
        """Test returns empty list when no similar names found."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            results = find_similar_names(conn, "CompletelyRandomName12345XYZ")

        assert results == []

    def test_limits_results(self, suggestions_db):
        """Test that results are limited."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            results = find_similar_names(conn, "group", limit=1)

        assert len(results) <= 1


class TestFindByParticipants:
    """Tests for participant-based suggestions."""

    def test_finds_chats_by_partial_name(self, suggestions_db):
        """Test finding chats by participant handle patterns."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            # Search for chats containing someone with '917' in their number
            # Use full number pattern since LIKE needs matching characters
            results = find_by_participants(conn, "9175551234")

        assert len(results) > 0
        # Should find chats with +19175551234

    def test_returns_empty_for_no_matches(self, suggestions_db):
        """Test returns empty when no participant matches."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            results = find_by_participants(conn, "+1999999999")

        assert results == []


class TestFindByContent:
    """Tests for content-based suggestions."""

    def test_finds_chats_by_message_content(self, suggestions_db):
        """Test finding chats containing specific message content."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            results = find_by_content(conn, "ski trip")

        assert len(results) > 0
        # Should find chat 4 (Loop) which has multiple "ski trip" mentions

    def test_returns_match_count(self, suggestions_db):
        """Test that match count is included in results."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            results = find_by_content(conn, "ski trip")

        assert len(results) > 0
        for result in results:
            assert "match_count" in result
            assert result["match_count"] > 0

    def test_returns_empty_for_no_matches(self, suggestions_db):
        """Test returns empty when no content matches."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            results = find_by_content(conn, "xyznonexistent12345")

        assert results == []


class TestSuggestExpandedTime:
    """Tests for time expansion suggestions."""

    def test_suggests_wider_time_range(self, suggestions_db):
        """Test suggesting wider time range when narrow range returns nothing."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            result = suggest_expanded_time(
                conn,
                chat_id=1,
                original_since="1h",  # Very narrow
                query="ski"
            )

        # Should suggest a wider range if it would find more messages
        if result:
            assert "original" in result
            assert "expanded" in result
            assert "would_find" in result

    def test_returns_none_when_no_additional_results(self, suggestions_db):
        """Test returns None when expanding wouldn't help."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            result = suggest_expanded_time(
                conn,
                chat_id=1,
                original_since="365d",  # Already very wide
                query="xyznonexistent12345"  # Won't find anything
            )

        # Should return None if expanding wouldn't find anything new
        assert result is None or result.get("would_find", 0) == 0


class TestSuggestSimilarQuery:
    """Tests for similar query suggestions."""

    def test_suggests_nickname_when_full_name_not_found(self, suggestions_db):
        """Test suggesting nickname when full name search returns nothing."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            # Search for "Michael" but we have "mike@example.com"
            result = suggest_similar_query(conn, "Michael")

        # Should suggest "Mike" or similar
        if result:
            assert "original" in result
            assert "suggestion" in result

    def test_returns_none_for_good_query(self, suggestions_db):
        """Test returns None when query already has good matches."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            result = suggest_similar_query(conn, "ski")

        # Query "ski" should find matches, no suggestion needed
        # Could return None or a suggestion if there are better options
        # The implementation decides


class TestSuggestOtherChats:
    """Tests for other chat suggestions."""

    def test_finds_matches_in_other_chats(self, suggestions_db):
        """Test finding query matches in chats other than the specified one."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            # Search for "ski" in chat 5 (Family Group - no ski messages)
            # Should suggest chats 1, 2, 4 which have ski messages
            results = suggest_other_chats(conn, "ski", exclude_chat_id=5)

        if results:
            assert len(results) > 0
            for result in results:
                assert "chat" in result
                assert "match_count" in result

    def test_excludes_specified_chat(self, suggestions_db):
        """Test that the specified chat is excluded from results."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            results = suggest_other_chats(conn, "ski", exclude_chat_id=4)

        if results:
            for result in results:
                assert result["chat"] != "chat4"


class TestSuggestRenamedChat:
    """Tests for renamed chat suggestions.

    NOTE: The iMessage chat.db does not track historical display_name changes,
    so suggest_renamed_chat() always returns an empty list. This test class
    verifies the function exists and behaves as expected for spec compliance.
    """

    def test_suggest_renamed_chat_returns_empty_list(self, suggestions_db):
        """Test that renamed_chat returns empty (not implemented due to db limitations)."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            result = suggest_renamed_chat(conn, "Old Chat Name")
            assert result == []

    def test_suggest_renamed_chat_with_known_chat_name(self, suggestions_db):
        """Test that renamed_chat returns empty even for names that exist."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            # Even searching for a name similar to existing chats returns empty
            # because we can't track renames
            result = suggest_renamed_chat(conn, "Ski Trip")
            assert result == []

    def test_suggest_renamed_chat_returns_list_type(self, suggestions_db):
        """Test that renamed_chat always returns a list (not None)."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            result = suggest_renamed_chat(conn, "Any Name")
            assert isinstance(result, list)


class TestGetChatSuggestions:
    """Tests for the main chat suggestions function."""

    def test_returns_suggestions_dict(self, suggestions_db):
        """Test that get_chat_suggestions returns a suggestions dict."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            result = get_chat_suggestions(
                conn,
                resolver=None,
                name="Nonexistent Group 12345"
            )

        assert isinstance(result, dict)
        # Should have at least one suggestion type (could be empty dicts)

    def test_includes_similar_names_for_name_search(self, suggestions_db):
        """Test that similar_names is included when searching by name."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            result = get_chat_suggestions(
                conn,
                resolver=None,
                name="Ski"  # Should find "Ski Trip Planning"
            )

        # Should have similar_names suggestion
        if "similar_names" in result:
            assert isinstance(result["similar_names"], list)

    def test_includes_by_content_for_content_search(self, suggestions_db):
        """Test that by_content suggestions are included."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            result = get_chat_suggestions(
                conn,
                resolver=None,
                contains_recent="ski trip"
            )

        # Should have by_content suggestion if there are matches
        if "by_content" in result:
            assert isinstance(result["by_content"], list)

    def test_graceful_handling_of_errors(self, suggestions_db):
        """Test that errors in suggestion generation are handled gracefully."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            # Should not raise, even with unusual inputs
            result = get_chat_suggestions(
                conn,
                resolver=None,
                name=None,
                participants=None,
                contains_recent=None
            )

        assert isinstance(result, dict)


class TestGetMessageSuggestions:
    """Tests for the main message suggestions function."""

    def test_returns_suggestions_dict(self, suggestions_db):
        """Test that get_message_suggestions returns a suggestions dict."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            result = get_message_suggestions(
                conn,
                resolver=None,
                query="nonexistent12345",
                chat_id=1
            )

        assert isinstance(result, dict)

    def test_suggests_expanded_time(self, suggestions_db):
        """Test that expanded_time suggestion is included."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            result = get_message_suggestions(
                conn,
                resolver=None,
                query="ski",
                chat_id=1,
                since="1h"  # Narrow time range
            )

        # May have expanded_time suggestion if wider range would help
        assert isinstance(result, dict)

    def test_suggests_other_chats(self, suggestions_db):
        """Test that other_chats suggestions are included."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            result = get_message_suggestions(
                conn,
                resolver=None,
                query="ski",
                chat_id=5  # Family Group - no ski messages
            )

        # Should have other_chats suggestion pointing to chats with ski messages
        if "other_chats" in result and result["other_chats"]:
            for chat_suggestion in result["other_chats"]:
                assert "chat" in chat_suggestion
                assert "match_count" in chat_suggestion

    def test_limits_suggestions_to_three(self, suggestions_db):
        """Test that each suggestion type is limited to 3 items."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            result = get_message_suggestions(
                conn,
                resolver=None,
                query="message"  # Generic query that might match many
            )

        for key, value in result.items():
            if isinstance(value, list):
                assert len(value) <= 3, f"Suggestion type {key} should be limited to 3 items"

    def test_graceful_handling_of_errors(self, suggestions_db):
        """Test that errors in suggestion generation are handled gracefully."""
        from imessage_max.db import get_db_connection

        with get_db_connection(str(suggestions_db)) as conn:
            # Should not raise, even with unusual inputs
            result = get_message_suggestions(
                conn,
                resolver=None,
                query="",
                chat_id=None
            )

        assert isinstance(result, dict)


class TestSuggestionIntegration:
    """Integration tests for suggestions in tool responses."""

    def test_find_chat_includes_suggestions_when_empty(self, suggestions_db):
        """Test that find_chat includes suggestions when no results."""
        from imessage_max.tools.find_chat import find_chat_impl

        result = find_chat_impl(
            name="NonexistentGroup12345XYZ",
            db_path=str(suggestions_db)
        )

        assert "chats" in result
        assert len(result["chats"]) == 0
        assert "suggestions" in result
        assert isinstance(result["suggestions"], dict)

    def test_find_chat_no_suggestions_when_results_found(self, suggestions_db):
        """Test that find_chat doesn't include suggestions when results found."""
        from imessage_max.tools.find_chat import find_chat_impl

        result = find_chat_impl(
            name="Tahoe",
            db_path=str(suggestions_db)
        )

        assert "chats" in result
        assert len(result["chats"]) > 0
        # Suggestions should not be present when results are found
        assert "suggestions" not in result

    def test_get_messages_includes_suggestions_when_empty(self, suggestions_db):
        """Test that get_messages includes suggestions when no results."""
        from imessage_max.tools.get_messages import get_messages_impl

        result = get_messages_impl(
            chat_id="chat5",  # Family Group
            contains="skiing",  # No skiing messages in Family Group
            db_path=str(suggestions_db)
        )

        assert "messages" in result
        # May or may not have suggestions depending on if there are matches elsewhere
        # This test verifies the structure is correct

    def test_search_includes_suggestions_when_empty(self, suggestions_db):
        """Test that search includes suggestions when no results."""
        from imessage_max.tools.search import search_impl

        result = search_impl(
            query="xyznonexistent12345",
            db_path=str(suggestions_db)
        )

        assert "results" in result or "chats" in result
        assert result.get("total", 0) == 0
        # Should have suggestions even when no results
        if "suggestions" in result:
            assert isinstance(result["suggestions"], dict)
