# iMessage MCP Pro Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a production-ready MCP server for iMessage that reduces tool calls per user intent from 3-5 to 1-2 through intent-aligned tools.

**Architecture:** FastMCP Python server with read-only SQLite access to chat.db, CNContactStore integration for contact resolution, and AppleScript backend for sending. All tools return token-efficient JSON with resolved contact names and smart disambiguation.

**Tech Stack:** Python 3.10+, FastMCP <3, PyObjC (pyobjc-framework-Contacts >=12.1), phonenumbers >=8.13, python-dateutil >=2.8, pytest

---

## Phase 1: Core Infrastructure

### Task 1.1: Initialize Python Package Structure

**Files:**
- Create: `pyproject.toml`
- Create: `src/imessage_mcp/__init__.py`
- Create: `src/imessage_mcp/server.py`
- Create: `tests/__init__.py`
- Create: `tests/conftest.py`

**Step 1: Create pyproject.toml**

```toml
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "imessage-mcp"
version = "0.1.0"
description = "Intent-aligned MCP server for iMessage"
readme = "README.md"
requires-python = ">=3.10"
license = "MIT"
authors = [
    { name = "Rob Dezendorf" }
]
dependencies = [
    "fastmcp>=0.4,<3",
    "pyobjc-framework-Contacts>=12.1",
    "phonenumbers>=8.13",
    "python-dateutil>=2.8",
]

[project.optional-dependencies]
dev = [
    "pytest>=7.0",
    "pytest-asyncio>=0.21",
]

[project.scripts]
imessage-mcp = "imessage_mcp.server:main"

[tool.hatch.build.targets.wheel]
packages = ["src/imessage_mcp"]

[tool.pytest.ini_options]
asyncio_mode = "auto"
testpaths = ["tests"]
```

**Step 2: Create package init**

Create `src/imessage_mcp/__init__.py`:
```python
"""iMessage MCP - Intent-aligned MCP server for iMessage."""

__version__ = "0.1.0"
```

**Step 3: Create minimal server**

Create `src/imessage_mcp/server.py`:
```python
"""iMessage MCP Server."""

from fastmcp import FastMCP

mcp = FastMCP("iMessage MCP")


def main():
    """Run the MCP server."""
    mcp.run()


if __name__ == "__main__":
    main()
```

**Step 4: Create test conftest**

Create `tests/__init__.py` (empty file).

Create `tests/conftest.py`:
```python
"""Pytest configuration and fixtures."""

import pytest
import sqlite3
import tempfile
import os
from pathlib import Path


@pytest.fixture
def mock_db_path(tmp_path):
    """Create a temporary mock chat.db for testing."""
    db_path = tmp_path / "chat.db"
    conn = sqlite3.connect(db_path)

    # Create minimal schema
    conn.executescript("""
        CREATE TABLE handle (
            ROWID INTEGER PRIMARY KEY,
            id TEXT UNIQUE,
            service TEXT
        );

        CREATE TABLE chat (
            ROWID INTEGER PRIMARY KEY,
            guid TEXT UNIQUE,
            display_name TEXT,
            service_name TEXT
        );

        CREATE TABLE message (
            ROWID INTEGER PRIMARY KEY,
            guid TEXT UNIQUE,
            text TEXT,
            attributedBody BLOB,
            handle_id INTEGER,
            date INTEGER,
            date_read INTEGER,
            is_from_me INTEGER,
            associated_message_type INTEGER DEFAULT 0,
            associated_message_guid TEXT,
            cache_has_attachments INTEGER DEFAULT 0,
            FOREIGN KEY (handle_id) REFERENCES handle(ROWID)
        );

        CREATE TABLE chat_handle_join (
            chat_id INTEGER,
            handle_id INTEGER,
            PRIMARY KEY (chat_id, handle_id)
        );

        CREATE TABLE chat_message_join (
            chat_id INTEGER,
            message_id INTEGER,
            PRIMARY KEY (chat_id, message_id)
        );

        CREATE TABLE attachment (
            ROWID INTEGER PRIMARY KEY,
            guid TEXT UNIQUE,
            filename TEXT,
            mime_type TEXT,
            total_bytes INTEGER,
            transfer_name TEXT
        );

        CREATE TABLE message_attachment_join (
            message_id INTEGER,
            attachment_id INTEGER,
            PRIMARY KEY (message_id, attachment_id)
        );
    """)
    conn.close()

    return db_path


@pytest.fixture
def populated_db(mock_db_path):
    """Create a mock database with sample data."""
    conn = sqlite3.connect(mock_db_path)

    # Insert sample handles
    conn.executescript("""
        INSERT INTO handle (ROWID, id, service) VALUES
            (1, '+19175551234', 'iMessage'),
            (2, '+15625559876', 'iMessage'),
            (3, 'test@example.com', 'iMessage');

        INSERT INTO chat (ROWID, guid, display_name, service_name) VALUES
            (1, 'iMessage;+;chat123', NULL, 'iMessage'),
            (2, 'iMessage;+;chat456', 'Test Group', 'iMessage');

        INSERT INTO chat_handle_join (chat_id, handle_id) VALUES
            (1, 1),
            (2, 1),
            (2, 2);

        -- Messages: Apple epoch nanoseconds (2026-01-16 = ~789100000000000000)
        INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, associated_message_type) VALUES
            (1, 'msg1', 'Hello world', 1, 789100000000000000, 0, 0),
            (2, 'msg2', 'How are you?', NULL, 789100100000000000, 1, 0),
            (3, 'msg3', NULL, 1, 789100200000000000, 0, 2000);

        INSERT INTO chat_message_join (chat_id, message_id) VALUES
            (1, 1),
            (1, 2),
            (1, 3);
    """)
    conn.close()

    return mock_db_path
```

**Step 5: Verify structure**

Run: `ls -la src/imessage_mcp/ tests/`
Expected: Shows `__init__.py`, `server.py` in src and `conftest.py` in tests

**Step 6: Install in dev mode**

Run: `cd /Users/robdezendorf/Documents/GitHub/imessage-mcp-pro && pip install -e ".[dev]"`
Expected: Successfully installed imessage-mcp

**Step 7: Commit**

```bash
git add pyproject.toml src/ tests/
git commit -m "feat: initialize Python package structure with FastMCP"
```

---

### Task 1.2: Database Connection Module

**Files:**
- Create: `src/imessage_mcp/db.py`
- Create: `tests/test_db.py`

**Step 1: Write failing test for connection manager**

Create `tests/test_db.py`:
```python
"""Tests for database connection management."""

import pytest
import sqlite3
from imessage_mcp.db import get_db_connection, DB_PATH


def test_get_db_connection_with_mock(mock_db_path):
    """Test connection manager with mock database."""
    with get_db_connection(mock_db_path) as conn:
        assert conn is not None
        # Verify read-only mode
        cursor = conn.execute("SELECT 1")
        assert cursor.fetchone()[0] == 1


def test_connection_closes_after_context(mock_db_path):
    """Test that connection is closed after context exit."""
    with get_db_connection(mock_db_path) as conn:
        pass
    # Connection should be closed - this should raise
    with pytest.raises(sqlite3.ProgrammingError):
        conn.execute("SELECT 1")


def test_get_db_connection_nonexistent():
    """Test error handling for missing database."""
    with pytest.raises(FileNotFoundError):
        with get_db_connection("/nonexistent/path/chat.db") as conn:
            pass
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/robdezendorf/Documents/GitHub/imessage-mcp-pro && pytest tests/test_db.py -v`
Expected: FAIL with "ModuleNotFoundError: No module named 'imessage_mcp.db'"

**Step 3: Implement database module**

