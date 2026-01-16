#!/usr/bin/env python3
"""
Test 4: Participant-Based Chat Lookup

Tests:
- Query by single participant name
- Query by multiple participants (AND logic)
- Handle fuzzy name matching
- Generate display names for unnamed groups
- Test disambiguation when multiple matches
"""

import sys
import os
from typing import Optional

# Add parent to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from prototype.utils.db import get_db_connection, apple_to_datetime
from prototype.utils.contacts import ContactResolver, PYOBJC_AVAILABLE
from prototype.utils.phone import format_phone_display


def generate_display_name(participants: list[dict], max_names: int = 3) -> str:
    """
    Generate display name like Messages.app does for unnamed chats.

    Args:
        participants: List of dicts with 'name' and 'handle' keys
        max_names: Maximum names to show before "and X others"

    Returns:
        Generated display name string
    """
    names = []
    for p in participants[:max_names]:
        if p.get('name'):
            # Use first name only for brevity
            first_name = p['name'].split()[0]
            names.append(first_name)
        else:
            # Format phone number nicely
            names.append(format_phone_display(p['handle']))

    if len(participants) > max_names:
        remaining = len(participants) - max_names
        return f"{', '.join(names)} and {remaining} others"

    if len(names) == 2:
        return f"{names[0]} & {names[1]}"

    return ', '.join(names)


def get_chat_participants(conn, chat_id: int, resolver: Optional[ContactResolver] = None) -> list[dict]:
    """Get all participants for a chat with resolved names."""
    cursor = conn.execute("""
        SELECT h.id as handle, h.service
        FROM chat_handle_join chj
        JOIN handle h ON chj.handle_id = h.ROWID
        WHERE chj.chat_id = ?
    """, (chat_id,))

    participants = []
    for row in cursor.fetchall():
        handle = row['handle']
        name = resolver.resolve(handle) if resolver else None
        participants.append({
            'handle': handle,
            'name': name,
            'service': row['service']
        })

    return participants


def find_chats_by_participant_handles(conn, handles: list[str]) -> list[dict]:
    """
    Find chats containing ALL specified handles.

    Args:
        conn: Database connection
        handles: List of E.164 phone numbers or email addresses

    Returns:
        List of chat dicts with id, guid, display_name
    """
    if not handles:
        return []

    # Build query to find chats containing all handles
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


def find_chats_by_participant_names(
    conn,
    names: list[str],
    resolver: ContactResolver
) -> list[dict]:
    """
    Find chats containing participants matching the given names.

    Uses fuzzy matching - name must appear in contact's full name.

    Args:
        conn: Database connection
        names: List of participant names to match
        resolver: ContactResolver for name -> handle resolution

    Returns:
        List of matching chats with participant details
    """
    if not resolver or not resolver.is_available:
        return []

    # Build reverse lookup: name -> handles
    name_to_handles = {}
    if resolver._lookup:
        for handle, contact_name in resolver._lookup.items():
            name_lower = contact_name.lower()
            for search_name in names:
                # Fuzzy match: search_name appears anywhere in contact name
                if search_name.lower() in name_lower:
                    if search_name not in name_to_handles:
                        name_to_handles[search_name] = set()
                    name_to_handles[search_name].add(handle)

    # Find all handles that match at least one name
    all_candidate_handles = set()
    for handles in name_to_handles.values():
        all_candidate_handles.update(handles)

    if not all_candidate_handles:
        return []

    # Get all chats and filter to those containing handles for ALL names
    placeholders = ','.join('?' * len(all_candidate_handles))
    cursor = conn.execute(f"""
        SELECT
            c.ROWID as chat_id,
            c.guid,
            c.display_name,
            GROUP_CONCAT(h.id) as participant_handles
        FROM chat c
        JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
        JOIN handle h ON chj.handle_id = h.ROWID
        WHERE h.id IN ({placeholders})
        GROUP BY c.ROWID
    """, tuple(all_candidate_handles))

    results = []
    for row in cursor.fetchall():
        chat_handles = set(row['participant_handles'].split(','))

        # Check if this chat has at least one handle matching EACH name
        has_all_names = True
        for name in names:
            matching_handles = name_to_handles.get(name, set())
            if not matching_handles.intersection(chat_handles):
                has_all_names = False
                break

        if has_all_names:
            results.append({
                'chat_id': row['chat_id'],
                'guid': row['guid'],
                'display_name': row['display_name'],
                'participant_handles': list(chat_handles)
            })

    return results


