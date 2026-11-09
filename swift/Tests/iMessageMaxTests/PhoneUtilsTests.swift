import XCTest
@testable import iMessageMax

final class PhoneUtilsTests: XCTestCase {

    func testTenDigitUSNumberGetsCountryCode() {
        for input in ["5551234567", "(555) 123-4567"] {
            XCTAssertEqual(PhoneUtils.normalizeToE164(input, region: "US"), "+15551234567", "input: \(input)")
        }
    }

    func testElevenDigitWithLeadingOne() {
        for input in ["15551234567", "+1 555 123 4567"] {
            XCTAssertEqual(PhoneUtils.normalizeToE164(input, region: "US"), "+15551234567", "input: \(input)")
        }
    }

    func testInternationalWithPlusIsPreserved() {
        XCTAssertEqual(PhoneUtils.normalizeToE164("+447911123456", region: "US"), "+447911123456")
    }

    func testShortInternationalWithPlusIsNotRewrittenToUS() {
        XCTAssertEqual(PhoneUtils.normalizeToE164("+4512345678", region: "US"), "+4512345678", "Denmark")
        XCTAssertEqual(PhoneUtils.normalizeToE164("+6591234567", region: "US"), "+6591234567", "Singapore")
    }

    func testOverlongInputReturnsNil() {
        XCTAssertNil(PhoneUtils.normalizeToE164("+" + String(repeating: "5", count: 16), region: "US"), "16 digits exceeds E.164")
    }

    func testWhitespaceIsIgnored() {
        XCTAssertEqual(PhoneUtils.normalizeToE164("  +4512345678 ", region: "US"), "+4512345678")
    }