Create `src/imessage_mcp/db.py`:
```python
"""Database connection utilities for iMessage chat.db."""

import sqlite3
import os
from contextlib import contextmanager
from datetime import datetime, timezone, timedelta
from typing import Generator

# Default database path
DB_PATH = os.path.expanduser("~/Library/Messages/chat.db")

# Apple epoch (2001-01-01 00:00:00 UTC)
APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)


def apple_to_datetime(apple_timestamp: int | None) -> datetime | None:
    """Convert Apple epoch nanoseconds to Python datetime."""
    if apple_timestamp is None:
        return None
    seconds = apple_timestamp / 1_000_000_000
    return APPLE_EPOCH + timedelta(seconds=seconds)


def datetime_to_apple(dt: datetime) -> int:
    """Convert Python datetime to Apple epoch nanoseconds."""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    delta = dt - APPLE_EPOCH
    return int(delta.total_seconds() * 1_000_000_000)


@contextmanager
def get_db_connection(db_path: str = DB_PATH) -> Generator[sqlite3.Connection, None, None]:
    """
    Open database connection in read-only mode with safe settings.

    Connection is closed immediately after use to prevent
    macOS Tahoe from terminating Messages.app.
    """
    if not os.path.exists(db_path):
        raise FileNotFoundError(f"Database not found: {db_path}")

    conn = sqlite3.connect(
        f"file:{db_path}?mode=ro",
        uri=True,
        timeout=5.0
    )
    conn.row_factory = sqlite3.Row

    conn.execute("PRAGMA query_only = ON")
    conn.execute("PRAGMA busy_timeout = 1000")

    try:
        yield conn
    finally:
        conn.close()


def detect_schema_capabilities(conn: sqlite3.Connection) -> dict:
    """Detect which columns/features are available in this database."""
    capabilities = {
        'has_date_edited': False,
        'has_date_retracted': False,
        'has_thread_originator': False,
        'has_associated_emoji': False,
        'has_schedule_fields': False,
    }

    cursor = conn.execute("PRAGMA table_info(message)")
    columns = {row['name'] for row in cursor.fetchall()}

    capabilities['has_date_edited'] = 'date_edited' in columns
    capabilities['has_date_retracted'] = 'date_retracted' in columns
    capabilities['has_thread_originator'] = 'thread_originator_guid' in columns
    capabilities['has_associated_emoji'] = 'associated_message_emoji' in columns
    capabilities['has_schedule_fields'] = 'schedule_type' in columns

    return capabilities
```

**Step 4: Run test to verify it passes**

Run: `pytest tests/test_db.py -v`
Expected: 3 passed

**Step 5: Add timestamp conversion tests**

Add to `tests/test_db.py`:
```python
from imessage_mcp.db import apple_to_datetime, datetime_to_apple, APPLE_EPOCH
from datetime import datetime, timezone


def test_apple_to_datetime():
    """Test Apple epoch to datetime conversion."""
    # 2026-01-16 00:00:00 UTC is ~789091200 seconds after 2001-01-01
    apple_ts = 789091200 * 1_000_000_000
    dt = apple_to_datetime(apple_ts)
    assert dt.year == 2026
    assert dt.month == 1
    assert dt.day == 16


def test_datetime_to_apple():
    """Test datetime to Apple epoch conversion."""
    dt = datetime(2026, 1, 16, 0, 0, 0, tzinfo=timezone.utc)
    apple_ts = datetime_to_apple(dt)
    # Convert back to verify
    result = apple_to_datetime(apple_ts)
    assert result == dt


def test_apple_to_datetime_none():
    """Test handling of None timestamp."""
    assert apple_to_datetime(None) is None
```

**Step 6: Run all db tests**

Run: `pytest tests/test_db.py -v`
Expected: 6 passed

**Step 7: Commit**

```bash
git add src/imessage_mcp/db.py tests/test_db.py
git commit -m "feat: add database connection manager with Apple epoch conversion"
```

---

### Task 1.3: Phone Number Utilities

**Files:**
- Create: `src/imessage_mcp/phone.py`
- Create: `tests/test_phone.py`

**Step 1: Write failing tests**

Create `tests/test_phone.py`:
```python
"""Tests for phone number utilities."""

import pytest
from imessage_mcp.phone import (
    normalize_to_e164,
    format_phone_display,
    is_phone_number,
    is_email,
)


class TestNormalizeToE164:
    def test_us_10_digit(self):
        assert normalize_to_e164("5551234567") == "+15551234567"

    def test_us_with_country_code(self):
        assert normalize_to_e164("15551234567") == "+15551234567"

    def test_already_e164(self):
        assert normalize_to_e164("+15551234567") == "+15551234567"

    def test_formatted_number(self):
        assert normalize_to_e164("(555) 123-4567") == "+15551234567"

    def test_invalid_number(self):
        assert normalize_to_e164("invalid") is None

    def test_short_number(self):
        assert normalize_to_e164("123") is None


class TestFormatPhoneDisplay:
    def test_us_number(self):
        result = format_phone_display("+15551234567")
        assert "555" in result
        assert "123" in result
        assert "4567" in result

    def test_invalid_returns_original(self):
        assert format_phone_display("invalid") == "invalid"


class TestIsPhoneNumber:
    def test_valid_phone(self):
        assert is_phone_number("+15551234567") is True
        assert is_phone_number("555-123-4567") is True

    def test_invalid_phone(self):
        assert is_phone_number("hello") is False
        assert is_phone_number("123") is False


class TestIsEmail:
    def test_valid_email(self):
        assert is_email("test@example.com") is True

    def test_invalid_email(self):
        assert is_email("notanemail") is False
        assert is_email("missing@domain") is False
```

**Step 2: Run test to verify it fails**

Run: `pytest tests/test_phone.py -v`
Expected: FAIL with "ModuleNotFoundError"

**Step 3: Implement phone module**

Create `src/imessage_mcp/phone.py`:
```python
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
    except:
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
    except:
        return e164


def is_phone_number(text: str) -> bool:
    """Check if text looks like a phone number."""
    cleaned = ''.join(c for c in text if c.isdigit())
    return 7 <= len(cleaned) <= 15


def is_email(text: str) -> bool:
    """Check if text looks like an email address."""
    return '@' in text and '.' in text.split('@')[-1]
```

**Step 4: Run tests**

Run: `pytest tests/test_phone.py -v`
Expected: All passed

**Step 5: Commit**

```bash
git add src/imessage_mcp/phone.py tests/test_phone.py
git commit -m "feat: add phone number normalization utilities"
```

---

### Task 1.4: Contact Resolution Module

**Files:**
- Create: `src/imessage_mcp/contacts.py`
- Create: `tests/test_contacts.py`

**Step 1: Write tests**

Create `tests/test_contacts.py`:
```python
"""Tests for contact resolution."""

import pytest
from imessage_mcp.contacts import (
    ContactResolver,
    resolve_handle,
    PYOBJC_AVAILABLE,
)


def test_resolve_handle_with_lookup():
    """Test resolving a handle against a lookup dict."""
    lookup = {
        "+15551234567": "John Doe",
        "test@example.com": "Jane Smith",
    }

    assert resolve_handle("+15551234567", lookup) == "John Doe"
    assert resolve_handle("test@example.com", lookup) == "Jane Smith"
    assert resolve_handle("+19999999999", lookup) is None


def test_resolve_handle_email_case_insensitive():
    """Test that email lookup is case insensitive."""
    lookup = {"test@example.com": "Jane Smith"}
    assert resolve_handle("TEST@EXAMPLE.COM", lookup) == "Jane Smith"


def test_contact_resolver_without_pyobjc():
    """Test ContactResolver gracefully handles missing PyObjC."""
    resolver = ContactResolver()
    # Should not crash even if PyObjC unavailable
    result = resolver.resolve("+15551234567")
    # Result depends on PyObjC availability
    assert result is None or isinstance(result, str)


@pytest.mark.skipif(not PYOBJC_AVAILABLE, reason="PyObjC not available")
def test_contact_resolver_initialization():
    """Test ContactResolver can initialize (requires Contacts access)."""
    resolver = ContactResolver()
    # May return False if Contacts access denied
    initialized = resolver.initialize()
    stats = resolver.get_stats()
    assert 'initialized' in stats
```

**Step 2: Run test to verify it fails**

Run: `pytest tests/test_contacts.py -v`
Expected: FAIL with "ModuleNotFoundError"

**Step 3: Implement contacts module**

