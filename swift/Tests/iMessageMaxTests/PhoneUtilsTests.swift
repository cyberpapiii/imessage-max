import XCTest
@testable import iMessageMax

/// Characterization tests for `PhoneUtils`, which normalizes the `to` argument
/// on the send path. A wrong normalization here sends a message to the wrong
/// person, so every branch is pinned.
final class PhoneUtilsTests: XCTestCase {

    func testTenDigitUSNumberGetsCountryCode() {
        for input in ["5551234567", "(555) 123-4567"] {
            XCTAssertEqual(PhoneUtils.normalizeToE164(input), "+15551234567", "input: \(input)")
        }
    }

    func testElevenDigitWithLeadingOne() {
        for input in ["15551234567", "+1 555 123 4567"] {
            XCTAssertEqual(PhoneUtils.normalizeToE164(input), "+15551234567", "input: \(input)")
        }
    }

    func testInternationalWithPlusIsPreserved() {
        XCTAssertEqual(PhoneUtils.normalizeToE164("+447911123456"), "+447911123456")
    }

    // A 10-digit number after an explicit "+" is a foreign subscriber, not a
    // US number missing its +1. Rewriting it to +1 would send to a stranger.
    func testShortInternationalWithPlusIsNotRewrittenToUS() {
        XCTAssertEqual(PhoneUtils.normalizeToE164("+4512345678"), "+4512345678", "Denmark")
        XCTAssertEqual(PhoneUtils.normalizeToE164("+6591234567"), "+6591234567", "Singapore")
    }

    func testOverlongInputReturnsNil() {
        XCTAssertNil(PhoneUtils.normalizeToE164("+" + String(repeating: "5", count: 16)), "16 digits exceeds E.164")
    }

    func testWhitespaceIsIgnored() {
        XCTAssertEqual(PhoneUtils.normalizeToE164("  +4512345678 "), "+4512345678")
    }

    func testEmptyOrNoDigitsReturnsNil() {
        for input in ["", "abc", "+"] {
            XCTAssertNil(PhoneUtils.normalizeToE164(input), "input: \(String(reflecting: input))")
        }
    }

    func testFormatDisplayUS() {
        XCTAssertEqual(PhoneUtils.formatDisplay("+15551234567"), "+1 (555) 123-4567")
        XCTAssertEqual(PhoneUtils.formatDisplay("+447911123456"), "+447911123456")
    }

    func testIsPhoneNumberBounds() {
        XCTAssertTrue(PhoneUtils.isPhoneNumber(String(repeating: "5", count: 10)), "10 digits")
        XCTAssertTrue(PhoneUtils.isPhoneNumber(String(repeating: "5", count: 15)), "15 digits")
        XCTAssertFalse(PhoneUtils.isPhoneNumber(String(repeating: "5", count: 9)), "9 digits")
        XCTAssertFalse(PhoneUtils.isPhoneNumber(String(repeating: "5", count: 16)), "16 digits")
        XCTAssertFalse(PhoneUtils.isPhoneNumber("alice@example.com"), "email")
    }

    func testShortCodesArePhoneNumbersButDoNotNormalize() {
        XCTAssertTrue(PhoneUtils.isPhoneNumber("55555"), "5-digit short code")
        XCTAssertFalse(PhoneUtils.isPhoneNumber("+5555"), "short code with + is not a handle")
        XCTAssertFalse(PhoneUtils.isPhoneNumber("5555"), "4 digits is too short")
        XCTAssertNil(PhoneUtils.normalizeToE164("55555"), "short codes have no E.164 form")
    }

    func testLettersAreNotPhoneNumbers() {
        XCTAssertFalse(PhoneUtils.isPhoneNumber("call 5551234567 now"), "letters present")
        XCTAssertTrue(PhoneUtils.isPhoneNumber("(555) 123-4567"), "punctuation only")
    }

    func testIsEmail() {
        XCTAssertTrue(PhoneUtils.isEmail("a@b.co"))
        XCTAssertFalse(PhoneUtils.isEmail("a@b"))
        XCTAssertFalse(PhoneUtils.isEmail("ab.co"))
    }
}
