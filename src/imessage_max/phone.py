"""Phone number normalization utilities."""

try:
    import phonenumbers
    from phonenumbers import PhoneNumberFormat
    PHONENUMBERS_AVAILABLE = True
except ImportError:
    PHONENUMBERS_AVAILABLE = False


def normalize_to_e164(raw_number: str, region: str = "US") -> str | None:
    """
    Normalize phone number to E.164 format for handle matching.

    Args:
        raw_number: Phone number in any format
        region: Default region for parsing (ISO 3166-1 alpha-2)

    Returns:
        E.164 formatted number or None if invalid
    """
    if not PHONENUMBERS_AVAILABLE:
        # Fallback: basic normalization
        cleaned = ''.join(c for c in raw_number if c.isdigit() or c == '+')
        if cleaned.startswith('+'):
            return cleaned
        if len(cleaned) == 10:
            return f"+1{cleaned}"
        if len(cleaned) == 11 and cleaned.startswith('1'):
            return f"+{cleaned}"
        return None

    try:
        parsed = phonenumbers.parse(raw_number, region)
        if phonenumbers.is_valid_number(parsed):
            return phonenumbers.format_number(parsed, PhoneNumberFormat.E164)
    except phonenumbers.NumberParseException:
        pass
    return None


def format_phone_display(e164: str) -> str:
    """Format E.164 number for human-readable display."""
    if not PHONENUMBERS_AVAILABLE:
        if e164.startswith('+1') and len(e164) == 12:
            return f"({e164[2:5]}) {e164[5:8]}-{e164[8:]}"
        return e164

    try:
        parsed = phonenumbers.parse(e164)
        return phonenumbers.format_number(parsed, PhoneNumberFormat.NATIONAL)
    except Exception:
        return e164


def format_phone_international(e164: str) -> str:
    """Format E.164 number for international display."""
    if not PHONENUMBERS_AVAILABLE:
        if e164.startswith('+1') and len(e164) == 12:
            return f"+1 ({e164[2:5]}) {e164[5:8]}-{e164[8:]}"
        return e164

    try:
        parsed = phonenumbers.parse(e164)
        return phonenumbers.format_number(parsed, PhoneNumberFormat.INTERNATIONAL)
    except Exception:
        return e164


def is_phone_number(text: str) -> bool:
    """Check if text looks like a phone number."""
    cleaned = ''.join(c for c in text if c.isdigit())
    return 7 <= len(cleaned) <= 15


def is_email(text: str) -> bool:
    """Check if text looks like an email address."""
    return '@' in text and '.' in text.split('@')[-1]
