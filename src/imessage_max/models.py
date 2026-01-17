"""Data models for iMessage MCP responses."""

from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional, Any

from .phone import format_phone_display


@dataclass
class Participant:
    """Represents a chat participant."""
    handle: str
    name: Optional[str] = None
    service: str = "iMessage"
    message_count: int = 0
    last_message_time: Optional[datetime] = None

    @property
    def in_contacts(self) -> bool:
        """Whether this participant is in the user's contacts."""
        return self.name is not None

    @property
    def display_name(self) -> str:
        """Human-readable display name."""
        return self.name or format_phone_display(self.handle)

    @property
    def short_name(self) -> str:
        """Short name (first name or formatted phone)."""
        if self.name:
            return self.name.split()[0]
        return format_phone_display(self.handle)

    def to_dict(self, compact: bool = False) -> dict[str, Any]:
        """Convert to dictionary for API response.

        Args:
            compact: If True, return minimal representation

        Returns:
            Dictionary representation
        """
        if compact:
            if self.name:
                return {"name": self.name}
            return {format_phone_display(self.handle): {}}

        result = {
            "handle": self.handle,
            "name": self.name,
        }
        if not self.in_contacts:
            result["handle_formatted"] = format_phone_display(self.handle)
        if self.message_count:
            result["msgs"] = self.message_count
        return result


@dataclass
class ChatInfo:
    """Represents a chat/conversation."""
    chat_id: int
    guid: str
    display_name: Optional[str] = None
    participants: list[Participant] = field(default_factory=list)
    is_group: bool = False
    service: str = "iMessage"
    last_message_time: Optional[datetime] = None
    last_message_preview: Optional[str] = None
    last_message_from: Optional[str] = None
    unread_count: int = 0
    message_count_24h: int = 0
    user_joined_at: Optional[datetime] = None

    @property
    def display_name_resolved(self) -> str:
        """Get display name, generating from participants if not set."""
        if self.display_name:
            return self.display_name
        return generate_display_name(self.participants)

    def to_dict(self, compact: bool = True) -> dict[str, Any]:
        """Convert to dictionary for API response.

        Args:
            compact: If True, return minimal representation

        Returns:
            Dictionary representation
        """
        result = {
            "id": f"chat{self.chat_id}",
            "name": self.display_name_resolved,
        }

        if not compact:
            result["participants"] = [p.to_dict() for p in self.participants]
            if self.is_group:
                result["group"] = True
            if self.last_message_preview:
                result["last"] = {
                    "from": self.last_message_from,
                    "text": self.last_message_preview[:50],
                }

        return result


@dataclass
class Message:
    """Represents a message."""
    message_id: int
    guid: str
    text: Optional[str]
    timestamp: datetime
    from_handle: Optional[str] = None
    from_name: Optional[str] = None
    is_from_me: bool = False
    reactions: list[dict] = field(default_factory=list)
    attachments: list[dict] = field(default_factory=list)
    links: list[str] = field(default_factory=list)
    session_id: Optional[str] = None

    def to_dict(self, people_map: dict[str, str] | None = None) -> dict[str, Any]:
        """Convert to dictionary with optional people reference mapping.

        Args:
            people_map: Optional mapping from handle to short reference (e.g. "p1")

        Returns:
            Dictionary representation
        """
        result: dict[str, Any] = {
            "id": f"msg_{self.message_id}",
            "ts": self.timestamp.isoformat(),
            "text": self.text,
        }

        # Determine "from" field with priority order
        if people_map and self.from_handle and self.from_handle in people_map:
            result["from"] = people_map[self.from_handle]
        elif self.is_from_me:
            result["from"] = "me"
        elif self.from_name:
            result["from"] = self.from_name

        # Only include non-empty collections
        if self.reactions:
            result["reactions"] = self.reactions

        if self.links:
            result["links"] = self.links

        return result


def generate_display_name(participants: list[Participant], max_names: int = 3) -> str:
    """Generate display name like Messages.app does for unnamed chats.

    Args:
        participants: List of chat participants
        max_names: Maximum names to show before truncating

    Returns:
        Generated display name string
    """
    if not participants:
        return "(empty chat)"

    names = []
    for p in participants[:max_names]:
        names.append(p.short_name)

    if len(participants) > max_names:
        remaining = len(participants) - max_names
        return f"{', '.join(names)} and {remaining} others"

    if len(names) == 2:
        return f"{names[0]} & {names[1]}"

    return ', '.join(names)
