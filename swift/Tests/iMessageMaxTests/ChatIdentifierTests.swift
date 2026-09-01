import XCTest
@testable import iMessageMax

final class ChatIdentifierTests: XCTestCase {

    func testNumericRowId() {
        XCTAssertEqual(ChatIdentifier.parseRowId("123"), 123)
        XCTAssertEqual(ChatIdentifier.parseRowId("20"), 20)
    }

    func testChatPrefix() {
        XCTAssertEqual(ChatIdentifier.parseRowId("chat123"), 123)
        XCTAssertEqual(ChatIdentifier.parseRowId("chat20"), 20)
    }

    func testWhitespace() {
        XCTAssertEqual(ChatIdentifier.parseRowId("  123  "), 123)
        XCTAssertEqual(ChatIdentifier.parseRowId("  chat123  "), 123)
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(ChatIdentifier.parseRowId(""))
        XCTAssertNil(ChatIdentifier.parseRowId("   "))
        XCTAssertNil(ChatIdentifier.parseRowId("abc"))
        XCTAssertNil(ChatIdentifier.parseRowId("chat"))
        XCTAssertNil(ChatIdentifier.parseRowId("chatABC"))
        XCTAssertNil(ChatIdentifier.parseRowId("iMessage;-;chat123"))
    }
}
