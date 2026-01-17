"""Time parsing and formatting utilities."""

from datetime import datetime, timezone, timedelta
from typing import Optional
import re

from dateutil import parser as dateutil_parser


def parse_time_input(time_str: str) -> Optional[datetime]:
    """
    Parse flexible time input formats.

    Supports:
    - ISO 8601: "2026-01-16T12:00:00Z"
    - Relative: "24h", "7d", "2w"
    - Natural: "yesterday", "today", "last week"

    Returns datetime in UTC or None if parsing fails.
    """
    if not time_str:
        return None

    time_str = time_str.strip().lower()
    now = datetime.now(timezone.utc)

    # Try relative formats first
    relative_match = re.match(r'^(\d+)(h|d|w|m)$', time_str)
    if relative_match:
        amount = int(relative_match.group(1))
        unit = relative_match.group(2)

        if unit == 'h':
            return now - timedelta(hours=amount)
        elif unit == 'd':
            return now - timedelta(days=amount)
        elif unit == 'w':
            return now - timedelta(weeks=amount)
        elif unit == 'm':
            return now - timedelta(days=amount * 30)

    # Natural language
    if time_str == 'yesterday':
        return now - timedelta(days=1)
    elif time_str == 'today':
        return now.replace(hour=0, minute=0, second=0, microsecond=0)
    elif time_str == 'last week':
        return now - timedelta(weeks=1)
    elif time_str == 'last month':
        return now - timedelta(days=30)

    # Try ISO/standard formats
    try:
        dt = dateutil_parser.parse(time_str)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except (ValueError, TypeError):
        pass

    return None


def format_relative_time(dt: Optional[datetime]) -> str:
    """
    Format datetime as human-readable relative time.

    Examples: "just now", "5 minutes ago", "2 hours ago", "3 days ago"
    """
    if dt is None:
        return ""

    now = datetime.now(timezone.utc)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)

    delta = now - dt
    seconds = delta.total_seconds()

    if seconds < 60:
        return "just now"
    elif seconds < 3600:
        minutes = int(seconds / 60)
        return f"{minutes} minute{'s' if minutes != 1 else ''} ago"
    elif seconds < 86400:
        hours = int(seconds / 3600)
        return f"{hours} hour{'s' if hours != 1 else ''} ago"
    elif seconds < 604800:
        days = int(seconds / 86400)
        return f"{days} day{'s' if days != 1 else ''} ago"
    elif seconds < 2592000:
        weeks = int(seconds / 604800)
        return f"{weeks} week{'s' if weeks != 1 else ''} ago"
    else:
        months = int(seconds / 2592000)
        return f"{months} month{'s' if months != 1 else ''} ago"


def format_compact_relative(dt: Optional[datetime]) -> str:
    """Format datetime as compact relative time (e.g., '2h ago', '3d ago')."""
    if dt is None:
        return ""

    now = datetime.now(timezone.utc)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)

    delta = now - dt
    seconds = delta.total_seconds()

    if seconds < 60:
        return "now"
    elif seconds < 3600:
        return f"{int(seconds / 60)}m ago"
    elif seconds < 86400:
        return f"{int(seconds / 3600)}h ago"
    elif seconds < 604800:
        return f"{int(seconds / 86400)}d ago"
    else:
        return f"{int(seconds / 604800)}w ago"
