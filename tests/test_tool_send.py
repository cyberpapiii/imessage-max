"""Tests for send tool."""

import pytest
from unittest.mock import patch, MagicMock
import sqlite3

from imessage_max.tools.send import (
    send_impl,
    _escape_applescript,
    _send_via_applescript,
    _resolve_recipient,
)


class TestEscapeApplescript:
    """Tests for AppleScript escaping function."""

    def test_escape_quotes(self):
        """Test that double quotes are escaped."""
        result = _escape_applescript('Hello "World"')
        assert result == 'Hello \\"World\\"'

    def test_escape_backslashes(self):
        """Test that backslashes are escaped."""
        result = _escape_applescript('path\\to\\file')
        assert result == 'path\\\\to\\\\file'

    def test_escape_backslash_then_quote(self):
        """Test escaping backslash followed by quote."""
        result = _escape_applescript('test\\"value')
        # Backslash becomes \\, quote becomes \"
        assert result == 'test\\\\\\"value'

    def test_escape_newlines(self):
        """Test that newlines are replaced with spaces."""
        result = _escape_applescript('Hello\nWorld\rTest')
        assert result == 'Hello World Test'

    def test_escape_empty_string(self):
        """Test escaping empty string."""
        result = _escape_applescript('')
        assert result == ''

    def test_escape_plain_text(self):
        """Test that plain text is unchanged."""
        result = _escape_applescript('Hello World')
        assert result == 'Hello World'


class TestSendViaApplescript:
    """Tests for AppleScript send function."""

    @patch('subprocess.run')
    def test_send_success(self, mock_run):
        """Test successful send via AppleScript."""
        mock_run.return_value = MagicMock(returncode=0, stderr='')

        result = _send_via_applescript('+19175551234', 'Hello!')

        assert result['success'] is True
        mock_run.assert_called_once()
        # Verify osascript was called
        call_args = mock_run.call_args
        assert call_args[0][0][0] == 'osascript'

    @patch('subprocess.run')
    def test_send_failure(self, mock_run):
        """Test send failure returns error."""
        mock_run.return_value = MagicMock(
            returncode=1,
            stderr='Error: can\'t get participant'
        )

        result = _send_via_applescript('+19175551234', 'Hello!')

        assert 'error' in result
        assert result['error'] == 'send_failed'

    @patch('subprocess.run')
    def test_send_timeout(self, mock_run):
        """Test send timeout handling."""
        import subprocess
        mock_run.side_effect = subprocess.TimeoutExpired(cmd='osascript', timeout=30)

        result = _send_via_applescript('+19175551234', 'Hello!')

        assert 'error' in result
        assert result['error'] == 'timeout'

    @patch('subprocess.run')
    def test_send_escapes_message(self, mock_run):
        """Test that message content is escaped in AppleScript."""
        mock_run.return_value = MagicMock(returncode=0, stderr='')

        _send_via_applescript('+19175551234', 'Hello "World"')

        call_args = mock_run.call_args
        script = call_args[0][0][2]  # -e argument value
        # The escaped quote should appear in the script
        assert '\\"World\\"' in script


class TestResolveRecipient:
    """Tests for recipient resolution."""

    def test_resolve_phone_number(self, populated_db):
        """Test resolving a phone number."""
        result = _resolve_recipient(
            to='+19175551234',
            db_path=str(populated_db)
        )

        assert 'error' not in result
        assert result['handle'] == '+19175551234'

    def test_resolve_phone_without_plus(self, populated_db):
        """Test resolving a phone number without + prefix."""
        result = _resolve_recipient(
            to='9175551234',
            db_path=str(populated_db)
        )

        # Should normalize and find the handle
        assert 'error' not in result

    def test_resolve_not_found(self, populated_db):
        """Test recipient not found error."""
        result = _resolve_recipient(
            to='+19999999999',
            db_path=str(populated_db)
        )

        assert 'error' in result
        assert result['error'] == 'recipient_not_found'

    def test_resolve_email(self, populated_db):
        """Test resolving an email handle."""
        result = _resolve_recipient(
            to='test@example.com',
            db_path=str(populated_db)
        )

        assert 'error' not in result
        assert result['handle'] == 'test@example.com'