Create `src/imessage_mcp/contacts.py`:
```python
"""Contact resolution via CNContactStore (PyObjC)."""

from typing import Optional
from .phone import normalize_to_e164

PYOBJC_AVAILABLE = False
CNContactStore = None
CNContactFetchRequest = None
CNEntityTypeContacts = None

try:
    from Contacts import (
        CNContactStore as _CNContactStore,
        CNContactFetchRequest as _CNContactFetchRequest,
        CNContactGivenNameKey,
        CNContactFamilyNameKey,
        CNContactPhoneNumbersKey,
        CNContactEmailAddressesKey,
        CNContactIdentifierKey,
        CNEntityTypeContacts as _CNEntityTypeContacts
    )
    CNContactStore = _CNContactStore
    CNContactFetchRequest = _CNContactFetchRequest
    CNEntityTypeContacts = _CNEntityTypeContacts
    PYOBJC_AVAILABLE = True
except ImportError:
    pass


def check_contacts_authorization() -> tuple[bool, str]:
    """Check current Contacts authorization status."""
    if not PYOBJC_AVAILABLE:
        return False, "PyObjC not installed"

    auth_status = CNContactStore.authorizationStatusForEntityType_(CNEntityTypeContacts)

    status_map = {
        0: "not_determined",
        1: "restricted",
        2: "denied",
        3: "authorized",
        4: "limited",
    }

    status_name = status_map.get(auth_status, f"unknown_{auth_status}")
    is_authorized = auth_status == 3

    return is_authorized, status_name


def build_contact_lookup() -> dict[str, str]:
    """Build phone/email -> name lookup table from Contacts."""
    if not PYOBJC_AVAILABLE:
        return {}

    is_authorized, status = check_contacts_authorization()
    if not is_authorized:
        return {}

    store = CNContactStore.new()

    keys_to_fetch = [
        CNContactIdentifierKey,
        CNContactGivenNameKey,
        CNContactFamilyNameKey,
        CNContactPhoneNumbersKey,
        CNContactEmailAddressesKey
    ]

    fetch_request = CNContactFetchRequest.alloc().initWithKeysToFetch_(keys_to_fetch)
    lookup = {}

    def process_contact(contact, stop):
        given = contact.givenName() or ""
        family = contact.familyName() or ""
        name = f"{given} {family}".strip()

        if not name:
            return

        for labeled_phone in contact.phoneNumbers():
            phone_value = labeled_phone.value()
            if phone_value:
                number = phone_value.stringValue()
                normalized = normalize_to_e164(number)
                if normalized:
                    lookup[normalized] = name

        for labeled_email in contact.emailAddresses():
            email_value = labeled_email.value()
            if email_value:
                lookup[email_value.lower()] = name

    try:
        error = None
        store.enumerateContactsWithFetchRequest_error_usingBlock_(
            fetch_request, error, process_contact
        )
    except Exception:
        return {}

    return lookup


def resolve_handle(handle: str, lookup: dict[str, str]) -> Optional[str]:
    """Resolve a handle (phone/email) to a contact name."""
    if not handle:
        return None

    if handle in lookup:
        return lookup[handle]

    normalized = normalize_to_e164(handle)
    if normalized and normalized in lookup:
        return lookup[normalized]

    if '@' in handle:
        lower = handle.lower()
        if lower in lookup:
            return lookup[lower]

    return None


class ContactResolver:
    """Cached contact resolver for efficient repeated lookups."""

    def __init__(self):
        self._lookup: Optional[dict[str, str]] = None
        self._is_available = PYOBJC_AVAILABLE

    @property
    def is_available(self) -> bool:
        return self._is_available

    def initialize(self) -> bool:
        """Initialize the contact lookup cache."""
        if not self._is_available:
            return False

        self._lookup = build_contact_lookup()
        return len(self._lookup) > 0

    def resolve(self, handle: str) -> Optional[str]:
        """Resolve a handle to a contact name."""
        if self._lookup is None:
            self.initialize()

        if self._lookup is None:
            return None

        return resolve_handle(handle, self._lookup)

    def get_stats(self) -> dict:
        """Get statistics about the contact cache."""
        if self._lookup is None:
            return {'initialized': False, 'handle_count': 0}

        return {
            'initialized': True,
            'handle_count': len(self._lookup),
        }
```

**Step 4: Run tests**

Run: `pytest tests/test_contacts.py -v`
Expected: All passed (some may skip if no PyObjC)

**Step 5: Commit**

```bash
git add src/imessage_mcp/contacts.py tests/test_contacts.py
git commit -m "feat: add contact resolution via CNContactStore"
```

---

### Task 1.5: Message Parsing Utilities

**Files:**
- Create: `src/imessage_mcp/parsing.py`
- Create: `tests/test_parsing.py`

**Step 1: Write tests**

Create `tests/test_parsing.py`:
```python
"""Tests for message parsing utilities."""

import pytest
from imessage_mcp.parsing import (
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
```

**Step 2: Run test to verify it fails**

Run: `pytest tests/test_parsing.py -v`
Expected: FAIL with "ModuleNotFoundError"

**Step 3: Implement parsing module**

Create `src/imessage_mcp/parsing.py`:
```python
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
        except:
            return None


def get_message_text(text: Optional[str], attributed_body: Optional[bytes] = None) -> Optional[str]:
    """Get message text, preferring text column but falling back to attributedBody."""
    if text:
        return text

    if attributed_body:
        return extract_text_from_attributed_body(attributed_body)

    return None


def extract_links(text: str) -> list[str]:
    """Extract URLs from message text."""
    if not text:
        return []

    url_pattern = r'https?://[^\s<>"{}|\\^`\[\]]+'
    return re.findall(url_pattern, text)


def is_reaction_message(associated_message_type: int) -> bool:
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
```

**Step 4: Run tests**

Run: `pytest tests/test_parsing.py -v`
Expected: All passed

**Step 5: Commit**

```bash
git add src/imessage_mcp/parsing.py tests/test_parsing.py
git commit -m "feat: add message parsing utilities for text extraction and reactions"
```

---

### Task 1.6: Time Parsing Utilities

**Files:**
- Create: `src/imessage_mcp/time_utils.py`
- Create: `tests/test_time_utils.py`

**Step 1: Write tests**

Create `tests/test_time_utils.py`:
```python
"""Tests for time parsing utilities."""

