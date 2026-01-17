"""Tests for data models."""

import pytest
from datetime import datetime, timezone

from imessage_max.models import (
    Participant,
    ChatInfo,
    Message,
    generate_display_name,
)


class TestParticipant:
    def test_creation(self):
        p = Participant(handle="+15551234567", name="John Doe")
        assert p.handle == "+15551234567"
        assert p.name == "John Doe"
        assert p.in_contacts is True

    def test_unknown_participant(self):
        p = Participant(handle="+15551234567", name=None)
        assert p.in_contacts is False

    def test_display_name_with_name(self):
        p = Participant(handle="+15551234567", name="John Doe")
        assert p.display_name == "John Doe"

    def test_display_name_without_name(self):
        p = Participant(handle="+15551234567", name=None)
        # Should use formatted phone number
        assert "555" in p.display_name

    def test_short_name_with_name(self):
        p = Participant(handle="+15551234567", name="John Doe")
        assert p.short_name == "John"

    def test_short_name_without_name(self):
        p = Participant(handle="+15551234567", name=None)
        # Should use formatted phone number
        assert "555" in p.short_name

    def test_to_dict(self):
        p = Participant(handle="+15551234567", name="John Doe")
        d = p.to_dict()
        assert d["name"] == "John Doe"
        assert d["handle"] == "+15551234567"

    def test_to_dict_unknown_includes_formatted(self):
        p = Participant(handle="+15551234567", name=None)
        d = p.to_dict()
        assert "handle_formatted" in d
        assert "555" in d["handle_formatted"]

    def test_to_dict_with_message_count(self):
        p = Participant(handle="+15551234567", name="John", message_count=42)
        d = p.to_dict()
        assert d["msgs"] == 42

    def test_to_dict_compact_with_name(self):
        p = Participant(handle="+15551234567", name="John Doe")
        d = p.to_dict(compact=True)
        assert d == {"name": "John Doe"}

    def test_to_dict_compact_without_name(self):
        p = Participant(handle="+15551234567", name=None)
        d = p.to_dict(compact=True)
        # Should be formatted phone as key
        assert len(d) == 1
        key = list(d.keys())[0]
        assert "555" in key


class TestGenerateDisplayName:
    def test_two_known_participants(self):
        participants = [
            Participant(handle="+1111", name="John Doe"),
            Participant(handle="+2222", name="Jane Smith"),
        ]
        result = generate_display_name(participants)
        assert "John" in result
        assert "Jane" in result
        assert "&" in result  # Two participants use "&"

    def test_three_known_participants(self):
        participants = [
            Participant(handle="+1111", name="John Doe"),
            Participant(handle="+2222", name="Jane Smith"),
            Participant(handle="+3333", name="Bob Wilson"),
        ]
        result = generate_display_name(participants)
        assert "John" in result
        assert "Jane" in result
        assert "Bob" in result
        assert "," in result

    def test_unknown_participant(self):
        participants = [
            Participant(handle="+15551234567", name=None),
        ]
        result = generate_display_name(participants)
        assert "555" in result  # Formatted phone number

    def test_mixed_known_and_unknown(self):
        participants = [
            Participant(handle="+1111", name="John Doe"),
            Participant(handle="+15559876543", name=None),
        ]
        result = generate_display_name(participants)
        assert "John" in result
        assert "555" in result

    def test_many_participants_truncated(self):
        participants = [
            Participant(handle=f"+{i}", name=f"Person {i}")
            for i in range(5)
        ]
        result = generate_display_name(participants, max_names=3)
        assert "others" in result
        assert "2 others" in result

    def test_empty_participants(self):
        result = generate_display_name([])
        assert "empty" in result.lower()