class TestSendImpl:
    """Tests for send_impl function."""

    def test_send_requires_recipient(self, populated_db):
        """Test error when neither to nor chat_id provided."""
        result = send_impl(
            text='Hello!',
            db_path=str(populated_db)
        )

        assert 'error' in result
        assert result['error'] == 'validation_error'
        assert 'to' in result['message'].lower() and 'chat_id' in result['message'].lower()

    def test_send_requires_text(self, populated_db):
        """Test error when text is empty."""
        result = send_impl(
            to='+19175551234',
            text='',
            db_path=str(populated_db)
        )

        assert 'error' in result
        assert result['error'] == 'validation_error'
        assert 'text' in result['message'].lower()

    def test_send_requires_text_none(self, populated_db):
        """Test error when text is None."""
        result = send_impl(
            to='+19175551234',
            text=None,
            db_path=str(populated_db)
        )

        assert 'error' in result
        assert result['error'] == 'validation_error'

    @patch('imessage_max.tools.send._send_via_applescript')
    def test_send_with_to(self, mock_send, populated_db):
        """Test sending with 'to' parameter."""
        mock_send.return_value = {'success': True}

        result = send_impl(
            to='+19175551234',
            text='Hello!',
            db_path=str(populated_db)
        )

        assert result['success'] is True
        mock_send.assert_called_once()

    @patch('imessage_max.tools.send._send_via_applescript')
    def test_send_with_chat_id(self, mock_send, populated_db):
        """Test sending with chat_id parameter."""
        mock_send.return_value = {'success': True}

        result = send_impl(
            chat_id='chat1',
            text='Hello!',
            db_path=str(populated_db)
        )

        assert result['success'] is True
        mock_send.assert_called_once()

    def test_send_invalid_chat_id(self, populated_db):
        """Test error when chat_id doesn't exist."""
        result = send_impl(
            chat_id='chat99999',
            text='Hello!',
            db_path=str(populated_db)
        )

        assert 'error' in result
        assert result['error'] == 'chat_not_found'

    def test_send_recipient_not_found(self, populated_db):
        """Test error when recipient is not found."""
        result = send_impl(
            to='+19999999999',
            text='Hello!',
            db_path=str(populated_db)
        )

        assert 'error' in result
        assert result['error'] == 'recipient_not_found'

    @patch('imessage_max.tools.send._send_via_applescript')
    def test_send_returns_chat_id(self, mock_send, populated_db):
        """Test that successful send returns chat_id."""
        mock_send.return_value = {'success': True}

        result = send_impl(
            to='+19175551234',
            text='Hello!',
            db_path=str(populated_db)
        )

        assert 'chat_id' in result
        assert result['chat_id'].startswith('chat')

    @patch('imessage_max.tools.send._send_via_applescript')
    def test_send_returns_timestamp(self, mock_send, populated_db):
        """Test that successful send returns timestamp."""
        mock_send.return_value = {'success': True}

        result = send_impl(
            to='+19175551234',
            text='Hello!',
            db_path=str(populated_db)
        )

        assert 'timestamp' in result
        # Should be ISO format
        assert 'T' in result['timestamp']

    @patch('imessage_max.tools.send._send_via_applescript')
    def test_send_returns_delivered_to(self, mock_send, populated_db):
        """Test that successful send returns delivered_to list."""
        mock_send.return_value = {'success': True}

        result = send_impl(
            to='+19175551234',
            text='Hello!',
            db_path=str(populated_db)
        )

        assert 'delivered_to' in result
        assert isinstance(result['delivered_to'], list)

    def test_send_reply_to_param_accepted(self, populated_db):
        """Test that reply_to parameter is accepted (future feature)."""
        # This should not raise an error even though reply_to is not implemented
        with patch('imessage_max.tools.send._send_via_applescript') as mock_send:
            mock_send.return_value = {'success': True}

            result = send_impl(
                to='+19175551234',
                text='Hello!',
                reply_to='msg123',
                db_path=str(populated_db)
            )

            # Should succeed - reply_to is accepted but not used yet
            assert result['success'] is True


