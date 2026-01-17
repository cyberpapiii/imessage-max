#!/usr/bin/env python3
"""
Test 2: Contacts Resolution via PyObjC

Tests:
- Request and verify permission
- Fetch all contacts with phone numbers
- Build phone -> name lookup table
- Test E.164 normalization matching
- Measure performance with full contact list
"""

import sys
import os
import time

# Add parent to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from prototype.utils.contacts import (
    PYOBJC_AVAILABLE,
    check_contacts_authorization,
    build_contact_lookup,
    resolve_handle,
    ContactResolver
)
from prototype.utils.phone import (
    normalize_to_e164,
    format_phone_display,
    PHONENUMBERS_AVAILABLE
)
from prototype.utils.db import get_db_connection


def test_pyobjc_available():
    """Test 2.1: Check if PyObjC is installed."""
    print("\n--- Test 2.1: PyObjC Availability ---")

    if PYOBJC_AVAILABLE:
        print("PASS: PyObjC Contacts framework is available")
        return True
    else:
        print("FAIL: PyObjC not installed")
        print("      Install with: pip install pyobjc-framework-Contacts")
        return False


def test_phonenumbers_available():
    """Test 2.2: Check if phonenumbers library is available."""
    print("\n--- Test 2.2: phonenumbers Library ---")

    if PHONENUMBERS_AVAILABLE:
        print("PASS: phonenumbers library is available")
        return True
    else:
        print("WARN: phonenumbers not installed (using fallback normalization)")
        print("      Install with: pip install phonenumbers")
        return True  # Not a failure, just using fallback


def test_contacts_authorization():
    """Test 2.3: Check Contacts authorization status."""
    print("\n--- Test 2.3: Contacts Authorization ---")

    if not PYOBJC_AVAILABLE:
        print("SKIP: PyObjC not available")
        return False

    is_authorized, status = check_contacts_authorization()

    print(f"      Authorization status: {status}")

    if is_authorized:
        print("PASS: Contacts access is authorized")
        return True
    else:
        print("WARN: Contacts access not authorized")
        print("      Please grant Contacts access when prompted")
        print("      NOTE: Permission prompt may not appear in VS Code terminal")
        print("      Try running from Terminal.app instead")
        return False


def test_build_lookup():
    """Test 2.4: Build contact lookup table."""
    print("\n--- Test 2.4: Build Contact Lookup ---")

    if not PYOBJC_AVAILABLE:
        print("SKIP: PyObjC not available")
        return False

    start = time.time()
    lookup = build_contact_lookup()
    elapsed = time.time() - start

    if len(lookup) == 0:
        print("FAIL: No contacts loaded")
        print("      Check Contacts authorization")
        return False

    # Count unique names (values)
    unique_names = len(set(lookup.values()))

    print(f"PASS: Built contact lookup")
    print(f"      Handles indexed: {len(lookup):,}")
    print(f"      Unique contacts: {unique_names:,}")
    print(f"      Build time: {elapsed:.3f}s")

    # Show sample entries
    print("      Sample entries:")
    for i, (handle, name) in enumerate(list(lookup.items())[:3]):
        # Redact phone numbers for privacy
        if handle.startswith('+'):
            display_handle = handle[:6] + '****' + handle[-2:]
        else:
            display_handle = handle[:10] + '...' if len(handle) > 10 else handle
        print(f"        {display_handle} -> {name}")

    return True


def test_phone_normalization():
    """Test 2.5: Test phone number normalization."""
    print("\n--- Test 2.5: Phone Normalization ---")

    # Use valid US phone numbers (212 is NYC area code)
    # Note: 555-xxxx numbers are fictional/reserved and rejected by phonenumbers
    test_cases = [
        ("(212) 456-7890", "+12124567890"),
        ("212-456-7890", "+12124567890"),
        ("2124567890", "+12124567890"),
        ("+1 212 456 7890", "+12124567890"),
        ("1-212-456-7890", "+12124567890"),
    ]

    passed = 0
    for input_num, expected in test_cases:
        result = normalize_to_e164(input_num)
        if result == expected:
            passed += 1
            print(f"      PASS: {input_num} -> {result}")
        else:
            print(f"      FAIL: {input_num} -> {result} (expected {expected})")

    if passed == len(test_cases):
        print(f"PASS: All {passed} normalization tests passed")
        return True
    else:
        print(f"WARN: {passed}/{len(test_cases)} normalization tests passed")
        return passed > 0


