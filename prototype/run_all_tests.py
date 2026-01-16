#!/usr/bin/env python3
"""
Run all prototype tests for iMessage MCP Pro.

This script runs all four test modules and provides a summary:
1. Database access verification
2. Contacts resolution via PyObjC
3. attributedBody parsing
4. Participant-based chat lookup

Prerequisites:
- Python 3.10+
- Full Disk Access granted to Terminal/Python
- Contacts access granted
- Run from Terminal.app (not VS Code) for permission prompts

Usage:
    python prototype/run_all_tests.py
"""

import sys
import os

# Ensure we can import from prototype
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def main():
    print("=" * 70)
    print("iMessage MCP Pro - Prototype Test Suite")
    print("=" * 70)
    print()
    print("This test suite validates key assumptions:")
    print("  1. Database access (read-only, connection lifecycle)")
    print("  2. Contacts resolution (CNContactStore via PyObjC)")
    print("  3. attributedBody parsing (typedstream format)")
    print("  4. Participant-based chat lookup (find_chat functionality)")
    print()
    print("Prerequisites:")
    print("  - Python 3.10+ (PyObjC requirement)")
    print("  - Full Disk Access granted")
    print("  - Contacts access granted")
    print("  - Run from Terminal.app for permission prompts")
    print()

    # Check Python version
    if sys.version_info < (3, 10):
        print(f"ERROR: Python 3.10+ required, got {sys.version_info.major}.{sys.version_info.minor}")
        return 1

    print(f"Python version: {sys.version}")
    print()

    results = {}

    # Test 1: Database access
    print("\n" + "=" * 70)
    try:
        from prototype.test_db_access import run_all_tests as test1
        results['Database Access'] = test1()
    except Exception as e:
        print(f"ERROR importing test_db_access: {e}")
        results['Database Access'] = False

    # Test 2: Contacts resolution
    print("\n" + "=" * 70)
    try:
        from prototype.test_contacts import run_all_tests as test2
        results['Contacts Resolution'] = test2()
    except Exception as e:
        print(f"ERROR importing test_contacts: {e}")
        results['Contacts Resolution'] = False

    # Test 3: attributedBody parsing
    print("\n" + "=" * 70)
    try:
        from prototype.test_attributed_body import run_all_tests as test3
        results['attributedBody Parsing'] = test3()
    except Exception as e:
        print(f"ERROR importing test_attributed_body: {e}")
        results['attributedBody Parsing'] = False

    # Test 4: Chat lookup
    print("\n" + "=" * 70)
    try:
        from prototype.test_chat_lookup import run_all_tests as test4
        results['Chat Lookup'] = test4()
    except Exception as e:
        print(f"ERROR importing test_chat_lookup: {e}")
        results['Chat Lookup'] = False

    # Summary
    print("\n" + "=" * 70)
    print("FINAL SUMMARY")
    print("=" * 70)

    passed = sum(1 for v in results.values() if v)
    failed = len(results) - passed

    for name, success in results.items():
        status = "PASS" if success else "FAIL"
        print(f"  {status}: {name}")

    print()
    print(f"Overall: {passed}/{len(results)} test modules passed")

    if failed == 0:
        print("\nAll prototype tests passed! Ready for implementation.")
    else:
        print("\nSome tests failed. Review output above for details.")

    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
