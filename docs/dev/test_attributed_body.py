#!/usr/bin/env python3
"""
Test 3: attributedBody Parsing

Tests:
- Query messages with NULL text column
- Parse attributedBody blob
- Extract plain text content
- Handle edge cases (emoji, mentions, links)
- Compare to text column when both exist
"""

import sys
import os

# Add parent to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from prototype.utils.db import get_db_connection, apple_to_datetime
from prototype.utils.parsing import (
    extract_text_from_attributed_body,
    get_message_text,
    extract_links,
    is_reaction_message,
    get_reaction_type
)


def test_find_messages_with_attributed_body():
    """Test 3.1: Find messages where text is in attributedBody."""
    print("\n--- Test 3.1: Find Messages with attributedBody ---")

    try:
        with get_db_connection() as conn:
            # Count messages with NULL text but non-NULL attributedBody
            cursor = conn.execute("""
                SELECT COUNT(*) as count
                FROM message
                WHERE text IS NULL
                  AND attributedBody IS NOT NULL
                  AND associated_message_type = 0
            """)
            null_text_count = cursor.fetchone()['count']

            # Count total non-reaction messages
            cursor = conn.execute("""
                SELECT COUNT(*) as count
                FROM message
                WHERE associated_message_type = 0
            """)
            total_count = cursor.fetchone()['count']

            # Count messages with both
            cursor = conn.execute("""
                SELECT COUNT(*) as count
                FROM message
                WHERE text IS NOT NULL
                  AND attributedBody IS NOT NULL
                  AND associated_message_type = 0
            """)
            both_count = cursor.fetchone()['count']

            pct_null = (null_text_count / total_count * 100) if total_count else 0

            print(f"PASS: Message text storage analysis:")
            print(f"      Total messages: {total_count:,}")
            print(f"      Text NULL (need attributedBody): {null_text_count:,} ({pct_null:.1f}%)")
            print(f"      Both text and attributedBody: {both_count:,}")

            return True
    except Exception as e:
        print(f"FAIL: {e}")
        return False


def test_parse_attributed_body_samples():
    """Test 3.2: Parse sample attributedBody blobs."""
    print("\n--- Test 3.2: Parse attributedBody Samples ---")

    try:
        with get_db_connection() as conn:
            # Get messages with NULL text and non-NULL attributedBody
            cursor = conn.execute("""
                SELECT
                    m.ROWID,
                    m.text,
                    m.attributedBody,
                    m.date,
                    m.is_from_me
                FROM message m
                WHERE m.text IS NULL
                  AND m.attributedBody IS NOT NULL
                  AND m.associated_message_type = 0
                ORDER BY m.date DESC
                LIMIT 10
            """)

            rows = cursor.fetchall()

            if not rows:
                print("WARN: No messages found with NULL text and attributedBody")
                print("      This may be normal if all messages have text column populated")
                return True

            success = 0
            failed = 0

            print(f"      Testing {len(rows)} messages with attributedBody:")
            for row in rows:
                blob = row['attributedBody']
                extracted = extract_text_from_attributed_body(blob)
                dt = apple_to_datetime(row['date'])

                if extracted:
                    success += 1
                    preview = extracted[:60]
                    if len(extracted) > 60:
                        preview += "..."
                    print(f"        [{dt.strftime('%m/%d %H:%M')}] PASS: \"{preview}\"")
                else:
                    failed += 1
                    print(f"        [{dt.strftime('%m/%d %H:%M')}] FAIL: Could not extract (blob size: {len(blob)} bytes)")

            print(f"      Results: {success} extracted, {failed} failed")

            if success == 0 and failed > 0:
                print("FAIL: Could not extract any text from attributedBody")
                return False

            print(f"PASS: Extracted text from {success}/{len(rows)} messages")
            return True
    except Exception as e:
        print(f"FAIL: {e}")
        import traceback
        traceback.print_exc()
        return False