    func testEmptyOrNoDigitsReturnsNil() {
        for input in ["", "abc", "+"] {
            XCTAssertNil(PhoneUtils.normalizeToE164(input, region: "US"), "input: \(String(reflecting: input))")
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
        XCTAssertNil(PhoneUtils.normalizeToE164("55555", region: "US"), "short codes have no E.164 form")
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

    // MARK: - Region-aware normalization (plan 088 #7)

    /// (region, input, expected E.164 or nil). A nil region is a Mac whose
    /// region is unknown.
    private static let regionTable: [(String?, String, String?)] = [
        // United States: +1 only here and in the rest of the NANP.
        ("US", "(555) 123-4567", "+15551234567"),
        ("US", "555.123.4567", "+15551234567"),
        ("US", "1-555-123-4567", "+15551234567"),
        ("US", "+1 555 123 4567", "+15551234567"),
        ("US", "555-123-4567 x89", "+15551234567"),
        ("US", "555-123-4567 ext. 89", "+15551234567"),
        ("US", "(555) 123-4567,,89", "+15551234567"),
        ("US", "+44 20 7946 0958", "+442079460958"),
        ("US", "011 44 20 7946 0958", "+442079460958"),
        ("US", "0044 20 7946 0958", "+442079460958"),
        ("US", "123-4567", nil),
        ("US", "55555", nil),
        // Canada
        ("CA", "416 555 0199", "+14165550199"),
        ("CA", "1 (416) 555-0199", "+14165550199"),
        ("CA", "011 33 6 12 34 56 78", "+33612345678"),
        // United Kingdom
        ("GB", "07911 123456", "+447911123456"),
        ("GB", "020 7946 0958", "+442079460958"),
        ("GB", "+44 (0)20 7946 0958", "+442079460958"),
        ("GB", "+44 7911 123456", "+447911123456"),
        ("GB", "0044 7911 123456", "+447911123456"),
        ("GB", "00 1 555 123 4567", "+15551234567"),
        ("GB", "+1 (555) 123-4567", "+15551234567"),
        ("GB", "020 7946 0958 ext 12", "+442079460958"),
        ("GB", "(555) 123-4567", nil),
        ("GB", "5551234567", nil),
        ("GB", "15551234567", nil),
        ("GB", "7911 123456", nil),
        // Germany
        ("DE", "030 12345678", "+493012345678"),
        ("DE", "0151 23456789", "+4915123456789"),
        ("DE", "030/1234567-89", "+4930123456789"),
        ("DE", "+49 (0)30 1234567", "+49301234567"),
        ("DE", "0049 30 1234567", "+49301234567"),
        ("DE", "5551234567", nil),
        // France
        ("FR", "06 12 34 56 78", "+33612345678"),
        ("FR", "01.23.45.67.89", "+33123456789"),
        ("FR", "+33 (0)6 12 34 56 78", "+33612345678"),
        ("FR", "0033 6 12 34 56 78", "+33612345678"),
        // Australia: international prefix 0011
        ("AU", "0412 345 678", "+61412345678"),
        ("AU", "(02) 9876 5432", "+61298765432"),
        ("AU", "+61 412 345 678", "+61412345678"),
        ("AU", "0011 44 20 7946 0958", "+442079460958"),
        // India: a 10-digit mobile is often written without the trunk 0
        ("IN", "098765 43210", "+919876543210"),
        ("IN", "98765 43210", "+919876543210"),
        ("IN", "+91 98765 43210", "+919876543210"),
        ("IN", "0091 98765 43210", "+919876543210"),
        ("IN", "12345", nil),
        // Brazil: written without the trunk 0, or with a carrier code after it
        ("BR", "(11) 98765-4321", "+5511987654321"),
        ("BR", "(11) 3456-7890", "+551134567890"),
        ("BR", "011 98765-4321", "+5511987654321"),
        ("BR", "0 21 11 98765-4321", "+5511987654321"),
        ("BR", "+55 11 98765-4321", "+5511987654321"),
        ("BR", "0021 44 20 7946 0958", nil),
        // Japan: international prefix 010
        ("JP", "090-1234-5678", "+819012345678"),
        ("JP", "03-1234-5678", "+81312345678"),
        ("JP", "+81 90-1234-5678", "+819012345678"),
        ("JP", "010 1 555 123 4567", "+15551234567"),
        // A region without a trunk prefix keeps the leading 0
        ("IT", "06 1234 5678", "+390612345678"),
        ("IT", "339 123 4567", "+393391234567"),
        // Unknown region: only "+" and "00" are read
        (nil, "07911 123456", nil),
        (nil, "5551234567", nil),
        (nil, "0044 7911 123456", "+447911123456"),
        (nil, "+44 7911 123456", "+447911123456"),
        ("ZZ", "5551234567", nil),
    ]

    func testRegionTable() {
        for (region, input, expected) in Self.regionTable {
            XCTAssertEqual(
                PhoneUtils.normalizeToE164(input, region: region), expected,
                "region \(region ?? "nil"), input \(input)"
            )
        }
    }

    func testRegionIsCaseInsensitive() {
        XCTAssertEqual(PhoneUtils.normalizeToE164("07911 123456", region: "gb"), "+447911123456")
    }

    func testLettersAreNeverReadAsANumber() {
        for region in ["US", "GB", "IT"] {
            XCTAssertNil(PhoneUtils.normalizeToE164("Room 1234567890", region: region), region)
            XCTAssertNil(PhoneUtils.normalizeToE164("1-800-FLOWERS", region: region), region)
        }
    }

    func testDigitsInOtherScriptsAreRead() {
        XCTAssertEqual(PhoneUtils.normalizeToE164("+٤٤ ٧٩١١ ١٢٣٤٥٦", region: "GB"), "+447911123456")
        XCTAssertEqual(PhoneUtils.normalizeToE164("０７９１１ １２３４５６", region: "GB"), "+447911123456")
    }

    func testNANPRegionsAssumePlusOne() {
        for region in ["US", "CA", "PR", "JM"] {
            XCTAssertEqual(PhoneUtils.normalizeToE164("5551234567", region: region), "+15551234567", region)
        }
        for region in ["GB", "DE", "FR", "AU", "JP", "MX"] {
            XCTAssertNotEqual(PhoneUtils.normalizeToE164("5551234567", region: region), "+15551234567", region)
        }
    }

    func testStripExtension() {
        XCTAssertEqual(PhoneUtils.stripExtension("555 1234 x12"), "555 1234 ")
        XCTAssertEqual(PhoneUtils.stripExtension("555 1234 Extension 12"), "555 1234 ")
        XCTAssertEqual(PhoneUtils.stripExtension("5551234;12"), "5551234")
        XCTAssertEqual(PhoneUtils.stripExtension("5551234#12"), "5551234")
        XCTAssertEqual(PhoneUtils.stripExtension("1-800-FLOWERS"), "1-800-FLOWERS")
    }
}
