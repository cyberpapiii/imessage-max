"""Pytest configuration and fixtures."""

import pytest
import sqlite3
import tempfile
import os
from pathlib import Path


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
        INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, associated_message_type) VALUES
            (1, 'msg1', 'Hello world', 1, 789100000000000000, 0, 0),
            (2, 'msg2', 'How are you?', NULL, 789100100000000000, 1, 0),
            (3, 'msg3', NULL, 1, 789100200000000000, 0, 2000);

        INSERT INTO chat_message_join (chat_id, message_id) VALUES
            (1, 1),
            (1, 2),
            (1, 3);
    """)
    conn.close()

    return mock_db_path
