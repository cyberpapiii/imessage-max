"""iMessage MCP - Intent-aligned MCP server for iMessage."""

__version__ = "0.1.0"

from .db import (
    get_db_connection,
    apple_to_datetime,
    datetime_to_apple,
    detect_schema_capabilities,
    DB_PATH,
)
from .phone import (
    normalize_to_e164,
    format_phone_display,
    format_phone_international,
    is_phone_number,
    is_email,
)
from .contacts import (
    ContactResolver,
    resolve_handle,
    check_contacts_authorization,
    request_contacts_access,
    PYOBJC_AVAILABLE,
)
from .parsing import (
    get_message_text,
    extract_links,
    is_reaction_message,
    get_reaction_type,
    reaction_to_emoji,
)
from .time_utils import (
    parse_time_input,
    format_relative_time,
    format_compact_relative,
)
from .models import (
    Participant,
    ChatInfo,
    Message,
    generate_display_name,
)

__all__ = [
    # Version
    "__version__",
    # Database
    "get_db_connection",
    "apple_to_datetime",
    "datetime_to_apple",
    "detect_schema_capabilities",
    "DB_PATH",
    # Phone
    "normalize_to_e164",
    "format_phone_display",
    "format_phone_international",
    "is_phone_number",
    "is_email",
    # Contacts
    "ContactResolver",
    "resolve_handle",
    "check_contacts_authorization",
    "request_contacts_access",
    "PYOBJC_AVAILABLE",
    # Parsing
    "get_message_text",
    "extract_links",
    "is_reaction_message",
    "get_reaction_type",
    "reaction_to_emoji",
    # Time
    "parse_time_input",
    "format_relative_time",
    "format_compact_relative",
    # Models
    "Participant",
    "ChatInfo",
    "Message",
    "generate_display_name",
]