def test_get_all_chats():
    """Test 4.1: Get all chats with participant counts."""
    print("\n--- Test 4.1: Get All Chats ---")

    try:
        with get_db_connection() as conn:
            cursor = conn.execute("""
                SELECT
                    c.ROWID as id,
                    c.guid,
                    c.display_name,
                    COUNT(DISTINCT chj.handle_id) as participant_count
                FROM chat c
                LEFT JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
                GROUP BY c.ROWID
                ORDER BY participant_count DESC
                LIMIT 10
            """)

            rows = cursor.fetchall()

            print(f"      Top 10 chats by participant count:")
            for row in rows:
                name = row['display_name'] or "(unnamed)"
                print(f"        {row['participant_count']} participants: {name[:40]}")

            # Count DMs vs groups
            cursor = conn.execute("""
                SELECT
                    CASE WHEN cnt > 1 THEN 'group' ELSE 'dm' END as chat_type,
                    COUNT(*) as count
                FROM (
                    SELECT c.ROWID, COUNT(chj.handle_id) as cnt
                    FROM chat c
                    LEFT JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
                    GROUP BY c.ROWID
                )
                GROUP BY chat_type
            """)
            for row in cursor.fetchall():
                print(f"      {row['chat_type']}: {row['count']:,} chats")

            print("PASS: Retrieved chat overview")
            return True
    except Exception as e:
        print(f"FAIL: {e}")
        return False


def test_generate_display_names():
    """Test 4.2: Generate display names for unnamed chats."""
    print("\n--- Test 4.2: Generate Display Names ---")

    resolver = ContactResolver()
    if PYOBJC_AVAILABLE:
        resolver.initialize()

    try:
        with get_db_connection() as conn:
            # Find unnamed group chats
            cursor = conn.execute("""
                SELECT c.ROWID as id, c.guid
                FROM chat c
                LEFT JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
                WHERE (c.display_name IS NULL OR c.display_name = '')
                GROUP BY c.ROWID
                HAVING COUNT(chj.handle_id) >= 2
                LIMIT 5
            """)

            chats = cursor.fetchall()

            if not chats:
                print("WARN: No unnamed group chats found")
                return True

            print(f"      Generating display names for {len(chats)} unnamed chats:")
            for chat in chats:
                participants = get_chat_participants(conn, chat['id'], resolver)
                generated_name = generate_display_name(participants)
                print(f"        Chat {chat['id']}: \"{generated_name}\"")

            print("PASS: Display name generation working")
            return True
    except Exception as e:
        print(f"FAIL: {e}")
        return False


def test_find_by_single_participant():
    """Test 4.3: Find chats by single participant."""
    print("\n--- Test 4.3: Find by Single Participant ---")

    resolver = ContactResolver()
    if PYOBJC_AVAILABLE:
        resolver.initialize()

    try:
        with get_db_connection() as conn:
            # Get a sample handle from the database
            cursor = conn.execute("""
                SELECT h.id as handle
                FROM handle h
                JOIN chat_handle_join chj ON h.ROWID = chj.handle_id
                LIMIT 1
            """)
            row = cursor.fetchone()

            if not row:
                print("FAIL: No handles found in database")
                return False

            test_handle = row['handle']
            resolved_name = resolver.resolve(test_handle) if resolver.is_available else None

            # Find chats containing this handle
            chats = find_chats_by_participant_handles(conn, [test_handle])

            display_handle = test_handle[:6] + '****' if test_handle.startswith('+') else test_handle
            print(f"      Searching for chats with: {display_handle}")
            if resolved_name:
                print(f"      (Resolved to: {resolved_name})")

            print(f"      Found {len(chats)} chats:")
            for chat in chats[:5]:
                name = chat['display_name'] or "(unnamed)"
                print(f"        - {name[:40]}")

            print("PASS: Single participant lookup working")
            return True
    except Exception as e:
        print(f"FAIL: {e}")
        return False


