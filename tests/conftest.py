"""Pytest configuration and fixtures."""

import pytest
import sqlite3


@pytest.fixture
def mock_db_path(tmp_path):
    """Create a temporary mock chat.db for testing."""
    db_path = tmp_path / "chat.db"
    conn = sqlite3.connect(db_path)

    # Create minimal schema
    conn.executescript("""
        CREATE TABLE handle (
            ROWID INTEGER PRIMARY KEY,
            id TEXT UNIQUE,
            service TEXT
        );

        CREATE TABLE chat (
            ROWID INTEGER PRIMARY KEY,
            guid TEXT UNIQUE,
            display_name TEXT,
            service_name TEXT
        );

        CREATE TABLE message (
            ROWID INTEGER PRIMARY KEY,
            guid TEXT UNIQUE,
            text TEXT,
            attributedBody BLOB,
            handle_id INTEGER,
            date INTEGER,
            date_read INTEGER,
            is_from_me INTEGER,
            associated_message_type INTEGER DEFAULT 0,
            associated_message_guid TEXT,
            cache_has_attachments INTEGER DEFAULT 0,
            FOREIGN KEY (handle_id) REFERENCES handle(ROWID)
        );

        CREATE TABLE chat_handle_join (
            chat_id INTEGER,
            handle_id INTEGER,
            PRIMARY KEY (chat_id, handle_id)
        );

        CREATE TABLE chat_message_join (
            chat_id INTEGER,
            message_id INTEGER,
            PRIMARY KEY (chat_id, message_id)
        );

        CREATE TABLE attachment (
            ROWID INTEGER PRIMARY KEY,
            guid TEXT UNIQUE,
            filename TEXT,
            mime_type TEXT,
            uti TEXT,
            total_bytes INTEGER,
            transfer_name TEXT
        );

        CREATE TABLE message_attachment_join (
            message_id INTEGER,
            attachment_id INTEGER,
            PRIMARY KEY (message_id, attachment_id)
        );
    """)
    conn.close()

    return db_path


@pytest.fixture
def populated_db(mock_db_path):
    """Create a mock database with sample data."""
    conn = sqlite3.connect(mock_db_path)

    # Insert sample handles
    conn.executescript("""
        INSERT INTO handle (ROWID, id, service) VALUES
            (1, '+19175551234', 'iMessage'),
            (2, '+15625559876', 'iMessage'),
            (3, 'test@example.com', 'iMessage');

        INSERT INTO chat (ROWID, guid, display_name, service_name) VALUES
            (1, 'iMessage;+;chat123', NULL, 'iMessage'),
            (2, 'iMessage;+;chat456', 'Test Group', 'iMessage');

        INSERT INTO chat_handle_join (chat_id, handle_id) VALUES
            (1, 1),
            (2, 1),
            (2, 2);

        -- Messages: Apple epoch nanoseconds (2026-01-16 = ~789100000000000000)
        -- 24 hours = 86400 seconds = 86400000000000 nanoseconds
        INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, associated_message_type) VALUES
            (1, 'msg1', 'Hello world', 1, 789100000000000000, 0, 0),
            (2, 'msg2', 'How are you?', NULL, 789100100000000000, 1, 0),
            (3, 'msg3', NULL, 1, 789100200000000000, 0, 2000),
            -- Unanswered question (no reply within 24h - reply comes after 48h)
            (4, 'msg4', 'Can you help me with this?', NULL, 789200000000000000, 1, 0),
            (5, 'msg5', 'Sure, what do you need?', 1, 789400000000000000, 0, 0),
            -- Answered question (reply within 24h)
            (6, 'msg6', 'What time is the meeting?', NULL, 789500000000000000, 1, 0),
            (7, 'msg7', 'It is at 3pm', 1, 789500100000000000, 0, 0),
            -- Unanswered message with "let me know" (no reply)
            (8, 'msg8', 'Check out this link and let me know', NULL, 789600000000000000, 1, 0);

        INSERT INTO chat_message_join (chat_id, message_id) VALUES
            (1, 1),
            (1, 2),
            (1, 3),
            (1, 4),
            (1, 5),
            (1, 6),
            (1, 7),
            (1, 8);
    """)
    conn.close()

    return mock_db_path


@pytest.fixture
def attachments_db(mock_db_path):
    """Create a mock database with attachment data for testing."""
    conn = sqlite3.connect(mock_db_path)

    # Insert sample handles
    conn.executescript("""
        INSERT INTO handle (ROWID, id, service) VALUES
            (1, '+19175551234', 'iMessage'),
            (2, '+15625559876', 'iMessage');

        INSERT INTO chat (ROWID, guid, display_name, service_name) VALUES
            (1, 'iMessage;+;chat123', NULL, 'iMessage'),
            (2, 'iMessage;+;chat456', 'Test Group', 'iMessage');

        INSERT INTO chat_handle_join (chat_id, handle_id) VALUES
            (1, 1),
            (2, 1),
            (2, 2);

        -- Messages with attachments: Apple epoch nanoseconds
        -- Using different dates for sort testing
        INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, cache_has_attachments) VALUES
            (1, 'msg1', 'Check out this photo!', 1, 789100000000000000, 0, 1),
            (2, 'msg2', 'Here is the video', NULL, 789100100000000000, 1, 1),
            (3, 'msg3', 'Document attached', 1, 789100200000000000, 0, 1),
            (4, 'msg4', 'Another image', 2, 789100300000000000, 0, 1),
            (5, 'msg5', 'Audio message', NULL, 789100400000000000, 1, 1);

        INSERT INTO chat_message_join (chat_id, message_id) VALUES
            (1, 1),
            (1, 2),
            (1, 3),
            (2, 4),
            (2, 5);

        -- Attachments with various types and sizes
        INSERT INTO attachment (ROWID, guid, filename, mime_type, uti, total_bytes, transfer_name) VALUES
            (1, 'att1', '~/Library/Messages/Attachments/IMG_001.jpg', 'image/jpeg', 'public.jpeg', 2458624, 'IMG_001.jpg'),
            (2, 'att2', '~/Library/Messages/Attachments/video.mp4', 'video/mp4', 'public.movie', 15728640, 'video.mp4'),
            (3, 'att3', '~/Library/Messages/Attachments/document.pdf', 'application/pdf', 'com.adobe.pdf', 1048576, 'document.pdf'),
            (4, 'att4', '~/Library/Messages/Attachments/photo.png', 'image/png', 'public.png', 524288, 'photo.png'),
            (5, 'att5', '~/Library/Messages/Attachments/voice.m4a', 'audio/x-m4a', 'public.audio', 262144, 'voice.m4a');

        INSERT INTO message_attachment_join (message_id, attachment_id) VALUES
            (1, 1),
            (2, 2),
            (3, 3),
            (4, 4),
            (5, 5);
    """)
    conn.close()

    return mock_db_path