class TestChatInfo:
    def test_basic_creation(self):
        chat = ChatInfo(chat_id=1, guid="chat123")
        assert chat.chat_id == 1
        assert chat.guid == "chat123"
        assert chat.is_group is False

    def test_display_name_resolved_with_explicit_name(self):
        chat = ChatInfo(chat_id=1, guid="chat123", display_name="My Group")
        assert chat.display_name_resolved == "My Group"

    def test_display_name_resolved_from_participants(self):
        participants = [
            Participant(handle="+1111", name="John Doe"),
            Participant(handle="+2222", name="Jane Smith"),
        ]
        chat = ChatInfo(chat_id=1, guid="chat123", participants=participants)
        result = chat.display_name_resolved
        assert "John" in result
        assert "Jane" in result

    def test_to_dict_compact(self):
        chat = ChatInfo(
            chat_id=1,
            guid="chat123",
            display_name="Test Chat",
        )
        d = chat.to_dict(compact=True)
        assert d["id"] == "chat1"
        assert d["name"] == "Test Chat"
        assert "participants" not in d

    def test_to_dict_full(self):
        participants = [
            Participant(handle="+1111", name="John Doe"),
        ]
        chat = ChatInfo(
            chat_id=1,
            guid="chat123",
            display_name="Test Chat",
            participants=participants,
            is_group=True,
            last_message_preview="Hello world",
            last_message_from="John",
        )
        d = chat.to_dict(compact=False)
        assert d["id"] == "chat1"
        assert d["name"] == "Test Chat"
        assert "participants" in d
        assert d["group"] is True
        assert "last" in d
        assert d["last"]["from"] == "John"


class TestMessage:
    def test_basic_creation(self):
        ts = datetime(2026, 1, 16, 12, 0, 0, tzinfo=timezone.utc)
        msg = Message(
            message_id=1,
            guid="msg123",
            text="Hello world",
            timestamp=ts,
        )
        assert msg.message_id == 1
        assert msg.text == "Hello world"
        assert msg.is_from_me is False

    def test_to_dict_basic(self):
        ts = datetime(2026, 1, 16, 12, 0, 0, tzinfo=timezone.utc)
        msg = Message(
            message_id=1,
            guid="msg123",
            text="Hello world",
            timestamp=ts,
            is_from_me=True,
        )
        d = msg.to_dict()
        assert d["id"] == "msg_1"
        assert d["text"] == "Hello world"
        assert d["from"] == "me"
        assert "ts" in d

    def test_to_dict_with_from_name(self):
        ts = datetime(2026, 1, 16, 12, 0, 0, tzinfo=timezone.utc)
        msg = Message(
            message_id=1,
            guid="msg123",
            text="Hello",
            timestamp=ts,
            from_name="John",
        )
        d = msg.to_dict()
        assert d["from"] == "John"

    def test_to_dict_with_people_map(self):
        ts = datetime(2026, 1, 16, 12, 0, 0, tzinfo=timezone.utc)
        msg = Message(
            message_id=1,
            guid="msg123",
            text="Hello",
            timestamp=ts,
            from_handle="+15551234567",
        )
        people_map = {"+15551234567": "p1"}
        d = msg.to_dict(people_map=people_map)
        assert d["from"] == "p1"

    def test_to_dict_with_reactions(self):
        ts = datetime(2026, 1, 16, 12, 0, 0, tzinfo=timezone.utc)
        msg = Message(
            message_id=1,
            guid="msg123",
            text="Hello",
            timestamp=ts,
            reactions=[{"type": "loved", "from": "John"}],
        )
        d = msg.to_dict()
        assert "reactions" in d
        assert len(d["reactions"]) == 1

    def test_to_dict_with_links(self):
        ts = datetime(2026, 1, 16, 12, 0, 0, tzinfo=timezone.utc)
        msg = Message(
            message_id=1,
            guid="msg123",
            text="Check this out",
            timestamp=ts,
            links=["https://example.com"],
        )
        d = msg.to_dict()
        assert "links" in d
        assert d["links"] == ["https://example.com"]

    def test_to_dict_omits_empty_reactions(self):
        ts = datetime(2026, 1, 16, 12, 0, 0, tzinfo=timezone.utc)
        msg = Message(
            message_id=1,
            guid="msg123",
            text="Hello",
            timestamp=ts,
        )
        d = msg.to_dict()
        assert "reactions" not in d

    def test_to_dict_omits_empty_links(self):
        ts = datetime(2026, 1, 16, 12, 0, 0, tzinfo=timezone.utc)
        msg = Message(
            message_id=1,
            guid="msg123",
            text="Hello",
            timestamp=ts,
        )
        d = msg.to_dict()
        assert "links" not in d
