"""
Message content parsing utilities.

Handles extraction of text from attributedBody blob (typedstream format)
used in macOS Ventura and later for styled messages.
"""

from typing import Optional


def extract_text_from_attributed_body(blob: bytes) -> Optional[str]:
    """
    Extract plain text from attributedBody blob.

    Since macOS Ventura, message text may be stored in attributedBody
    (a typedstream blob) instead of the text column. This is especially
    true for messages with styling, mentions, or rich formatting.

    Args:
        blob: Raw bytes from attributedBody column

    Returns:
        Extracted plain text or None if parsing fails
    """
    if not blob:
        return None

    # Find NSString marker in typedstream
    marker = b"NSString"
    idx = blob.find(marker)
    if idx == -1:
        # Try alternative marker
        marker = b"NSMutableString"
        idx = blob.find(marker)
        if idx == -1:
            return None

    # Skip past marker and type info bytes
    idx += len(marker) + 5

    if idx >= len(blob):
        return None

    # Read string length - can be single byte or multi-byte encoded
    if blob[idx] == 0x81:
        # Multi-byte length encoding (for strings > 127 chars)
        if idx + 3 > len(blob):
            return None
        length = int.from_bytes(blob[idx+1:idx+3], 'little')
        idx += 3
    elif blob[idx] == 0x82:
        # 3-byte length encoding (for very long strings)
        if idx + 4 > len(blob):
            return None
        length = int.from_bytes(blob[idx+1:idx+4], 'little')
        idx += 4
    else:
        # Single-byte length
        length = blob[idx]
        idx += 1

    # Sanity check length
    if length <= 0 or idx + length > len(blob):
        return None

    # Extract string content
    try:
        return blob[idx:idx+length].decode('utf-8')
    except UnicodeDecodeError:
        # Try with error handling
        try:
            return blob[idx:idx+length].decode('utf-8', errors='replace')
        except:
            return None


def get_message_text(text: Optional[str], attributed_body: Optional[bytes]) -> Optional[str]:
    """
    Get message text, preferring text column but falling back to attributedBody.

    Args:
        text: Value from message.text column
        attributed_body: Value from message.attributedBody column

    Returns:
        Message text content or None
    """
    # Prefer the text column if available
    if text:
        return text

    # Fall back to parsing attributedBody
    if attributed_body:
        return extract_text_from_attributed_body(attributed_body)

    return None


def extract_links(text: str) -> list[str]:
    """
    Extract URLs from message text.

    Args:
        text: Message text content

    Returns:
        List of URLs found in the text
    """
    import re
    if not text:
        return []

    # Simple URL regex - matches http/https URLs
    url_pattern = r'https?://[^\s<>"{}|\\^`\[\]]+'
    return re.findall(url_pattern, text)


def is_reaction_message(associated_message_type: int) -> bool:
    """
    Check if a message is a reaction/tapback.

    Args:
        associated_message_type: Value from message.associated_message_type

    Returns:
        True if this is a reaction, False if regular message
    """
    if associated_message_type is None:
        return False
    return associated_message_type >= 2000


def get_reaction_type(associated_message_type: int) -> Optional[str]:
    """
    Get the reaction type name from associated_message_type.

    Args:
        associated_message_type: Value from message.associated_message_type

    Returns:
        Reaction type name or None
    """
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
        'loved': '\u2764\ufe0f',      # ❤️
        'liked': '\U0001F44D',         # 👍
        'disliked': '\U0001F44E',      # 👎
        'laughed': '\U0001F602',       # 😂
        'emphasized': '\u203c\ufe0f',  # ‼️
        'questioned': '\u2753',        # ❓
    }
    return emoji_map.get(reaction_type, '?')
