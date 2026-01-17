"""Contact resolution via CNContactStore (PyObjC)."""

import sys
import threading
from typing import Optional
from .phone import normalize_to_e164

PYOBJC_AVAILABLE = False
CNContactStore = None
CNContactFetchRequest = None
CNEntityTypeContacts = None
CNAuthorizationStatusNotDetermined = 0
CNAuthorizationStatusAuthorized = 3

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


def request_contacts_access(timeout: float = 30.0) -> tuple[bool, str]:
    """
    Request Contacts access if not already determined.
    
    This will trigger the macOS permission dialog if status is 'not_determined'.
    Call this on server startup to ensure users get prompted for access.
    
    Args:
        timeout: Max seconds to wait for user response (default 30)
        
    Returns:
        Tuple of (granted: bool, status: str)
    """
    if not PYOBJC_AVAILABLE:
        return False, "pyobjc_not_available"
    
    auth_status = CNContactStore.authorizationStatusForEntityType_(CNEntityTypeContacts)
    
    # Already determined - return current status
    if auth_status != CNAuthorizationStatusNotDetermined:
        is_authorized, status = check_contacts_authorization()
        return is_authorized, status
    
    # Request access - this triggers the macOS permission dialog
    print("[Contacts] Requesting access (you may see a macOS permission dialog)...", file=sys.stderr, flush=True)
    
    result = {"granted": False, "error": None}
    event = threading.Event()
    
    def completion_handler(granted, error):
        result["granted"] = granted
        result["error"] = str(error) if error else None
        event.set()
    
    store = CNContactStore.alloc().init()
    store.requestAccessForEntityType_completionHandler_(
        CNEntityTypeContacts, 
        completion_handler
    )
    
    # Wait for user response (with timeout)
    if event.wait(timeout=timeout):
        if result["granted"]:
            print("[Contacts] Access granted!", file=sys.stderr, flush=True)
            return True, "authorized"
        else:
            print(f"[Contacts] Access denied: {result['error']}", file=sys.stderr, flush=True)
            return False, "denied"
    else:
        print("[Contacts] Permission request timed out", file=sys.stderr, flush=True)
        # Check status again in case it changed
        return check_contacts_authorization()


def build_contact_lookup() -> dict[str, str]:
    """Build phone/email -> name lookup table from Contacts."""
    if not PYOBJC_AVAILABLE:
        print("[ContactResolver] PyObjC not available", file=sys.stderr, flush=True)
        return {}

    is_authorized, status = check_contacts_authorization()
    if not is_authorized:
        print(f"[ContactResolver] Contacts not authorized: {status}", file=sys.stderr, flush=True)
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
    except Exception as e:
        print(f"[ContactResolver] Error enumerating contacts: {e}", file=sys.stderr, flush=True)
        return {}

    print(f"[ContactResolver] Successfully loaded {len(lookup)} handles from contacts", file=sys.stderr, flush=True)
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

    def search_by_name(self, query: str) -> list[tuple[str, str]]:
        """Search contacts by name. Returns list of (handle, name) tuples."""
        if self._lookup is None:
            self.initialize()

        if not self._lookup:
            return []

        query_lower = query.lower()
        return [(handle, name) for handle, name in self._lookup.items()
                if query_lower in name.lower()]

    def get_stats(self) -> dict:
        """Get statistics about the contact cache."""
        if self._lookup is None:
            return {'initialized': False, 'handle_count': 0}

        return {
            'initialized': True,
            'handle_count': len(self._lookup),
        }
