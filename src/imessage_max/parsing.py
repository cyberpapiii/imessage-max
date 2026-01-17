"""Message content parsing utilities."""

from typing import Optional
import re


def extract_text_from_attributed_body(blob: bytes) -> Optional[str]:
    """
    Extract plain text from attributedBody blob (typedstream format).

    Since macOS Ventura, message text may be stored in attributedBody
    instead of the text column for styled messages.
    """
    if not blob:
        return None

    marker = b"NSString"
    idx = blob.find(marker)
    if idx == -1:
        marker = b"NSMutableString"
        idx = blob.find(marker)
        if idx == -1:
            return None

    idx += len(marker) + 5

    if idx >= len(blob):
        return None

    if blob[idx] == 0x81:
        if idx + 3 > len(blob):
            return None
        length = int.from_bytes(blob[idx+1:idx+3], 'little')
        idx += 3
    elif blob[idx] == 0x82:
        if idx + 4 > len(blob):
            return None
        length = int.from_bytes(blob[idx+1:idx+4], 'little')
        idx += 4
    else:
        length = blob[idx]
        idx += 1

    if length <= 0 or idx + length > len(blob):
        return None

    try:
        return blob[idx:idx+length].decode('utf-8')
    except UnicodeDecodeError:
        try:
            return blob[idx:idx+length].decode('utf-8', errors='replace')
        except Exception:
            return None


def get_message_text(text: Optional[str], attributed_body: Optional[bytes] = None) -> Optional[str]:
    """Get message text, preferring text column but falling back to attributedBody."""
    if text:
        return text

    if attributed_body:
        return extract_text_from_attributed_body(attributed_body)

    return None


def extract_links(text: Optional[str]) -> list[str]:
    """Extract URLs from message text."""
    if not text:
        return []

    url_pattern = r'https?://[^\s<>"{}|\\^`\[\]]+'
    return re.findall(url_pattern, text)


def is_reaction_message(associated_message_type: Optional[int]) -> bool:
    """Check if a message is a reaction/tapback."""
    if associated_message_type is None:
        return False
    return associated_message_type >= 2000


def get_reaction_type(associated_message_type: int) -> Optional[str]:
    """Get the reaction type name from associated_message_type."""
    reaction_map = {
        2000: 'loved',
        2001: 'liked',
        2002: 'disliked',
        2003: 'laughed',
        2004: 'emphasized',
        2005: 'questioned',
        2006: 'custom_emoji',
        2007: 'custom_emoji',
        3000: 'removed_love',
        3001: 'removed_like',
        3002: 'removed_dislike',
        3003: 'removed_laugh',
        3004: 'removed_emphasis',
        3005: 'removed_question',
        3006: 'removed_custom_emoji',
        3007: 'removed_custom_emoji',
    }
    return reaction_map.get(associated_message_type)


def reaction_to_emoji(reaction_type: str) -> str:
    """Convert reaction type to emoji representation."""
    emoji_map = {
        'loved': '\u2764\ufe0f',
        'liked': '\U0001F44D',
        'disliked': '\U0001F44E',
        'laughed': '\U0001F602',
        'emphasized': '\u203c\ufe0f',
        'questioned': '\u2753',
    }
    return emoji_map.get(reaction_type, '?')
