"""Tests for version checking functionality."""

import json
import pytest
from unittest.mock import patch, MagicMock
from pathlib import Path

from imessage_max.version_check import (
    _parse_version,
    _is_newer,
    check_for_update,
    get_update_notice_once,
    reset_session_notice,
    get_current_version,
    CURRENT_VERSION,
)


class TestVersionParsing:
    """Tests for version parsing and comparison."""

    def test_parse_version_standard(self):
        """Test parsing standard version string."""
        assert _parse_version("1.2.3") == (1, 2, 3)

    def test_parse_version_two_parts(self):
        """Test parsing version with two parts."""
        assert _parse_version("1.2") == (1, 2)

    def test_parse_version_single(self):
        """Test parsing single version number."""
        assert _parse_version("1") == (1,)

    def test_parse_version_invalid(self):
        """Test parsing invalid version returns fallback."""
        assert _parse_version("invalid") == (0, 0, 0)
        assert _parse_version(None) == (0, 0, 0)

    def test_is_newer_major(self):
        """Test major version comparison."""
        assert _is_newer("2.0.0", "1.0.0") is True
        assert _is_newer("1.0.0", "2.0.0") is False

    def test_is_newer_minor(self):
        """Test minor version comparison."""
        assert _is_newer("1.2.0", "1.1.0") is True
        assert _is_newer("1.1.0", "1.2.0") is False

    def test_is_newer_patch(self):
        """Test patch version comparison."""
        assert _is_newer("1.0.2", "1.0.1") is True
        assert _is_newer("1.0.1", "1.0.2") is False

    def test_is_newer_equal(self):
        """Test equal versions."""
        assert _is_newer("1.0.0", "1.0.0") is False


class TestCheckForUpdate:
    """Tests for check_for_update function."""

    @patch('imessage_max.version_check._read_cache')
    @patch('imessage_max.version_check._fetch_latest_version')
    @patch('imessage_max.version_check._write_cache')
    def test_check_for_update_with_update_available(self, mock_write, mock_fetch, mock_read):
        """Test check_for_update when update is available."""
        mock_read.return_value = None  # No cache
        mock_fetch.return_value = "99.0.0"  # Much newer version

        result = check_for_update()

        assert result is not None
        assert result["available"] is True
        assert result["latest_version"] == "99.0.0"
        assert result["current_version"] == CURRENT_VERSION
        assert "update_command" in result
        mock_write.assert_called_once_with("99.0.0")

    @patch('imessage_max.version_check._read_cache')
    @patch('imessage_max.version_check._fetch_latest_version')
    def test_check_for_update_already_latest(self, mock_fetch, mock_read):
        """Test check_for_update when already on latest."""
        mock_read.return_value = None
        mock_fetch.return_value = "0.0.1"  # Older version

        result = check_for_update()

        assert result is None

    @patch('imessage_max.version_check._read_cache')
    def test_check_for_update_uses_cache(self, mock_read):
        """Test check_for_update uses cached data."""
        mock_read.return_value = {"latest_version": "99.0.0", "timestamp": 9999999999}

        result = check_for_update()

        assert result is not None
        assert result["latest_version"] == "99.0.0"

    @patch('imessage_max.version_check._read_cache')
    @patch('imessage_max.version_check._fetch_latest_version')
    def test_check_for_update_fetch_fails(self, mock_fetch, mock_read):
        """Test check_for_update handles fetch failure."""
        mock_read.return_value = None
        mock_fetch.return_value = None

        result = check_for_update()

        assert result is None


class TestSessionNotification:
    """Tests for once-per-session notification."""

    def setup_method(self):
        """Reset session notification before each test."""
        reset_session_notice()

    @patch('imessage_max.version_check.check_for_update')
    def test_get_update_notice_once_first_call(self, mock_check):
        """Test first call returns notice."""
        mock_check.return_value = {"available": True, "latest_version": "99.0.0"}

        result = get_update_notice_once()

        assert result is not None
        assert result["latest_version"] == "99.0.0"

    @patch('imessage_max.version_check.check_for_update')
    def test_get_update_notice_once_second_call(self, mock_check):
        """Test second call returns None."""
        mock_check.return_value = {"available": True, "latest_version": "99.0.0"}

        first = get_update_notice_once()
        second = get_update_notice_once()

        assert first is not None
        assert second is None

    @patch('imessage_max.version_check.check_for_update')
    def test_get_update_notice_once_no_update(self, mock_check):
        """Test returns None when no update available."""
        mock_check.return_value = None

        result = get_update_notice_once()

        assert result is None

    def test_reset_session_notice(self):
        """Test reset_session_notice clears the flag."""
        with patch('imessage_max.version_check.check_for_update') as mock_check:
            mock_check.return_value = {"available": True, "latest_version": "99.0.0"}

            first = get_update_notice_once()
            reset_session_notice()
            second = get_update_notice_once()

            assert first is not None
            assert second is not None


class TestGetCurrentVersion:
    """Tests for get_current_version function."""

    def test_get_current_version(self):
        """Test get_current_version returns CURRENT_VERSION."""
        assert get_current_version() == CURRENT_VERSION

    def test_current_version_format(self):
        """Test version has valid format."""
        version = get_current_version()
        parts = version.split(".")
        assert len(parts) >= 2
        for part in parts:
            assert part.isdigit()
