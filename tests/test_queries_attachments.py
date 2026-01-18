"""Tests for attachment queries."""

import pytest
import sqlite3
from imessage_max.queries import get_attachments_for_messages


@pytest.fixture
def db_with_attachments(mock_db_path):
    """Create database with messages and attachments."""
    conn = sqlite3.connect(mock_db_path)
    conn.executescript("""
        INSERT INTO handle (ROWID, id, service) VALUES
            (1, '+19175551234', 'iMessage');

        INSERT INTO chat (ROWID, guid, display_name, service_name) VALUES
            (1, 'iMessage;+;chat123', NULL, 'iMessage');

        INSERT INTO chat_handle_join (chat_id, handle_id) VALUES
            (1, 1);

        INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, cache_has_attachments) VALUES
            (1, 'msg1', 'Photo', 1, 789100000000000000, 0, 1),
            (2, 'msg2', 'No attachment', 1, 789100100000000000, 0, 0),
            (3, 'msg3', 'Video', 1, 789100200000000000, 0, 1);

        INSERT INTO chat_message_join (chat_id, message_id) VALUES
            (1, 1), (1, 2), (1, 3);

        INSERT INTO attachment (ROWID, guid, filename, mime_type, uti, total_bytes) VALUES
            (1, 'att1', '~/Library/Messages/Attachments/IMG.HEIC', 'image/heic', 'public.heic', 2048000),
            (2, 'att2', '~/Library/Messages/Attachments/VID.mov', 'video/quicktime', 'public.movie', 15000000);

        INSERT INTO message_attachment_join (message_id, attachment_id) VALUES
            (1, 1),
            (3, 2);
    """)
    conn.close()
    return mock_db_path


class TestGetAttachmentsForMessages:
    """Tests for get_attachments_for_messages function."""

    def test_returns_attachments_grouped_by_message(self, db_with_attachments):
        """Should return attachments grouped by message ID."""
        conn = sqlite3.connect(db_with_attachments)
        conn.row_factory = sqlite3.Row

        result = get_attachments_for_messages(conn, [1, 2, 3])
        conn.close()

        assert 1 in result
        assert 2 not in result  # No attachment
        assert 3 in result

        assert result[1][0]["filename"].endswith("IMG.HEIC")
        assert result[1][0]["mime_type"] == "image/heic"

        assert result[3][0]["filename"].endswith("VID.mov")

    def test_returns_empty_for_no_messages(self, db_with_attachments):
        """Should return empty dict for empty message list."""
        conn = sqlite3.connect(db_with_attachments)
        conn.row_factory = sqlite3.Row

        result = get_attachments_for_messages(conn, [])
        conn.close()

        assert result == {}
