"""
Contact resolution via CNContactStore (PyObjC).

This is the only reliable way to access iCloud contacts on macOS.
The AddressBook SQLite database does NOT contain iCloud contacts.
"""

from typing import Optional
from .phone import normalize_to_e164

# Track whether PyObjC is available
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
    """
    Check current Contacts authorization status.

    Returns:
        Tuple of (is_authorized, status_description)
    """
    if not PYOBJC_AVAILABLE:
        return False, "PyObjC not installed"

    auth_status = CNContactStore.authorizationStatusForEntityType_(CNEntityTypeContacts)

    status_map = {
        0: "not_determined",
        1: "restricted",
        2: "denied",
        3: "authorized",
        4: "limited",  # iOS 14+ partial access
    }

    status_name = status_map.get(auth_status, f"unknown_{auth_status}")
    is_authorized = auth_status == 3

    return is_authorized, status_name


def request_contacts_access() -> bool:
    """
    Request access to Contacts.

    NOTE: The permission prompt may not appear in VS Code's integrated terminal.
    User should run from Terminal.app for first authorization.

    Returns:
        True if access was granted
    """
    if not PYOBJC_AVAILABLE:
        return False

    store = CNContactStore.new()

    # This is async but we'll block with a simple flag
    result = {'granted': False, 'done': False}

    def completion_handler(granted, error):
        result['granted'] = granted
        result['done'] = True

    store.requestAccessForEntityType_completionHandler_(
        CNEntityTypeContacts,
        completion_handler
    )

    # Wait for completion (crude but effective for testing)
    import time
    for _ in range(50):  # 5 second timeout
        if result['done']:
            break
        time.sleep(0.1)

    return result['granted']


def build_contact_lookup() -> dict[str, str]:
    """
    Build phone/email -> name lookup table from Contacts.

    Returns:
        Dictionary mapping handles (E.164 phones, lowercase emails) to full names
    """
    if not PYOBJC_AVAILABLE:
        return {}

    is_authorized, status = check_contacts_authorization()
    if not is_authorized:
        print(f"Contacts not authorized: {status}")
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
    contact_count = 0

    def process_contact(contact, stop):
        nonlocal contact_count
        contact_count += 1

        # Build full name
        given = contact.givenName() or ""
        family = contact.familyName() or ""
        name = f"{given} {family}".strip()

        if not name:
            return

        # Index by phone numbers (normalized to E.164)
        for labeled_phone in contact.phoneNumbers():
            phone_value = labeled_phone.value()
            if phone_value:
                number = phone_value.stringValue()
                normalized = normalize_to_e164(number)
                if normalized:
                    lookup[normalized] = name

        # Index by email addresses (lowercased)
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
        print(f"Error enumerating contacts: {e}")
        return {}

    print(f"Indexed {contact_count} contacts, {len(lookup)} handles")
    return lookup


def resolve_handle(handle: str, lookup: dict[str, str]) -> Optional[str]:
    """
    Resolve a handle (phone/email) to a contact name.

    Args:
        handle: Phone number (E.164) or email address
        lookup: Contact lookup dictionary from build_contact_lookup()

    Returns:
        Contact name or None if not found
    """
    if not handle:
        return None

    # Try direct lookup
    if handle in lookup:
        return lookup[handle]

    # Try normalized phone number
    normalized = normalize_to_e164(handle)
    if normalized and normalized in lookup:
        return lookup[normalized]

    # Try lowercase email
    if '@' in handle:
        lower = handle.lower()
        if lower in lookup:
            return lookup[lower]

    return None


class ContactResolver:
    """
    Cached contact resolver for efficient repeated lookups.
    """

    def __init__(self):
        self._lookup: Optional[dict[str, str]] = None
        self._is_available = PYOBJC_AVAILABLE

    @property
    def is_available(self) -> bool:
        """Check if contact resolution is available."""
        return self._is_available

    def initialize(self) -> bool:
        """
        Initialize the contact lookup cache.

        Returns:
            True if initialization succeeded
        """
        if not self._is_available:
            return False

        self._lookup = build_contact_lookup()
        return len(self._lookup) > 0

    def resolve(self, handle: str) -> Optional[str]:
        """
        Resolve a handle to a contact name.

        Initializes lookup on first call if needed.
        """
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
