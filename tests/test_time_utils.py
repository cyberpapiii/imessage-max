"""Tests for time parsing utilities."""

import pytest
from datetime import datetime, timezone, timedelta
from imessage_max.time_utils import (
    parse_time_input,
    format_relative_time,
    format_compact_relative,
)


class TestParseTimeInput:
    def test_iso_format(self):
        result = parse_time_input("2026-01-16T12:00:00Z")
        assert result.year == 2026
        assert result.month == 1
        assert result.day == 16

    def test_relative_hours(self):
        result = parse_time_input("24h")
        now = datetime.now(timezone.utc)
        delta = now - result
        assert 23 < delta.total_seconds() / 3600 < 25

    def test_relative_days(self):
        result = parse_time_input("7d")
        now = datetime.now(timezone.utc)
        delta = now - result
        assert 6 < delta.days < 8

    def test_natural_yesterday(self):
        result = parse_time_input("yesterday")
        now = datetime.now(timezone.utc)
        delta = now - result
        assert 0 < delta.days <= 2

    def test_natural_today(self):
        result = parse_time_input("today")
        now = datetime.now(timezone.utc)
        assert result.date() == now.date()

    def test_invalid_returns_none(self):
        assert parse_time_input("invalid") is None
        assert parse_time_input("") is None


class TestFormatRelativeTime:
    def test_just_now(self):
        dt = datetime.now(timezone.utc)
        result = format_relative_time(dt)
        assert "just now" in result or "seconds" in result or "minute" in result

    def test_hours_ago(self):
        dt = datetime.now(timezone.utc) - timedelta(hours=5)
        result = format_relative_time(dt)
        assert "hours ago" in result or "5h ago" in result

    def test_days_ago(self):
        dt = datetime.now(timezone.utc) - timedelta(days=3)
        result = format_relative_time(dt)
        assert "days ago" in result or "3d ago" in result

    def test_none_returns_empty(self):
        assert format_relative_time(None) == ""


class TestFormatCompactRelative:
    def test_now(self):
        dt = datetime.now(timezone.utc)
        result = format_compact_relative(dt)
        assert result == "now"

    def test_minutes_ago(self):
        dt = datetime.now(timezone.utc) - timedelta(minutes=15)
        result = format_compact_relative(dt)
        assert result == "15m ago"

    def test_hours_ago(self):
        dt = datetime.now(timezone.utc) - timedelta(hours=5)
        result = format_compact_relative(dt)
        assert result == "5h ago"

    def test_days_ago(self):
        dt = datetime.now(timezone.utc) - timedelta(days=3)
        result = format_compact_relative(dt)
        assert result == "3d ago"

    def test_weeks_ago(self):
        dt = datetime.now(timezone.utc) - timedelta(weeks=2)
        result = format_compact_relative(dt)
        assert result == "2w ago"

    def test_none_returns_empty(self):
        assert format_compact_relative(None) == ""