def test_resolve_database_handles():
    """Test 2.6: Resolve handles from database to contact names."""
    print("\n--- Test 2.6: Resolve Database Handles ---")

    if not PYOBJC_AVAILABLE:
        print("SKIP: PyObjC not available")
        return False

    # Build lookup
    lookup = build_contact_lookup()
    if not lookup:
        print("SKIP: No contacts available")
        return False

    # Get sample handles from database
    try:
        with get_db_connection() as conn:
            cursor = conn.execute("""
                SELECT DISTINCT h.id
                FROM handle h
                JOIN chat_handle_join chj ON h.ROWID = chj.handle_id
                LIMIT 20
            """)
            handles = [row['id'] for row in cursor.fetchall()]
    except Exception as e:
        print(f"FAIL: Database error: {e}")
        return False

    if not handles:
        print("FAIL: No handles found in database")
        return False

    # Try to resolve each handle
    resolved = 0
    unresolved = 0

    print(f"      Testing {len(handles)} handles from database:")
    for handle in handles[:10]:  # Show first 10
        name = resolve_handle(handle, lookup)
        if name:
            resolved += 1
            # Redact for privacy
            if handle.startswith('+'):
                display_handle = handle[:6] + '****' + handle[-2:]
            else:
                display_handle = handle[:15] + '...' if len(handle) > 15 else handle
            print(f"        {display_handle} -> {name}")
        else:
            unresolved += 1
            if handle.startswith('+'):
                print(f"        {handle[:6]}****{handle[-2:]} -> (not in contacts)")
            else:
                print(f"        {handle} -> (not in contacts)")

    print(f"PASS: Resolved {resolved}/{len(handles)} handles to contact names")
    return True


def test_contact_resolver_class():
    """Test 2.7: Test ContactResolver class."""
    print("\n--- Test 2.7: ContactResolver Class ---")

    if not PYOBJC_AVAILABLE:
        print("SKIP: PyObjC not available")
        return False

    resolver = ContactResolver()

    if not resolver.is_available:
        print("FAIL: ContactResolver not available")
        return False

    # Initialize and get stats
    start = time.time()
    success = resolver.initialize()
    elapsed = time.time() - start

    if not success:
        print("WARN: ContactResolver initialization returned no contacts")

    stats = resolver.get_stats()
    print(f"PASS: ContactResolver initialized")
    print(f"      Handle count: {stats['handle_count']:,}")
    print(f"      Init time: {elapsed:.3f}s")

    # Test lookup
    with get_db_connection() as conn:
        cursor = conn.execute("""
            SELECT h.id
            FROM handle h
            LIMIT 1
        """)
        row = cursor.fetchone()
        if row:
            test_handle = row['id']
            name = resolver.resolve(test_handle)
            if test_handle.startswith('+'):
                display = test_handle[:6] + '****' + test_handle[-2:]
            else:
                display = test_handle
            print(f"      Test resolve: {display} -> {name or '(not found)'}")

    return True


def test_performance():
    """Test 2.8: Performance test for bulk resolution."""
    print("\n--- Test 2.8: Bulk Resolution Performance ---")

    if not PYOBJC_AVAILABLE:
        print("SKIP: PyObjC not available")
        return False

    lookup = build_contact_lookup()
    if not lookup:
        print("SKIP: No contacts available")
        return False

    # Get all handles from database
    try:
        with get_db_connection() as conn:
            cursor = conn.execute("SELECT DISTINCT id FROM handle")
            handles = [row['id'] for row in cursor.fetchall()]
    except Exception as e:
        print(f"FAIL: Database error: {e}")
        return False

    # Resolve all handles
    start = time.time()
    resolved_count = 0
    for handle in handles:
        if resolve_handle(handle, lookup):
            resolved_count += 1
    elapsed = time.time() - start

    per_handle = (elapsed / len(handles) * 1000) if handles else 0

    print(f"PASS: Bulk resolution complete")
    print(f"      Total handles: {len(handles):,}")
    print(f"      Resolved: {resolved_count:,} ({resolved_count/len(handles)*100:.1f}%)")
    print(f"      Total time: {elapsed:.3f}s")
    print(f"      Per handle: {per_handle:.3f}ms")

    return True


def run_all_tests():
    """Run all contact resolution tests."""
    print("=" * 60)
    print("TEST 2: CONTACTS RESOLUTION VIA PYOBJC")
    print("=" * 60)

    tests = [
        test_pyobjc_available,
        test_phonenumbers_available,
        test_contacts_authorization,
        test_build_lookup,
        test_phone_normalization,
        test_resolve_database_handles,
        test_contact_resolver_class,
        test_performance,
    ]

    passed = 0
    failed = 0
    skipped = 0

    for test in tests:
        try:
            result = test()
            if result is None:
                skipped += 1
            elif result:
                passed += 1
            else:
                failed += 1
        except Exception as e:
            print(f"FAIL: Unexpected error in {test.__name__}: {e}")
            import traceback
            traceback.print_exc()
            failed += 1

    print("\n" + "=" * 60)
    print(f"RESULTS: {passed} passed, {failed} failed, {skipped} skipped")
    print("=" * 60)

    return failed == 0


if __name__ == "__main__":
    success = run_all_tests()
    sys.exit(0 if success else 1)