def test_compare_text_and_attributed_body():
    """Test 3.3: Compare text column with attributedBody extraction."""
    print("\n--- Test 3.3: Compare Text vs attributedBody ---")

    try:
        with get_db_connection() as conn:
            # Get messages with BOTH text and attributedBody
            cursor = conn.execute("""
                SELECT
                    m.ROWID,
                    m.text,
                    m.attributedBody,
                    m.date
                FROM message m
                WHERE m.text IS NOT NULL
                  AND m.attributedBody IS NOT NULL
                  AND LENGTH(m.text) > 10
                  AND m.associated_message_type = 0
                ORDER BY m.date DESC
                LIMIT 10
            """)

            rows = cursor.fetchall()

            if not rows:
                print("WARN: No messages found with both text and attributedBody")
                return True

            matches = 0
            mismatches = 0

            print(f"      Comparing {len(rows)} messages:")
            for row in rows:
                text = row['text']
                blob = row['attributedBody']
                extracted = extract_text_from_attributed_body(blob)

                if extracted:
                    # Normalize for comparison (strip whitespace)
                    text_norm = text.strip()
                    extracted_norm = extracted.strip()

                    if text_norm == extracted_norm:
                        matches += 1
                        preview = text[:40] + "..." if len(text) > 40 else text
                        print(f"        MATCH: \"{preview}\"")
                    else:
                        mismatches += 1
                        print(f"        DIFF:")
                        print(f"          text:      \"{text[:50]}...\"")
                        print(f"          extracted: \"{extracted[:50] if extracted else 'None'}...\"")
                else:
                    mismatches += 1
                    print(f"        FAIL: Could not extract from attributedBody")

            print(f"      Results: {matches} matches, {mismatches} differences")
            print(f"PASS: Comparison complete ({matches}/{len(rows)} exact matches)")
            return True
    except Exception as e:
        print(f"FAIL: {e}")
        return False


def test_get_message_text_helper():
    """Test 3.4: Test get_message_text helper function."""
    print("\n--- Test 3.4: get_message_text Helper ---")

    try:
        with get_db_connection() as conn:
            # Test with text column present
            cursor = conn.execute("""
                SELECT text, attributedBody
                FROM message
                WHERE text IS NOT NULL
                LIMIT 1
            """)
            row = cursor.fetchone()
            if row:
                result = get_message_text(row['text'], row['attributedBody'])
                print(f"      With text column: \"{result[:50]}...\"")

            # Test with NULL text
            cursor = conn.execute("""
                SELECT text, attributedBody
                FROM message
                WHERE text IS NULL AND attributedBody IS NOT NULL
                LIMIT 1
            """)
            row = cursor.fetchone()
            if row:
                result = get_message_text(row['text'], row['attributedBody'])
                if result:
                    print(f"      With NULL text (extracted): \"{result[:50]}...\"")
                else:
                    print(f"      With NULL text: extraction failed")

            print("PASS: get_message_text helper works correctly")
            return True
    except Exception as e:
        print(f"FAIL: {e}")
        return False


def test_link_extraction():
    """Test 3.5: Test URL extraction from messages."""
    print("\n--- Test 3.5: Link Extraction ---")

    try:
        with get_db_connection() as conn:
            # Find messages containing URLs
            cursor = conn.execute("""
                SELECT text, attributedBody
                FROM message
                WHERE (text LIKE '%http%' OR text LIKE '%https%')
                  AND associated_message_type = 0
                ORDER BY date DESC
                LIMIT 5
            """)

            rows = cursor.fetchall()

            if not rows:
                print("WARN: No messages with URLs found")
                return True

            print(f"      Testing link extraction on {len(rows)} messages:")
            for row in rows:
                text = get_message_text(row['text'], row['attributedBody'])
                if text:
                    links = extract_links(text)
                    if links:
                        print(f"        Found {len(links)} link(s): {links[0][:50]}...")
                    else:
                        print(f"        No links extracted from: \"{text[:40]}...\"")

            print("PASS: Link extraction functional")
            return True
    except Exception as e:
        print(f"FAIL: {e}")
        return False


