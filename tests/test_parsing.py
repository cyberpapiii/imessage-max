"""Tests for message parsing utilities."""

import pytest
from imessage_max.parsing import (
    extract_text_from_attributed_body,
    get_message_text,
    extract_links,
    is_reaction_message,
    get_reaction_type,
    reaction_to_emoji,
)


class TestGetMessageText:
    def test_prefers_text_column(self):
        assert get_message_text("Hello", None) == "Hello"
        assert get_message_text("Hello", b"blob") == "Hello"

    def test_returns_none_for_empty(self):
        assert get_message_text(None, None) is None
        assert get_message_text("", None) is None


class TestExtractLinks:
    def test_extracts_https(self):
        text = "Check out https://example.com/page"
        links = extract_links(text)
        assert "https://example.com/page" in links

    def test_extracts_http(self):
        text = "See http://test.org"
        links = extract_links(text)
        assert "http://test.org" in links

    def test_multiple_links(self):
        text = "Visit https://a.com and https://b.com"
        links = extract_links(text)
        assert len(links) == 2

    def test_no_links(self):
        assert extract_links("No links here") == []

    def test_empty_text(self):
        assert extract_links("") == []
        assert extract_links(None) == []


class TestReactions:
    def test_is_reaction_message(self):
        assert is_reaction_message(0) is False
        assert is_reaction_message(2000) is True
        assert is_reaction_message(2005) is True
        assert is_reaction_message(3000) is True
        assert is_reaction_message(None) is False

    def test_get_reaction_type(self):
        assert get_reaction_type(2000) == "loved"
        assert get_reaction_type(2001) == "liked"
        assert get_reaction_type(2002) == "disliked"
        assert get_reaction_type(2003) == "laughed"
        assert get_reaction_type(2004) == "emphasized"
        assert get_reaction_type(2005) == "questioned"
        assert get_reaction_type(3000) == "removed_love"
        assert get_reaction_type(0) is None

    def test_reaction_to_emoji(self):
        assert reaction_to_emoji("loved") == "❤️"
        assert reaction_to_emoji("liked") == "👍"
        assert reaction_to_emoji("laughed") == "😂"
        assert reaction_to_emoji("unknown") == "?"