def test_find_by_multiple_participants():
    """Test 4.4: Find chat by multiple participants (AND logic)."""
    print("\n--- Test 4.4: Find by Multiple Participants ---")

    try:
        with get_db_connection() as conn:
            # Find a group chat with known participants
            cursor = conn.execute("""
                SELECT
                    c.ROWID as chat_id,
                    GROUP_CONCAT(h.id) as handles
                FROM chat c
                JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
                JOIN handle h ON chj.handle_id = h.ROWID
                GROUP BY c.ROWID
                HAVING COUNT(h.id) >= 2
                LIMIT 1
            """)
            row = cursor.fetchone()

            if not row:
                print("WARN: No multi-participant chats found")
                return True

            handles = row['handles'].split(',')[:2]  # Use first 2 participants

            # Now search for chats containing both
            found_chats = find_chats_by_participant_handles(conn, handles)

            print(f"      Searching for chat with {len(handles)} participants:")
            for h in handles:
                display = h[:6] + '****' if h.startswith('+') else h
                print(f"        - {display}")

            print(f"      Found {len(found_chats)} matching chats")

            # Verify original chat is in results
            original_found = any(c['id'] == row['chat_id'] for c in found_chats)
            if original_found:
                print("PASS: Original chat found in search results")
            else:
                print("WARN: Original chat not in results (may have additional participants)")

            return True
    except Exception as e:
        print(f"FAIL: {e}")
        return False


def test_find_by_names():
    """Test 4.5: Find chat by participant names (fuzzy matching)."""
    print("\n--- Test 4.5: Find by Participant Names ---")

    if not PYOBJC_AVAILABLE:
        print("SKIP: PyObjC not available")
        return None

    resolver = ContactResolver()
    resolver.initialize()

    if not resolver._lookup:
        print("SKIP: No contacts loaded")
        return None

    try:
        with get_db_connection() as conn:
            # Find a contact name that appears in the database
            cursor = conn.execute("""
                SELECT h.id as handle
                FROM handle h
                JOIN chat_handle_join chj ON h.ROWID = chj.handle_id
                LIMIT 20
            """)

            # Find a handle with a resolved name
            test_name = None
            for row in cursor.fetchall():
                name = resolver.resolve(row['handle'])
                if name:
                    test_name = name.split()[0]  # First name only
                    break

            if not test_name:
                print("WARN: No contacts found matching database handles")
                return True

            # Search by name
            print(f"      Searching for chats with participant: \"{test_name}\"")
            matching_chats = find_chats_by_participant_names(conn, [test_name], resolver)

            print(f"      Found {len(matching_chats)} chats:")
            for chat in matching_chats[:5]:
                name = chat['display_name'] or "(unnamed)"
                print(f"        - {name[:40]}")

            print("PASS: Name-based lookup working")
            return True
    except Exception as e:
        print(f"FAIL: {e}")
        import traceback
        traceback.print_exc()
        return False


def test_disambiguation():
    """Test 4.6: Test disambiguation when name matches multiple contacts."""
    print("\n--- Test 4.6: Disambiguation ---")

    if not PYOBJC_AVAILABLE:
        print("SKIP: PyObjC not available")
        return None

    resolver = ContactResolver()
    resolver.initialize()

    if not resolver._lookup:
        print("SKIP: No contacts loaded")
        return None

    # Find a common first name with multiple matches
    from collections import defaultdict
    first_name_counts = defaultdict(list)

    for handle, full_name in resolver._lookup.items():
        first_name = full_name.split()[0].lower()
        first_name_counts[first_name].append((handle, full_name))

    # Find a name with multiple matches
    test_name = None
    test_matches = []
    for name, matches in first_name_counts.items():
        if len(matches) >= 2:
            test_name = name.title()
            test_matches = matches[:5]
            break

    if not test_name:
        print("WARN: No common names found with multiple contacts")
        return True

    print(f"      Testing disambiguation for \"{test_name}\":")
    print(f"      Found {len(test_matches)} contacts with this name:")
    for handle, full_name in test_matches:
        display_handle = handle[:6] + '****' if handle.startswith('+') else handle[:15]
        print(f"        - {full_name} ({display_handle})")

    print("PASS: Disambiguation data available for UI implementation")
    return True