import pytest
from datetime import datetime, timezone, timedelta
from imessage_mcp.time_utils import (
    parse_time_input,
    format_relative_time,
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
```

**Step 2: Run test to verify it fails**

Run: `pytest tests/test_time_utils.py -v`
Expected: FAIL with "ModuleNotFoundError"

**Step 3: Implement time utilities**

Create `src/imessage_mcp/time_utils.py`:
```python
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
```

**Step 4: Run tests**

Run: `pytest tests/test_time_utils.py -v`
Expected: All passed

**Step 5: Commit**

```bash
git add src/imessage_mcp/time_utils.py tests/test_time_utils.py
git commit -m "feat: add time parsing and relative formatting utilities"
```

---

### Task 1.7: Core Types and Models

**Files:**
- Create: `src/imessage_mcp/models.py`
- Create: `tests/test_models.py`

**Step 1: Write tests**

Create `tests/test_models.py`:
```python
"""Tests for data models."""

import pytest
from imessage_mcp.models import (
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

    def test_to_dict(self):
        p = Participant(handle="+15551234567", name="John Doe")
        d = p.to_dict()
        assert d["name"] == "John Doe"
        assert d["handle"] == "+15551234567"


class TestGenerateDisplayName:
    def test_two_known_participants(self):
        participants = [
            Participant(handle="+1111", name="John Doe"),
            Participant(handle="+2222", name="Jane Smith"),
        ]
        result = generate_display_name(participants)
        assert "John" in result
        assert "Jane" in result

    def test_unknown_participant(self):
        participants = [
            Participant(handle="+15551234567", name=None),
        ]
        result = generate_display_name(participants)
        assert "555" in result  # Formatted phone number

    def test_many_participants_truncated(self):
        participants = [
            Participant(handle=f"+{i}", name=f"Person {i}")
            for i in range(5)
        ]
        result = generate_display_name(participants, max_names=3)
        assert "others" in result
```

**Step 2: Run test to verify it fails**

Run: `pytest tests/test_models.py -v`
Expected: FAIL with "ModuleNotFoundError"

**Step 3: Implement models**

Create `src/imessage_mcp/models.py`:
```python
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
        return self.name is not None

    @property
    def display_name(self) -> str:
        return self.name or format_phone_display(self.handle)

    @property
    def short_name(self) -> str:
        if self.name:
            return self.name.split()[0]
        return format_phone_display(self.handle)

    def to_dict(self, compact: bool = False) -> dict[str, Any]:
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
        if self.display_name:
            return self.display_name
        return generate_display_name(self.participants)

    def to_dict(self, compact: bool = True) -> dict[str, Any]:
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

    def to_dict(self, people_map: dict[str, str] = None) -> dict[str, Any]:
        """Convert to dict with optional people reference mapping."""
        result = {
            "id": f"msg_{self.message_id}",
            "ts": self.timestamp.isoformat(),
            "text": self.text,
        }

        if people_map and self.from_handle and self.from_handle in people_map:
            result["from"] = people_map[self.from_handle]
        elif self.is_from_me:
            result["from"] = "me"
        elif self.from_name:
            result["from"] = self.from_name

        if self.reactions:
            result["reactions"] = self.reactions

        if self.links:
            result["links"] = self.links

        return result


def generate_display_name(participants: list[Participant], max_names: int = 3) -> str:
    """Generate display name like Messages.app does for unnamed chats."""
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
```

**Step 4: Run tests**

Run: `pytest tests/test_models.py -v`
Expected: All passed

**Step 5: Commit**

```bash
git add src/imessage_mcp/models.py tests/test_models.py
git commit -m "feat: add core data models for participants, chats, and messages"
```

---

### Task 1.8: Module Exports

**Files:**
- Modify: `src/imessage_mcp/__init__.py`

**Step 1: Update package init with exports**

Update `src/imessage_mcp/__init__.py`:
```python
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
```

**Step 2: Test imports work**

Run: `python -c "from imessage_mcp import ContactResolver, get_db_connection, Message; print('OK')"`
Expected: OK

**Step 3: Run all tests**

Run: `pytest tests/ -v`
Expected: All tests pass

**Step 4: Commit**

```bash
git add src/imessage_mcp/__init__.py
git commit -m "feat: add module exports to package init"
```

---

## Phase 2: Core Read Tools

### Task 2.1: Query Builder Utility

**Files:**
- Create: `src/imessage_mcp/queries.py`
- Create: `tests/test_queries.py`

**Step 1: Write tests**

Create `tests/test_queries.py`:
```python
"""Tests for query building utilities."""

import pytest
from imessage_mcp.queries import (
    QueryBuilder,
    get_chat_by_id,
    get_chat_participants,
)


def test_query_builder_basic(populated_db):
    """Test basic query building."""
    qb = QueryBuilder()
    qb.select("m.ROWID", "m.text")
    qb.from_table("message m")
    qb.where("m.is_from_me = ?", 1)
    qb.limit(10)

    query, params = qb.build()
    assert "SELECT" in query
    assert "FROM message m" in query
    assert "WHERE" in query
    assert "LIMIT 10" in query
    assert params == [1]


def test_query_builder_joins(populated_db):
    """Test query with joins."""
    qb = QueryBuilder()
    qb.select("m.text", "h.id")
    qb.from_table("message m")
    qb.join("handle h ON m.handle_id = h.ROWID")

    query, params = qb.build()
    assert "JOIN handle h" in query


def test_get_chat_participants(populated_db):
    """Test retrieving chat participants."""
    from imessage_mcp.db import get_db_connection

    with get_db_connection(populated_db) as conn:
        participants = get_chat_participants(conn, 2)  # Group chat
        assert len(participants) == 2
        assert all('handle' in p for p in participants)
```

**Step 2: Run test to verify it fails**

Run: `pytest tests/test_queries.py -v`
Expected: FAIL with "ModuleNotFoundError"

**Step 3: Implement query builder**

Create `src/imessage_mcp/queries.py`:
```python
"""SQL query building utilities."""

import sqlite3
from typing import Any, Optional
from .models import Participant
from .contacts import ContactResolver


class QueryBuilder:
    """Fluent SQL query builder."""

    def __init__(self):
        self._select: list[str] = []
        self._from: str = ""
        self._joins: list[str] = []
        self._where: list[tuple[str, list]] = []
        self._group_by: list[str] = []
        self._order_by: list[str] = []
        self._limit: Optional[int] = None
        self._offset: Optional[int] = None

    def select(self, *columns: str) -> "QueryBuilder":
        self._select.extend(columns)
        return self

    def from_table(self, table: str) -> "QueryBuilder":
        self._from = table
        return self

    def join(self, join_clause: str) -> "QueryBuilder":
        self._joins.append(f"JOIN {join_clause}")
        return self

    def left_join(self, join_clause: str) -> "QueryBuilder":
        self._joins.append(f"LEFT JOIN {join_clause}")
        return self

    def where(self, condition: str, *params) -> "QueryBuilder":
        self._where.append((condition, list(params)))
        return self

    def group_by(self, *columns: str) -> "QueryBuilder":
        self._group_by.extend(columns)
        return self

    def order_by(self, *columns: str) -> "QueryBuilder":
        self._order_by.extend(columns)
        return self

    def limit(self, n: int) -> "QueryBuilder":
        self._limit = n
        return self

    def offset(self, n: int) -> "QueryBuilder":
        self._offset = n
        return self

    def build(self) -> tuple[str, list]:
        parts = []
        params = []

        parts.append(f"SELECT {', '.join(self._select)}")
        parts.append(f"FROM {self._from}")

        for join in self._joins:
            parts.append(join)

        if self._where:
            conditions = []
            for condition, condition_params in self._where:
                conditions.append(condition)
                params.extend(condition_params)
            parts.append(f"WHERE {' AND '.join(conditions)}")

        if self._group_by:
            parts.append(f"GROUP BY {', '.join(self._group_by)}")

        if self._order_by:
            parts.append(f"ORDER BY {', '.join(self._order_by)}")

        if self._limit is not None:
            parts.append(f"LIMIT {self._limit}")

        if self._offset is not None:
            parts.append(f"OFFSET {self._offset}")

        return '\n'.join(parts), params


def get_chat_by_id(conn: sqlite3.Connection, chat_id: int) -> Optional[dict]:
    """Get chat info by ROWID."""
    cursor = conn.execute("""
        SELECT c.ROWID as id, c.guid, c.display_name, c.service_name,
               COUNT(DISTINCT chj.handle_id) as participant_count
        FROM chat c
        LEFT JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
        WHERE c.ROWID = ?
        GROUP BY c.ROWID
    """, (chat_id,))

    row = cursor.fetchone()
    if row:
        return dict(row)
    return None


def get_chat_participants(
    conn: sqlite3.Connection,
    chat_id: int,
    resolver: Optional[ContactResolver] = None
) -> list[dict]:
    """Get all participants for a chat with resolved names."""
    cursor = conn.execute("""
        SELECT h.ROWID, h.id as handle, h.service
        FROM chat_handle_join chj
        JOIN handle h ON chj.handle_id = h.ROWID
        WHERE chj.chat_id = ?
    """, (chat_id,))

    participants = []
    for row in cursor.fetchall():
        handle = row['handle']
        name = resolver.resolve(handle) if resolver else None
        participants.append({
            'handle_id': row['ROWID'],
            'handle': handle,
            'name': name,
            'service': row['service'],
            'in_contacts': name is not None,
        })

    return participants


def find_chats_by_handles(conn: sqlite3.Connection, handles: list[str]) -> list[dict]:
    """Find chats containing ALL specified handles."""
    if not handles:
        return []

    placeholders = ','.join('?' * len(handles))
    cursor = conn.execute(f"""
        SELECT c.ROWID as id, c.guid, c.display_name, c.service_name
        FROM chat c
        WHERE c.ROWID IN (
            SELECT chat_id
            FROM chat_handle_join chj
            JOIN handle h ON chj.handle_id = h.ROWID
            WHERE h.id IN ({placeholders})
            GROUP BY chat_id
            HAVING COUNT(DISTINCT h.id) = ?
        )
    """, (*handles, len(handles)))

    return [dict(row) for row in cursor.fetchall()]


def get_messages_for_chat(
    conn: sqlite3.Connection,
    chat_id: int,
    limit: int = 50,
    since_apple: Optional[int] = None,
    before_apple: Optional[int] = None,
    from_handle: Optional[str] = None,
    contains: Optional[str] = None,
) -> list[dict]:
    """Get messages from a chat with optional filters."""
    qb = QueryBuilder()
    qb.select(
        "m.ROWID as id",
        "m.guid",
        "m.text",
        "m.attributedBody",
        "m.date",
        "m.is_from_me",
        "m.associated_message_type",
        "m.associated_message_guid",
        "h.id as sender_handle"
    )
    qb.from_table("message m")
    qb.join("chat_message_join cmj ON m.ROWID = cmj.message_id")
    qb.left_join("handle h ON m.handle_id = h.ROWID")
    qb.where("cmj.chat_id = ?", chat_id)
    qb.where("m.associated_message_type = 0")  # Exclude reactions

    if since_apple:
        qb.where("m.date >= ?", since_apple)

    if before_apple:
        qb.where("m.date < ?", before_apple)

    if from_handle:
        qb.where("h.id = ?", from_handle)

    if contains:
        qb.where("m.text LIKE ?", f"%{contains}%")

    qb.order_by("m.date DESC")
    qb.limit(limit)

    query, params = qb.build()
    cursor = conn.execute(query, params)

    return [dict(row) for row in cursor.fetchall()]


def get_reactions_for_messages(
    conn: sqlite3.Connection,
    message_guids: list[str]
) -> dict[str, list[dict]]:
    """Get reactions grouped by original message GUID."""
    if not message_guids:
        return {}

    placeholders = ','.join('?' * len(message_guids))
    cursor = conn.execute(f"""
        SELECT
            m.associated_message_guid,
            m.associated_message_type,
            m.associated_message_emoji,
            h.id as from_handle,
            m.date
        FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        WHERE m.associated_message_guid IN ({placeholders})
        AND m.associated_message_type >= 2000
        AND m.associated_message_type < 3000
        ORDER BY m.date
    """, tuple(message_guids))

    reactions: dict[str, list[dict]] = {}
    for row in cursor.fetchall():
        guid = row['associated_message_guid']
        if guid not in reactions:
            reactions[guid] = []
        reactions[guid].append({
            'type': row['associated_message_type'],
            'emoji': row['associated_message_emoji'],
            'from_handle': row['from_handle'],
            'date': row['date'],
        })

    return reactions
```

**Step 4: Run tests**

Run: `pytest tests/test_queries.py -v`
Expected: All passed

**Step 5: Commit**

```bash
git add src/imessage_mcp/queries.py tests/test_queries.py
git commit -m "feat: add SQL query builder and common query functions"
```

---

### Task 2.2: find_chat Tool

**Files:**
- Create: `src/imessage_mcp/tools/__init__.py`
- Create: `src/imessage_mcp/tools/find_chat.py`
- Create: `tests/test_tool_find_chat.py`
- Modify: `src/imessage_mcp/server.py`

**Step 1: Write tests**

Create `tests/test_tool_find_chat.py`:
```python
"""Tests for find_chat tool."""

import pytest
from imessage_mcp.tools.find_chat import find_chat_impl


def test_find_chat_by_participants(populated_db):
    """Test finding chat by participant handles."""
    result = find_chat_impl(
        participants=["+19175551234"],
        db_path=populated_db,
    )

    assert "chats" in result
    assert len(result["chats"]) > 0


def test_find_chat_by_name(populated_db):
    """Test finding chat by display name."""
    result = find_chat_impl(
        name="Test Group",
        db_path=populated_db,
    )

    assert "chats" in result
    assert len(result["chats"]) > 0
    assert result["chats"][0]["name"] == "Test Group"


def test_find_chat_requires_parameter(populated_db):
    """Test that at least one search param is required."""
    result = find_chat_impl(db_path=populated_db)

    assert "error" in result


def test_find_chat_no_results(populated_db):
    """Test handling of no matches."""
    result = find_chat_impl(
        name="NonexistentChat12345",
        db_path=populated_db,
    )

    assert "chats" in result
    assert len(result["chats"]) == 0
```

**Step 2: Run test to verify it fails**

Run: `pytest tests/test_tool_find_chat.py -v`
Expected: FAIL with "ModuleNotFoundError"

**Step 3: Create tools package init**

Create `src/imessage_mcp/tools/__init__.py`:
```python
"""iMessage MCP Tools."""

from .find_chat import find_chat_impl

__all__ = ["find_chat_impl"]
```

**Step 4: Implement find_chat tool**

Create `src/imessage_mcp/tools/find_chat.py`:
```python
"""find_chat tool implementation."""

from typing import Optional, Any
from ..db import get_db_connection, apple_to_datetime, DB_PATH
from ..contacts import ContactResolver
from ..phone import normalize_to_e164, format_phone_display
from ..queries import (
    get_chat_by_id,
    get_chat_participants,
    find_chats_by_handles,
)
from ..models import Participant, generate_display_name
from ..time_utils import format_compact_relative


def find_chat_impl(
    participants: Optional[list[str]] = None,
    name: Optional[str] = None,
    contains_recent: Optional[str] = None,
    is_group: Optional[bool] = None,
    limit: int = 5,
    cursor: Optional[str] = None,
    db_path: str = DB_PATH,
) -> dict[str, Any]:
    """
    Find chats by participants, name, or recent content.

    At least one of participants, name, or contains_recent must be provided.
    """
    if not any([participants, name, contains_recent]):
        return {
            "error": "validation_error",
            "message": "At least one of participants, name, or contains_recent required",
        }

    resolver = ContactResolver()

    try:
        with get_db_connection(db_path) as conn:
            results = []

            # Strategy 1: Search by participant handles
            if participants:
                # Resolve names to handles
                handles = []
                for p in participants:
                    if p.startswith('+'):
                        handles.append(p)
                    else:
                        normalized = normalize_to_e164(p)
                        if normalized:
                            handles.append(normalized)
                        else:
                            # Try name lookup via contacts
                            if resolver.is_available:
                                resolver.initialize()
                                # Reverse lookup name -> handles
                                for handle, contact_name in (resolver._lookup or {}).items():
                                    if p.lower() in contact_name.lower():
                                        handles.append(handle)

                if handles:
                    chat_rows = find_chats_by_handles(conn, handles)
                    for chat_row in chat_rows:
                        chat_info = _build_chat_info(conn, chat_row, resolver)
                        chat_info["match"] = "participants"
                        results.append(chat_info)

            # Strategy 2: Search by display name
            if name and not results:
                cursor_obj = conn.execute("""
                    SELECT c.ROWID as id, c.guid, c.display_name, c.service_name
                    FROM chat c
                    WHERE c.display_name LIKE ?
                    LIMIT ?
                """, (f"%{name}%", limit))

                for row in cursor_obj.fetchall():
                    chat_info = _build_chat_info(conn, dict(row), resolver)
                    chat_info["match"] = "name"
                    results.append(chat_info)

            # Strategy 3: Search by recent content
            if contains_recent and not results:
                cursor_obj = conn.execute("""
                    SELECT DISTINCT c.ROWID as id, c.guid, c.display_name, c.service_name
                    FROM chat c
                    JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
                    JOIN message m ON cmj.message_id = m.ROWID
                    WHERE m.text LIKE ?
                    ORDER BY m.date DESC
                    LIMIT ?
                """, (f"%{contains_recent}%", limit))

                for row in cursor_obj.fetchall():
                    chat_info = _build_chat_info(conn, dict(row), resolver)
                    chat_info["match"] = "content"
                    results.append(chat_info)

            # Filter by is_group if specified
            if is_group is not None:
                results = [r for r in results if r.get("group", False) == is_group]

            # Deduplicate and limit
            seen_ids = set()
            unique_results = []
            for r in results:
                if r["id"] not in seen_ids:
                    seen_ids.add(r["id"])
                    unique_results.append(r)
                    if len(unique_results) >= limit:
                        break

            return {
                "chats": unique_results,
                "more": len(results) > limit,
                "cursor": None,
            }

    except FileNotFoundError:
        return {
            "error": "database_not_found",
            "message": f"Database not found at {db_path}",
        }
    except Exception as e:
        return {
            "error": "internal_error",
            "message": str(e),
        }


def _build_chat_info(conn, chat_row: dict, resolver: ContactResolver) -> dict:
    """Build chat info dict with participants."""
    chat_id = chat_row['id']

    # Get participants
    participant_rows = get_chat_participants(conn, chat_id, resolver)
    participants = []
    for p in participant_rows:
        participants.append({
            "name": p['name'],
            "handle": p['handle'],
        })

    is_group = len(participants) > 1

    # Generate display name if not set
    display_name = chat_row.get('display_name')
    if not display_name:
        participant_objs = [
            Participant(handle=p['handle'], name=p['name'])
            for p in participants
        ]
        display_name = generate_display_name(participant_objs)

    # Get last message
    cursor = conn.execute("""
        SELECT m.text, m.date, m.is_from_me, h.id as sender_handle
        FROM message m
        JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        WHERE cmj.chat_id = ?
        AND m.associated_message_type = 0
        ORDER BY m.date DESC
        LIMIT 1
    """, (chat_id,))

    last_msg = cursor.fetchone()
    last_info = None
    if last_msg:
        sender = "me" if last_msg['is_from_me'] else (
            resolver.resolve(last_msg['sender_handle']) if resolver else last_msg['sender_handle']
        )
        last_dt = apple_to_datetime(last_msg['date'])
        last_info = {
            "from": sender,
            "text": (last_msg['text'] or "")[:50],
            "ago": format_compact_relative(last_dt),
        }

    result = {
        "id": f"chat{chat_id}",
        "name": display_name,
        "participants": participants,
    }

    if is_group:
        result["group"] = True

    if last_info:
        result["last"] = last_info

    return result
```

**Step 5: Run tests**

Run: `pytest tests/test_tool_find_chat.py -v`
Expected: All passed

**Step 6: Register tool with server**

Update `src/imessage_mcp/server.py`:
```python
"""iMessage MCP Server."""

from typing import Optional
from fastmcp import FastMCP

from .tools.find_chat import find_chat_impl

mcp = FastMCP("iMessage MCP")


@mcp.tool()
def find_chat(
    participants: Optional[list[str]] = None,
    name: Optional[str] = None,
    contains_recent: Optional[str] = None,
    is_group: Optional[bool] = None,
    limit: int = 5,
) -> dict:
    """
    Find chats by participants, name, or recent content.

    Args:
        participants: List of participant names or phone numbers to match
        name: Chat display name to search for (fuzzy match)
        contains_recent: Text that appears in recent messages
        is_group: Filter to group chats only (True) or DMs only (False)
        limit: Maximum results to return (default 5)

    Returns:
        List of matching chats with participant info
    """
    return find_chat_impl(
        participants=participants,
        name=name,
        contains_recent=contains_recent,
        is_group=is_group,
        limit=limit,
    )


def main():
    """Run the MCP server."""
    mcp.run()


if __name__ == "__main__":
    main()
```

**Step 7: Run all tests**

Run: `pytest tests/ -v`
Expected: All passed

**Step 8: Commit**

```bash
git add src/imessage_mcp/tools/ src/imessage_mcp/server.py tests/test_tool_find_chat.py
git commit -m "feat: implement find_chat tool with participant and name search"
```

---

### Task 2.3: get_messages Tool

**Files:**
- Create: `src/imessage_mcp/tools/get_messages.py`
- Create: `tests/test_tool_get_messages.py`
- Modify: `src/imessage_mcp/tools/__init__.py`
- Modify: `src/imessage_mcp/server.py`

**Step 1: Write tests**

Create `tests/test_tool_get_messages.py`:
```python
"""Tests for get_messages tool."""

import pytest
from imessage_mcp.tools.get_messages import get_messages_impl


def test_get_messages_by_chat_id(populated_db):
    """Test getting messages by chat ID."""
    result = get_messages_impl(
        chat_id="chat1",
        db_path=populated_db,
    )

    assert "messages" in result
    assert "chat" in result


def test_get_messages_with_limit(populated_db):
    """Test message limit parameter."""
    result = get_messages_impl(
        chat_id="chat1",
        limit=1,
        db_path=populated_db,
    )

    assert len(result["messages"]) <= 1


def test_get_messages_requires_chat(populated_db):
    """Test that chat_id is required."""
    result = get_messages_impl(db_path=populated_db)

    assert "error" in result


def test_get_messages_people_map(populated_db):
    """Test that people map is included."""
    result = get_messages_impl(
        chat_id="chat1",
        db_path=populated_db,
    )

    if result.get("messages"):
        assert "people" in result
```

**Step 2: Run test to verify it fails**

Run: `pytest tests/test_tool_get_messages.py -v`
Expected: FAIL with "ModuleNotFoundError"

**Step 3: Implement get_messages tool**

Create `src/imessage_mcp/tools/get_messages.py`:
```python
"""get_messages tool implementation."""

from typing import Optional, Any
from ..db import get_db_connection, apple_to_datetime, datetime_to_apple, DB_PATH
from ..contacts import ContactResolver
from ..phone import normalize_to_e164, format_phone_display
from ..queries import get_chat_participants, get_messages_for_chat, get_reactions_for_messages
from ..parsing import get_message_text, get_reaction_type, reaction_to_emoji, extract_links
from ..time_utils import parse_time_input
from ..models import Participant, generate_display_name


def get_messages_impl(
    chat_id: Optional[str] = None,
    participants: Optional[list[str]] = None,
    since: Optional[str] = None,
    before: Optional[str] = None,
    limit: int = 50,
    from_person: Optional[str] = None,
    contains: Optional[str] = None,
    has: Optional[str] = None,
    include_reactions: bool = True,
    cursor: Optional[str] = None,
    db_path: str = DB_PATH,
) -> dict[str, Any]:
    """
    Get messages from a chat with flexible filtering.

    Either chat_id or participants must be provided.
    """
    if not chat_id and not participants:
        return {
            "error": "validation_error",
            "message": "Either chat_id or participants must be provided",
        }

    resolver = ContactResolver()

    try:
        with get_db_connection(db_path) as conn:
            # Resolve chat_id to numeric ID
            numeric_chat_id = None

            if chat_id:
                # Extract numeric ID from "chatXXX" format
                if chat_id.startswith("chat"):
                    try:
                        numeric_chat_id = int(chat_id[4:])
                    except ValueError:
                        pass

                if numeric_chat_id is None:
                    # Try to find by GUID
                    cursor_obj = conn.execute(
                        "SELECT ROWID FROM chat WHERE guid LIKE ?",
                        (f"%{chat_id}%",)
                    )
                    row = cursor_obj.fetchone()
                    if row:
                        numeric_chat_id = row[0]

            if numeric_chat_id is None:
                return {
                    "error": "chat_not_found",
                    "message": f"Chat not found: {chat_id}",
                }

            # Get chat info
            chat_cursor = conn.execute("""
                SELECT c.ROWID, c.guid, c.display_name, c.service_name
                FROM chat c WHERE c.ROWID = ?
            """, (numeric_chat_id,))
            chat_row = chat_cursor.fetchone()

            if not chat_row:
                return {
                    "error": "chat_not_found",
                    "message": f"Chat not found: {chat_id}",
                }

            # Get participants
            participant_rows = get_chat_participants(conn, numeric_chat_id, resolver)

            # Build people map (handle -> short key)
            people = {"me": "Me"}
            handle_to_key = {}
            unknown_count = 0

            for i, p in enumerate(participant_rows):
                handle = p['handle']
                if p['name']:
                    # Use first name as key
                    key = p['name'].split()[0].lower()
                    # Handle duplicates
                    if key in people:
                        key = f"{key}{i}"
                    people[key] = p['name']
                    handle_to_key[handle] = key
                else:
                    unknown_count += 1
                    key = f"unknown{unknown_count}"
                    people[key] = format_phone_display(handle)
                    handle_to_key[handle] = key

            # Convert time filters to Apple epoch
            since_apple = None
            before_apple = None

            if since:
                since_dt = parse_time_input(since)
                if since_dt:
                    since_apple = datetime_to_apple(since_dt)

            if before:
                before_dt = parse_time_input(before)
                if before_dt:
                    before_apple = datetime_to_apple(before_dt)

            # Resolve from_person to handle
            from_handle = None
            if from_person:
                if from_person.lower() == "me":
                    # Special handling for "me" - filter by is_from_me later
                    pass
                else:
                    from_handle = normalize_to_e164(from_person)
                    if not from_handle and resolver.is_available:
                        resolver.initialize()
                        for handle, name in (resolver._lookup or {}).items():
                            if from_person.lower() in name.lower():
                                from_handle = handle
                                break

            # Get messages
            message_rows = get_messages_for_chat(
                conn,
                numeric_chat_id,
                limit=limit,
                since_apple=since_apple,
                before_apple=before_apple,
                from_handle=from_handle,
                contains=contains,
            )

            # Get reactions for messages
            reactions_map = {}
            if include_reactions and message_rows:
                message_guids = [m['guid'] for m in message_rows]
                reactions_map = get_reactions_for_messages(conn, message_guids)

            # Build response
            messages = []
            for row in message_rows:
                text = get_message_text(row['text'], row.get('attributedBody'))

                msg = {
                    "id": f"msg_{row['id']}",
                    "ts": apple_to_datetime(row['date']).isoformat() if row['date'] else None,
                    "text": text,
                }

                # Add sender
                if row['is_from_me']:
                    msg["from"] = "me"
                elif row['sender_handle']:
                    msg["from"] = handle_to_key.get(row['sender_handle'], row['sender_handle'])

                # Add reactions
                if row['guid'] in reactions_map:
                    reactions = []
                    for r in reactions_map[row['guid']]:
                        reaction_type = get_reaction_type(r['type'])
                        if reaction_type and not reaction_type.startswith('removed'):
                            emoji = reaction_to_emoji(reaction_type)
                            from_key = handle_to_key.get(r['from_handle'], 'unknown')
                            reactions.append(f"{emoji} {from_key}")
                    if reactions:
                        msg["reactions"] = reactions

                # Extract links
                if text:
                    links = extract_links(text)
                    if links:
                        msg["links"] = links

                messages.append(msg)

            # Build chat info
            participant_objs = [
                Participant(handle=p['handle'], name=p['name'])
                for p in participant_rows
            ]
            display_name = chat_row['display_name'] or generate_display_name(participant_objs)

            return {
                "chat": {
                    "id": f"chat{numeric_chat_id}",
                    "name": display_name,
                },
                "people": people,
                "messages": messages,
                "more": len(messages) == limit,
                "cursor": None,
            }

    except FileNotFoundError:
        return {
            "error": "database_not_found",
            "message": f"Database not found at {db_path}",
        }
    except Exception as e:
        return {
            "error": "internal_error",
            "message": str(e),
        }
```

**Step 4: Update tools init**

Update `src/imessage_mcp/tools/__init__.py`:
```python
"""iMessage MCP Tools."""

from .find_chat import find_chat_impl
from .get_messages import get_messages_impl

__all__ = ["find_chat_impl", "get_messages_impl"]
```

**Step 5: Register tool with server**

Update `src/imessage_mcp/server.py` to add after find_chat:
```python
from .tools.get_messages import get_messages_impl


@mcp.tool()
def get_messages(
    chat_id: Optional[str] = None,
    participants: Optional[list[str]] = None,
    since: Optional[str] = None,
    before: Optional[str] = None,
    limit: int = 50,
    from_person: Optional[str] = None,
    contains: Optional[str] = None,
    include_reactions: bool = True,
) -> dict:
    """
    Get messages from a chat with flexible filtering.

    Args:
        chat_id: Chat identifier from find_chat
        participants: Alternative - find chat by participants
        since: Time bound (ISO, relative like "24h", or natural like "yesterday")
        before: Upper time bound
        limit: Max messages (default 50, max 200)
        from_person: Filter to messages from specific person (or "me")
        contains: Text search within messages
        include_reactions: Include reaction data (default True)

    Returns:
        Messages with chat info and people map for compact references
    """
    return get_messages_impl(
        chat_id=chat_id,
        participants=participants,
        since=since,
        before=before,
        limit=min(limit, 200),
        from_person=from_person,
        contains=contains,
        include_reactions=include_reactions,
    )
```

**Step 6: Run tests**

Run: `pytest tests/test_tool_get_messages.py -v`
Expected: All passed

**Step 7: Commit**

```bash
git add src/imessage_mcp/tools/ src/imessage_mcp/server.py tests/test_tool_get_messages.py
git commit -m "feat: implement get_messages tool with filtering and reactions"
```

---

### Task 2.4: list_chats Tool

**Files:**
- Create: `src/imessage_mcp/tools/list_chats.py`
- Create: `tests/test_tool_list_chats.py`
- Modify: `src/imessage_mcp/tools/__init__.py`
- Modify: `src/imessage_mcp/server.py`

**Step 1: Write tests**

Create `tests/test_tool_list_chats.py`:
```python
"""Tests for list_chats tool."""

import pytest
from imessage_mcp.tools.list_chats import list_chats_impl


def test_list_chats_basic(populated_db):
    """Test basic chat listing."""
    result = list_chats_impl(db_path=populated_db)

    assert "chats" in result
    assert isinstance(result["chats"], list)


def test_list_chats_with_limit(populated_db):
    """Test limit parameter."""
    result = list_chats_impl(limit=1, db_path=populated_db)

    assert len(result["chats"]) <= 1


def test_list_chats_groups_only(populated_db):
    """Test filtering to groups only."""
    result = list_chats_impl(is_group=True, db_path=populated_db)

    for chat in result["chats"]:
        assert chat.get("group", False) is True


def test_list_chats_has_totals(populated_db):
    """Test that totals are included."""
    result = list_chats_impl(db_path=populated_db)

    assert "total_chats" in result or "chats" in result
```

**Step 2: Run test to verify it fails**

Run: `pytest tests/test_tool_list_chats.py -v`
Expected: FAIL with "ModuleNotFoundError"

**Step 3: Implement list_chats tool**

Create `src/imessage_mcp/tools/list_chats.py`:
```python
"""list_chats tool implementation."""

from typing import Optional, Any
from ..db import get_db_connection, apple_to_datetime, datetime_to_apple, DB_PATH
from ..contacts import ContactResolver
from ..queries import get_chat_participants
from ..time_utils import parse_time_input, format_compact_relative
from ..models import Participant, generate_display_name


def list_chats_impl(
    limit: int = 20,
    since: Optional[str] = None,
    is_group: Optional[bool] = None,
    min_participants: Optional[int] = None,
    max_participants: Optional[int] = None,
    sort: str = "recent",
    cursor: Optional[str] = None,
    db_path: str = DB_PATH,
) -> dict[str, Any]:
    """
    List recent chats with previews.
    """
    resolver = ContactResolver()

    try:
        with get_db_connection(db_path) as conn:
            # Build base query
            query = """
                SELECT
                    c.ROWID as id,
                    c.guid,
                    c.display_name,
                    c.service_name,
                    COUNT(DISTINCT chj.handle_id) as participant_count,
                    MAX(m.date) as last_message_date
                FROM chat c
                LEFT JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
                LEFT JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
                LEFT JOIN message m ON cmj.message_id = m.ROWID
                    AND m.associated_message_type = 0
            """

            params = []
            conditions = []

            # Time filter
            if since:
                since_dt = parse_time_input(since)
                if since_dt:
                    since_apple = datetime_to_apple(since_dt)
                    conditions.append("m.date >= ?")
                    params.append(since_apple)

            if conditions:
                query += " WHERE " + " AND ".join(conditions)

            query += " GROUP BY c.ROWID"

            # Participant count filters
            having = []
            if min_participants is not None:
                having.append(f"participant_count >= {min_participants}")
            if max_participants is not None:
                having.append(f"participant_count <= {max_participants}")
            if is_group is not None:
                if is_group:
                    having.append("participant_count > 1")
                else:
                    having.append("participant_count = 1")

            if having:
                query += " HAVING " + " AND ".join(having)

            # Sort
            if sort == "recent":
                query += " ORDER BY last_message_date DESC NULLS LAST"
            elif sort == "alphabetical":
                query += " ORDER BY COALESCE(c.display_name, '') ASC"
            elif sort == "most_active":
                query += " ORDER BY last_message_date DESC NULLS LAST"

            query += f" LIMIT {limit}"

            cursor_obj = conn.execute(query, params)
            rows = cursor_obj.fetchall()

            # Build results
            chats = []
            for row in rows:
                chat_id = row['id']

                # Get participants
                participant_rows = get_chat_participants(conn, chat_id, resolver)
                participants = []
                for p in participant_rows:
                    participants.append({
                        "name": p['name'],
                        "handle": p['handle'],
                    })

                participant_objs = [
                    Participant(handle=p['handle'], name=p['name'])
                    for p in participant_rows
                ]

                display_name = row['display_name'] or generate_display_name(participant_objs)
                is_group_chat = row['participant_count'] > 1

                # Get last message
                last_cursor = conn.execute("""
                    SELECT m.text, m.is_from_me, h.id as sender_handle, m.date
                    FROM message m
                    JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
                    LEFT JOIN handle h ON m.handle_id = h.ROWID
                    WHERE cmj.chat_id = ?
                    AND m.associated_message_type = 0
                    ORDER BY m.date DESC
                    LIMIT 1
                """, (chat_id,))
                last_msg = last_cursor.fetchone()

                chat_info = {
                    "id": f"chat{chat_id}",
                    "name": display_name,
                    "participants": participants,
                    "participant_count": row['participant_count'],
                }

                if is_group_chat:
                    chat_info["group"] = True

                if last_msg:
                    sender = "me" if last_msg['is_from_me'] else (
                        resolver.resolve(last_msg['sender_handle']) if resolver.is_available else None
                    ) or last_msg['sender_handle']
                    last_dt = apple_to_datetime(last_msg['date'])
                    chat_info["last"] = {
                        "from": sender,
                        "text": (last_msg['text'] or "")[:50],
                        "ago": format_compact_relative(last_dt),
                    }

                chats.append(chat_info)

            # Get totals
            total_cursor = conn.execute("""
                SELECT
                    COUNT(*) as total,
                    SUM(CASE WHEN cnt > 1 THEN 1 ELSE 0 END) as groups,
                    SUM(CASE WHEN cnt = 1 THEN 1 ELSE 0 END) as dms
                FROM (
                    SELECT c.ROWID, COUNT(chj.handle_id) as cnt
                    FROM chat c
                    LEFT JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
                    GROUP BY c.ROWID
                )
            """)
            totals = total_cursor.fetchone()

            return {
                "chats": chats,
                "total_chats": totals['total'],
                "total_groups": totals['groups'],
                "total_dms": totals['dms'],
                "more": len(chats) == limit,
                "cursor": None,
            }

    except FileNotFoundError:
        return {
            "error": "database_not_found",
            "message": f"Database not found at {db_path}",
        }
    except Exception as e:
        return {
            "error": "internal_error",
            "message": str(e),
        }
```

**Step 4: Update tools init and server**

Update `src/imessage_mcp/tools/__init__.py`:
```python
"""iMessage MCP Tools."""

from .find_chat import find_chat_impl
from .get_messages import get_messages_impl
from .list_chats import list_chats_impl

__all__ = ["find_chat_impl", "get_messages_impl", "list_chats_impl"]
```

Add to `src/imessage_mcp/server.py`:
```python
from .tools.list_chats import list_chats_impl


@mcp.tool()
def list_chats(
    limit: int = 20,
    since: Optional[str] = None,
    is_group: Optional[bool] = None,
    min_participants: Optional[int] = None,
    max_participants: Optional[int] = None,
    sort: str = "recent",
) -> dict:
    """
    List recent chats with previews.

    Args:
        limit: Max chats to return (default 20)
        since: Only chats with activity since this time
        is_group: True for groups only, False for DMs only
        min_participants: Filter to chats with at least N participants
        max_participants: Filter to chats with at most N participants
        sort: "recent" (default), "alphabetical", or "most_active"

    Returns:
        List of chats with last message previews
    """
    return list_chats_impl(
        limit=limit,
        since=since,
        is_group=is_group,
        min_participants=min_participants,
        max_participants=max_participants,
        sort=sort,
    )
```

**Step 5: Run tests**

Run: `pytest tests/test_tool_list_chats.py -v`
Expected: All passed

**Step 6: Commit**

```bash
git add src/imessage_mcp/tools/ src/imessage_mcp/server.py tests/test_tool_list_chats.py
git commit -m "feat: implement list_chats tool with filtering and sorting"
```

---

## Phase 3: Search and Advanced Read Tools

Due to length constraints, I'll provide task stubs for the remaining tools. Each follows the same TDD pattern.

### Task 3.1: search Tool

**Files:** `src/imessage_mcp/tools/search.py`, `tests/test_tool_search.py`

**Key features:**
- Full-text search with compound filters
- `grouped_by_chat` format option
- `include_context` for surrounding messages
- Match highlights

### Task 3.2: get_context Tool

**Files:** `src/imessage_mcp/tools/get_context.py`, `tests/test_tool_get_context.py`

**Key features:**
- Get messages before/after a target message
- Find by message_id or by chat_id + contains

### Task 3.3: get_active_conversations Tool

**Files:** `src/imessage_mcp/tools/get_active_conversations.py`, `tests/test_tool_get_active.py`

**Key features:**
- Find chats with recent bidirectional activity
- Calculate exchanges, my_messages, their_messages
- `awaiting_my_reply` flag

### Task 3.4: list_attachments Tool

**Files:** `src/imessage_mcp/tools/list_attachments.py`, `tests/test_tool_attachments.py`

**Key features:**
- Filter by type (image, video, pdf, link, etc.)
- Include parent message context
- Link extraction with domain/title

### Task 3.5: get_unread Tool

**Files:** `src/imessage_mcp/tools/get_unread.py`, `tests/test_tool_unread.py`

**Key features:**
- `messages` format with full unread messages
- `summary` format with counts per chat
- Sort by oldest unread

---

## Phase 4: Send and Polish

### Task 4.1: send Tool

**Files:** `src/imessage_mcp/tools/send.py`, `tests/test_tool_send.py`

**Key features:**
- AppleScript backend for Messages.app
- Input sanitization for injection prevention
- Disambiguation for ambiguous recipients

### Task 4.2: from:"me" Filter Enhancement

**Files:** Modify existing tools to support `from: "me"` consistently

### Task 4.3: Unanswered Messages Filter

**Files:** Add `unanswered: true` filter to get_messages and search

### Task 4.4: Conversation Sessions

**Files:** Add session detection to get_messages responses

### Task 4.5: Smart Error Suggestions

**Files:** `src/imessage_mcp/suggestions.py`

Add contextual suggestions when queries return no results.

### Task 4.6: Integration Tests

**Files:** `tests/integration/test_real_database.py`

Tests against real chat.db (marked to skip in CI).

### Task 4.7: Documentation

**Files:** `README.md` (update only if explicitly requested by user)

---

## Final Verification

After all tasks complete:

1. Run full test suite: `pytest tests/ -v`
2. Test with real database: `pytest tests/integration/ -v --real-db`
3. Test MCP server: `imessage-mcp` (verify it starts)
4. Test with Claude: Connect MCP and run sample queries

---

## Summary

**Total Tasks:** 27 (7 infrastructure + 4 core tools + 6 advanced tools + 6 send/polish + 4 final)

**Key Patterns:**
- TDD: Write failing test → Implement → Verify → Commit
- Token efficiency: Compact response schemas with people maps
- Safety: Read-only DB, AppleScript sanitization, connection lifecycle

**Dependencies to Install:**
```bash
pip install fastmcp pyobjc-framework-Contacts phonenumbers python-dateutil pytest pytest-asyncio
```