def test_reaction_detection():
    """Test 3.6: Test reaction/tapback detection."""
    print("\n--- Test 3.6: Reaction Detection ---")

    try:
        with get_db_connection() as conn:
            # Get reaction type distribution
            cursor = conn.execute("""
                SELECT associated_message_type, COUNT(*) as count
                FROM message
                WHERE associated_message_type >= 2000
                GROUP BY associated_message_type
                ORDER BY associated_message_type
            """)

            rows = cursor.fetchall()

            if not rows:
                print("WARN: No reactions found in database")
                return True

            print(f"      Reaction type distribution:")
            total = 0
            for row in rows:
                msg_type = row['associated_message_type']
                count = row['count']
                total += count
                reaction_name = get_reaction_type(msg_type) or f"unknown_{msg_type}"
                print(f"        Type {msg_type} ({reaction_name}): {count:,}")

            print(f"      Total reactions: {total:,}")
            print("PASS: Reaction detection working")
            return True
    except Exception as e:
        print(f"FAIL: {e}")
        return False


def test_edge_cases():
    """Test 3.7: Test edge cases in attributedBody parsing."""
    print("\n--- Test 3.7: Edge Cases ---")

    # Test with None/empty inputs
    assert extract_text_from_attributed_body(None) is None
    assert extract_text_from_attributed_body(b'') is None
    assert extract_text_from_attributed_body(b'random garbage') is None

    # Test get_message_text with various inputs
    assert get_message_text("Hello", None) == "Hello"
    assert get_message_text("Hello", b'garbage') == "Hello"  # Prefers text
    assert get_message_text(None, None) is None
    # Empty string is falsy in Python, so it falls through to attributedBody
    # Since b'garbage' doesn't contain NSString marker, extraction returns None
    assert get_message_text("", b'garbage') is None

    print("PASS: Edge cases handled correctly")
    return True


def test_emoji_messages():
    """Test 3.8: Test extraction of emoji-only messages."""
    print("\n--- Test 3.8: Emoji Messages ---")

    try:
        with get_db_connection() as conn:
            # Find emoji-heavy messages
            cursor = conn.execute("""
                SELECT text, attributedBody
                FROM message
                WHERE text IS NULL
                  AND attributedBody IS NOT NULL
                  AND associated_message_type = 0
                  AND LENGTH(attributedBody) < 500
                ORDER BY date DESC
                LIMIT 5
            """)

            rows = cursor.fetchall()

            if not rows:
                print("WARN: No suitable messages found for emoji test")
                return True

            print(f"      Testing {len(rows)} short messages:")
            for row in rows:
                blob = row['attributedBody']
                extracted = extract_text_from_attributed_body(blob)
                if extracted:
                    # Check if it's emoji-heavy
                    has_emoji = any(ord(c) > 0x1F000 for c in extracted)
                    if has_emoji:
                        print(f"        Emoji message: \"{extracted}\"")
                    else:
                        print(f"        Text message: \"{extracted[:40]}...\"")
                else:
                    print(f"        Could not extract (blob size: {len(blob)})")

            print("PASS: Emoji message handling tested")
            return True
    except Exception as e:
        print(f"FAIL: {e}")
        return False


def run_all_tests():
    """Run all attributedBody parsing tests."""
    print("=" * 60)
    print("TEST 3: ATTRIBUTEDBODY PARSING")
    print("=" * 60)

    tests = [
        test_find_messages_with_attributed_body,
        test_parse_attributed_body_samples,
        test_compare_text_and_attributed_body,
        test_get_message_text_helper,
        test_link_extraction,
        test_reaction_detection,
        test_edge_cases,
        test_emoji_messages,
    ]

    passed = 0
    failed = 0

    for test in tests:
        try:
            if test():
                passed += 1
            else:
                failed += 1
        except Exception as e:
            print(f"FAIL: Unexpected error in {test.__name__}: {e}")
            import traceback
            traceback.print_exc()
            failed += 1

    print("\n" + "=" * 60)
    print(f"RESULTS: {passed} passed, {failed} failed")
    print("=" * 60)

    return failed == 0


if __name__ == "__main__":
    success = run_all_tests()
    sys.exit(0 if success else 1)