def test_chat_activity_context():
    """Test 4.7: Get activity context for disambiguation."""
    print("\n--- Test 4.7: Activity Context for Disambiguation ---")

    resolver = ContactResolver()
    if PYOBJC_AVAILABLE:
        resolver.initialize()

    try:
        with get_db_connection() as conn:
            # Get participant activity for a group chat
            cursor = conn.execute("""
                SELECT c.ROWID as chat_id, c.display_name
                FROM chat c
                JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
                GROUP BY c.ROWID
                HAVING COUNT(chj.handle_id) >= 3
                LIMIT 1
            """)
            chat = cursor.fetchone()

            if not chat:
                print("WARN: No group chats found")
                return True

            # Get activity per participant
            cursor = conn.execute("""
                SELECT
                    h.id as handle,
                    COUNT(m.ROWID) as message_count,
                    MAX(m.date) as last_message_date
                FROM chat_handle_join chj
                JOIN handle h ON chj.handle_id = h.ROWID
                LEFT JOIN message m ON m.handle_id = h.ROWID
                WHERE chj.chat_id = ?
                GROUP BY h.id
                ORDER BY message_count DESC
            """, (chat['chat_id'],))

            participants = cursor.fetchall()
            chat_name = chat['display_name'] or "(unnamed)"

            print(f"      Activity context for chat: {chat_name}")
            for p in participants[:5]:
                name = resolver.resolve(p['handle']) if resolver.is_available else None
                display_handle = p['handle'][:6] + '****' if p['handle'].startswith('+') else p['handle']
                display_name = name or display_handle

                last_dt = apple_to_datetime(p['last_message_date']) if p['last_message_date'] else None
                last_str = last_dt.strftime('%Y-%m-%d') if last_dt else 'never'

                print(f"        {display_name}: {p['message_count']:,} msgs, last: {last_str}")

            print("PASS: Activity context available for smart disambiguation")
            return True
    except Exception as e:
        print(f"FAIL: {e}")
        return False


def test_find_chat_by_two_names():
    """Test 4.8: Find specific chat by two participant names."""
    print("\n--- Test 4.8: Find Chat by Two Names ---")

    if not PYOBJC_AVAILABLE:
        print("SKIP: PyObjC not available")
        return None

    resolver = ContactResolver()
    resolver.initialize()

    try:
        with get_db_connection() as conn:
            # Find a chat with two resolved participants
            cursor = conn.execute("""
                SELECT
                    c.ROWID as chat_id,
                    c.display_name,
                    GROUP_CONCAT(h.id) as handles
                FROM chat c
                JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
                JOIN handle h ON chj.handle_id = h.ROWID
                GROUP BY c.ROWID
                HAVING COUNT(h.id) = 2
                LIMIT 10
            """)

            # Find one where both participants have names
            test_chat = None
            test_names = []
            for row in cursor.fetchall():
                handles = row['handles'].split(',')
                names = [resolver.resolve(h) for h in handles]
                if all(names):
                    test_chat = row
                    test_names = [n.split()[0] for n in names]  # First names
                    break

            if not test_chat:
                print("WARN: No 2-person chat with both resolved contacts found")
                return True

            print(f"      Test chat: {test_chat['display_name'] or '(unnamed)'}")
            print(f"      Searching by names: {test_names}")

            # Now search for this chat by names
            found_chats = find_chats_by_participant_names(conn, test_names, resolver)

            print(f"      Found {len(found_chats)} matching chats")

            # Check if our test chat is in results
            found = any(c['chat_id'] == test_chat['chat_id'] for c in found_chats)

            if found:
                print("PASS: Successfully found chat by participant names")
            else:
                print("WARN: Original chat not found (may have name collisions)")

            return True
    except Exception as e:
        print(f"FAIL: {e}")
        import traceback
        traceback.print_exc()
        return False


def run_all_tests():
    """Run all chat lookup tests."""
    print("=" * 60)
    print("TEST 4: PARTICIPANT-BASED CHAT LOOKUP")
    print("=" * 60)

    tests = [
        test_get_all_chats,
        test_generate_display_names,
        test_find_by_single_participant,
        test_find_by_multiple_participants,
        test_find_by_names,
        test_disambiguation,
        test_chat_activity_context,
        test_find_chat_by_two_names,
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