class TestAmbiguousRecipient:
    """Tests for ambiguous recipient handling."""

    @pytest.fixture
    def ambiguous_db(self, mock_db_path):
        """Create database with multiple contacts named Nick."""
        conn = sqlite3.connect(mock_db_path)
        conn.executescript("""
            INSERT INTO handle (ROWID, id, service) VALUES
                (1, '+19175551234', 'iMessage'),
                (2, '+15551234567', 'iMessage');

            INSERT INTO chat (ROWID, guid, display_name, service_name) VALUES
                (1, 'iMessage;+;chat1', NULL, 'iMessage'),
                (2, 'iMessage;+;chat2', NULL, 'iMessage');

            INSERT INTO chat_handle_join (chat_id, handle_id) VALUES
                (1, 1),
                (2, 2);

            -- Messages for recency
            INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, associated_message_type) VALUES
                (1, 'msg1', 'Hello', 1, 789100000000000000, 0, 0),
                (2, 'msg2', 'Hi', 2, 789000000000000000, 0, 0);

            INSERT INTO chat_message_join (chat_id, message_id) VALUES
                (1, 1),
                (2, 2);
        """)
        conn.close()
        return mock_db_path

    @patch('imessage_max.tools.send.ContactResolver')
    def test_ambiguous_recipient_returns_candidates(self, mock_resolver_class, ambiguous_db):
        """Test that ambiguous name returns candidate list."""
        # Mock contact resolver to return multiple matches for "Nick"
        mock_resolver = MagicMock()
        mock_resolver.is_available = True
        mock_resolver.search_by_name.return_value = [
            ('+19175551234', 'Nick Gallo'),
            ('+15551234567', 'Nick DePalma'),
        ]
        mock_resolver.resolve.side_effect = lambda h: {
            '+19175551234': 'Nick Gallo',
            '+15551234567': 'Nick DePalma',
        }.get(h)
        mock_resolver_class.return_value = mock_resolver

        result = send_impl(
            to='Nick',
            text='Hello!',
            db_path=str(ambiguous_db)
        )

        assert 'error' in result
        assert result['error'] == 'ambiguous_recipient'
        assert 'candidates' in result
        assert len(result['candidates']) == 2

    @patch('imessage_max.tools.send.ContactResolver')
    def test_ambiguous_candidates_have_required_fields(self, mock_resolver_class, ambiguous_db):
        """Test that ambiguous candidates include required fields."""
        mock_resolver = MagicMock()
        mock_resolver.is_available = True
        mock_resolver.search_by_name.return_value = [
            ('+19175551234', 'Nick Gallo'),
            ('+15551234567', 'Nick DePalma'),
        ]
        mock_resolver.resolve.side_effect = lambda h: {
            '+19175551234': 'Nick Gallo',
            '+15551234567': 'Nick DePalma',
        }.get(h)
        mock_resolver_class.return_value = mock_resolver

        result = send_impl(
            to='Nick',
            text='Hello!',
            db_path=str(ambiguous_db)
        )

        assert result['error'] == 'ambiguous_recipient'
        for candidate in result['candidates']:
            assert 'name' in candidate
            assert 'handle' in candidate
            assert 'last_contact' in candidate

    @pytest.fixture
    def ambiguous_db_with_different_times(self, mock_db_path):
        """Create database with multiple contacts and distinct message times."""
        conn = sqlite3.connect(mock_db_path)
        conn.executescript("""
            INSERT INTO handle (ROWID, id, service) VALUES
                (1, '+19175551234', 'iMessage'),
                (2, '+15551234567', 'iMessage'),
                (3, '+12125559999', 'iMessage');

            INSERT INTO chat (ROWID, guid, display_name, service_name) VALUES
                (1, 'iMessage;+;chat1', NULL, 'iMessage'),
                (2, 'iMessage;+;chat2', NULL, 'iMessage'),
                (3, 'iMessage;+;chat3', NULL, 'iMessage');

            INSERT INTO chat_handle_join (chat_id, handle_id) VALUES
                (1, 1),
                (2, 2),
                (3, 3);

            -- Messages with different dates (oldest to newest: handle 2, handle 3, handle 1)
            -- handle 2: oldest message
            INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, associated_message_type) VALUES
                (1, 'msg1', 'Oldest', 2, 789000000000000000, 0, 0),
                (2, 'msg2', 'Middle', 3, 789050000000000000, 0, 0),
                (3, 'msg3', 'Newest', 1, 789100000000000000, 0, 0);

            INSERT INTO chat_message_join (chat_id, message_id) VALUES
                (2, 1),
                (3, 2),
                (1, 3);
        """)
        conn.close()
        return mock_db_path

    @patch('imessage_max.tools.send.ContactResolver')
    def test_ambiguous_candidates_sorted_by_recent(self, mock_resolver_class, ambiguous_db_with_different_times):
        """Test that candidates are sorted by most recent contact (newest first)."""
        mock_resolver = MagicMock()
        mock_resolver.is_available = True
        # Return matches in non-chronological order to verify sorting
        mock_resolver.search_by_name.return_value = [
            ('+15551234567', 'John Smith'),    # oldest contact
            ('+12125559999', 'John Doe'),      # middle contact
            ('+19175551234', 'John Johnson'),  # newest contact
        ]
        mock_resolver_class.return_value = mock_resolver

        result = send_impl(
            to='John',
            text='Hello!',
            db_path=str(ambiguous_db_with_different_times)
        )

        assert result['error'] == 'ambiguous_recipient'
        candidates = result['candidates']
        assert len(candidates) == 3

        # Verify sorted by most recent first
        assert candidates[0]['handle'] == '+19175551234'  # newest
        assert candidates[1]['handle'] == '+12125559999'  # middle
        assert candidates[2]['handle'] == '+15551234567'  # oldest

        # Verify _sort_ts is not exposed in the response
        for c in candidates:
            assert '_sort_ts' not in c
