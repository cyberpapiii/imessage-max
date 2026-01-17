"""Tests for query building utilities."""

import pytest
from imessage_max.queries import (
    QueryBuilder,
    get_chat_by_id,
    get_chat_participants,
    find_chats_by_handles,
    get_messages_for_chat,
    get_reactions_for_messages,
)


class TestQueryBuilder:
    """Tests for QueryBuilder class."""

    def test_query_builder_basic(self):
        """Test basic query building."""
        qb = QueryBuilder()
        qb.select("m.ROWID", "m.text")
        qb.from_table("message m")
        qb.where("m.is_from_me = ?", 1)
        qb.limit(10)

        query, params = qb.build()
        assert "SELECT" in query
        assert "m.ROWID" in query
        assert "m.text" in query
        assert "FROM message m" in query
        assert "WHERE" in query
        assert "m.is_from_me = ?" in query
        assert "LIMIT 10" in query
        assert params == [1]

    def test_query_builder_joins(self):
        """Test query with joins."""
        qb = QueryBuilder()
        qb.select("m.text", "h.id")
        qb.from_table("message m")
        qb.join("handle h ON m.handle_id = h.ROWID")

        query, params = qb.build()
        assert "JOIN handle h ON m.handle_id = h.ROWID" in query
        assert params == []

    def test_query_builder_left_join(self):
        """Test query with left join."""
        qb = QueryBuilder()
        qb.select("m.text")
        qb.from_table("message m")
        qb.left_join("handle h ON m.handle_id = h.ROWID")

        query, params = qb.build()
        assert "LEFT JOIN handle h ON m.handle_id = h.ROWID" in query

    def test_query_builder_multiple_where_conditions(self):
        """Test multiple where conditions joined with AND."""
        qb = QueryBuilder()
        qb.select("m.ROWID")
        qb.from_table("message m")
        qb.where("m.is_from_me = ?", 1)
        qb.where("m.date > ?", 1000)

        query, params = qb.build()
        assert "WHERE m.is_from_me = ? AND m.date > ?" in query
        assert params == [1, 1000]

    def test_query_builder_group_by(self):
        """Test GROUP BY clause."""
        qb = QueryBuilder()
        qb.select("h.id", "COUNT(*) as count")
        qb.from_table("message m")
        qb.join("handle h ON m.handle_id = h.ROWID")
        qb.group_by("h.id")

        query, params = qb.build()
        assert "GROUP BY h.id" in query

    def test_query_builder_order_by(self):
        """Test ORDER BY clause."""
        qb = QueryBuilder()
        qb.select("m.ROWID", "m.date")
        qb.from_table("message m")
        qb.order_by("m.date DESC")

        query, params = qb.build()
        assert "ORDER BY m.date DESC" in query

    def test_query_builder_offset(self):
        """Test OFFSET clause."""
        qb = QueryBuilder()
        qb.select("m.ROWID")
        qb.from_table("message m")
        qb.limit(10)
        qb.offset(20)

        query, params = qb.build()
        assert "LIMIT 10" in query
        assert "OFFSET 20" in query

    def test_query_builder_fluent_api(self):
        """Test fluent/chaining API."""
        qb = QueryBuilder()
        query, params = (
            qb.select("m.ROWID", "m.text")
            .from_table("message m")
            .where("m.is_from_me = ?", 1)
            .order_by("m.date DESC")
            .limit(5)
            .build()
        )

        assert "SELECT m.ROWID, m.text" in query
        assert "FROM message m" in query
        assert "WHERE m.is_from_me = ?" in query
        assert "ORDER BY m.date DESC" in query
        assert "LIMIT 5" in query
        assert params == [1]


