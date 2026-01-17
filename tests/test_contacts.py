"""Tests for contact resolution."""

import pytest
from imessage_max.contacts import (
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
