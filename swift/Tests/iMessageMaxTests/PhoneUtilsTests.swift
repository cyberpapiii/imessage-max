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

    // Known bug: a 10-digit number after an explicit "+" hits the US branch
    // before the hasPlus branch and is rewritten to +1. Plan 043 fixes this;
    // its executor must remove the strict expected-failure wrapper.
    func testShortInternationalWithPlusIsNotRewrittenToUS() {
        XCTExpectFailure("10 digits after '+' are rewritten to +1; fixed by plan 043", strict: true)
        XCTAssertEqual(PhoneUtils.normalizeToE164("+4512345678"), "+4512345678", "Denmark")
        XCTAssertEqual(PhoneUtils.normalizeToE164("+6591234567"), "+6591234567", "Singapore")
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

    func testIsEmail() {
        XCTAssertTrue(PhoneUtils.isEmail("a@b.co"))
        XCTAssertFalse(PhoneUtils.isEmail("a@b"))
        XCTAssertFalse(PhoneUtils.isEmail("ab.co"))
    }
}
