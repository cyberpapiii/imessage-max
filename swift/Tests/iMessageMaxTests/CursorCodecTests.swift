import XCTest
@testable import iMessageMax

/// Characterization tests for the two keyset cursor codecs. Cursors are opaque
/// to agents but round-trip through them verbatim, so the wire format is pinned.
final class CursorCodecTests: XCTestCase {

    // MARK: - TimelineCursor

    func testTimelineCursorRoundTrip() {
        let encoded = TimelineCursor.encode(date: 123, messageId: 456)
        XCTAssertEqual(encoded, "123:456")
        XCTAssertEqual(TimelineCursor.decode("123:456"), TimelineCursor(date: 123, messageId: 456))
    }

    func testTimelineCursorNilDateEncodesNil() {
        XCTAssertNil(TimelineCursor.encode(date: nil, messageId: 1))
    }

    func testTimelineCursorDecodeRejectsMalformed() {
        for raw in ["123", "a:b", "1:2:3", ""] {
            XCTAssertNil(TimelineCursor.decode(raw), "raw: \(String(reflecting: raw))")
        }
    }

    func testTimelineCursorSQLFragments() {
        let cursor = TimelineCursor(date: 123, messageId: 456)

        XCTAssertEqual(cursor.olderThanSQL, "(m.date < ? OR (m.date = ? AND m.ROWID < ?))")
        XCTAssertEqual(cursor.olderThanParams.compactMap { $0 as? Int64 }, [123, 123, 456])

        XCTAssertEqual(cursor.newerThanSQL, "(m.date > ? OR (m.date = ? AND m.ROWID > ?))")
        XCTAssertEqual(cursor.newerThanParams.compactMap { $0 as? Int64 }, [123, 123, 456])
    }

    // MARK: - ChatListCursor

    func testChatListCursorTwoAndThreePartRoundTrip() {
        let twoPart = ChatListCursor.encode(primary: 10, secondary: nil, chatId: 5)
        XCTAssertEqual(twoPart, "10:5")
        XCTAssertEqual(
            ChatListCursor.decode("10:5"),
            ChatListCursor(primary: 10, secondary: nil, chatId: 5)
        )

        let threePart = ChatListCursor.encode(primary: 10, secondary: 20, chatId: 5)
        XCTAssertEqual(threePart, "10:20:5")
        XCTAssertEqual(
            ChatListCursor.decode("10:20:5"),
            ChatListCursor(primary: 10, secondary: 20, chatId: 5)
        )
    }

    func testChatListCursorNameWithColonsRoundTrips() throws {
        let encoded = ChatListCursor.encodeName(name: "Team: Ops: 2026", chatId: 7)
        XCTAssertEqual(encoded, "n:Team: Ops: 2026:7")

        let decoded = try XCTUnwrap(ChatListCursor.decodeName(encoded))
        XCTAssertEqual(decoded.name, "Team: Ops: 2026")
        XCTAssertEqual(decoded.chatId, 7)

        XCTAssertNil(ChatListCursor.decode(encoded), "name cursors are not numeric cursors")
    }

    func testChatListCursorDecodeRejectsMalformed() {
        for raw in ["x:y", "1:2:3:4"] {
            XCTAssertNil(ChatListCursor.decode(raw), "raw: \(raw)")
        }
        for raw in ["n:", "n:name"] {
            XCTAssertNil(ChatListCursor.decodeName(raw), "raw: \(raw)")
            XCTAssertNil(ChatListCursor.decode(raw), "raw: \(raw)")
        }
    }
}