class TestChatQueries:
    """Tests for chat-related query functions."""

    def test_get_chat_by_id(self, populated_db):
        """Test retrieving chat by ROWID."""
        from imessage_max.db import get_db_connection

        with get_db_connection(populated_db) as conn:
            chat = get_chat_by_id(conn, 1)
            assert chat is not None
            assert chat['id'] == 1
            assert chat['guid'] == 'iMessage;+;chat123'
            assert chat['participant_count'] == 1

    def test_get_chat_by_id_group(self, populated_db):
        """Test retrieving group chat."""
        from imessage_max.db import get_db_connection

        with get_db_connection(populated_db) as conn:
            chat = get_chat_by_id(conn, 2)
            assert chat is not None
            assert chat['id'] == 2
            assert chat['display_name'] == 'Test Group'
            assert chat['participant_count'] == 2

    def test_get_chat_by_id_not_found(self, populated_db):
        """Test retrieving non-existent chat."""
        from imessage_max.db import get_db_connection

        with get_db_connection(populated_db) as conn:
            chat = get_chat_by_id(conn, 999)
            assert chat is None

    def test_get_chat_participants(self, populated_db):
        """Test retrieving chat participants."""
        from imessage_max.db import get_db_connection

        with get_db_connection(populated_db) as conn:
            participants = get_chat_participants(conn, 2)  # Group chat
            assert len(participants) == 2
            assert all('handle' in p for p in participants)
            handles = {p['handle'] for p in participants}
            assert '+19175551234' in handles
            assert '+15625559876' in handles

    def test_get_chat_participants_single(self, populated_db):
        """Test retrieving participants from single-person chat."""
        from imessage_max.db import get_db_connection

        with get_db_connection(populated_db) as conn:
            participants = get_chat_participants(conn, 1)
            assert len(participants) == 1
            assert participants[0]['handle'] == '+19175551234'

    def test_find_chats_by_handles(self, populated_db):
        """Test finding chats by participant handles."""
        from imessage_max.db import get_db_connection

        with get_db_connection(populated_db) as conn:
            # Find chats with both handles (should be the group chat)
            chats = find_chats_by_handles(conn, ['+19175551234', '+15625559876'])
            assert len(chats) == 1
            assert chats[0]['id'] == 2

    def test_find_chats_by_handles_single(self, populated_db):
        """Test finding chats with a single handle."""
        from imessage_max.db import get_db_connection

        with get_db_connection(populated_db) as conn:
            # Find chats with single handle (should be both chats)
            chats = find_chats_by_handles(conn, ['+19175551234'])
            assert len(chats) == 2

    def test_find_chats_by_handles_empty(self, populated_db):
        """Test finding chats with empty handles list."""
        from imessage_max.db import get_db_connection

        with get_db_connection(populated_db) as conn:
            chats = find_chats_by_handles(conn, [])
            assert chats == []


class TestMessageQueries:
    """Tests for message-related query functions."""

    def test_get_messages_for_chat(self, populated_db):
        """Test retrieving messages for a chat."""
        from imessage_max.db import get_db_connection

        with get_db_connection(populated_db) as conn:
            messages = get_messages_for_chat(conn, 1)
            # Should return messages excluding reactions (associated_message_type = 0)
            # 8 total messages in chat1, 1 reaction (msg3) excluded = 7 regular messages
            assert len(messages) == 7
            assert all(m['associated_message_type'] == 0 for m in messages)

    def test_get_messages_for_chat_with_limit(self, populated_db):
        """Test message retrieval with limit."""
        from imessage_max.db import get_db_connection

        with get_db_connection(populated_db) as conn:
            messages = get_messages_for_chat(conn, 1, limit=1)
            assert len(messages) == 1

    def test_get_messages_for_chat_contains_filter(self, populated_db):
        """Test message retrieval with text contains filter."""
        from imessage_max.db import get_db_connection

        with get_db_connection(populated_db) as conn:
            messages = get_messages_for_chat(conn, 1, contains="Hello")
            assert len(messages) == 1
            assert "Hello" in messages[0]['text']

    def test_get_messages_for_chat_ordering(self, populated_db):
        """Test that messages are ordered by date DESC."""
        from imessage_max.db import get_db_connection

        with get_db_connection(populated_db) as conn:
            messages = get_messages_for_chat(conn, 1)
            # Verify descending order (most recent first)
            dates = [m['date'] for m in messages]
            assert dates == sorted(dates, reverse=True)


class TestReactionQueries:
    """Tests for reaction-related query functions."""

    def test_get_reactions_for_messages_empty(self, populated_db):
        """Test getting reactions with empty message list."""
        from imessage_max.db import get_db_connection

        with get_db_connection(populated_db) as conn:
            reactions = get_reactions_for_messages(conn, [])
            assert reactions == {}

    def test_get_reactions_for_messages_no_reactions(self, populated_db):
        """Test getting reactions for messages without reactions."""
        from imessage_max.db import get_db_connection

        with get_db_connection(populated_db) as conn:
            # msg1 and msg2 don't have reactions in our test data
            reactions = get_reactions_for_messages(conn, ['msg1', 'msg2'])
            # Should return empty since no reactions target these messages
            assert reactions == {}


class TestIntegration:
    """Integration tests combining multiple query functions."""

    def test_get_chat_with_participants_and_messages(self, populated_db):
        """Test retrieving a chat with its participants and messages."""
        from imessage_max.db import get_db_connection

        with get_db_connection(populated_db) as conn:
            chat = get_chat_by_id(conn, 1)
            assert chat is not None

            participants = get_chat_participants(conn, 1)
            assert len(participants) == 1

            messages = get_messages_for_chat(conn, 1)
            assert len(messages) >= 1
