import Foundation
import XCTest
@testable import iMessageMax

/// Characterization tests for `AppleTime.parse`, the `since`/`before` parser
/// shared by get_messages, search, get_unread, list_attachments, and list_chats.
/// Every caller drops the filter silently when this returns nil, so the exact
/// set of accepted inputs is behaviour an agent can observe.
final class AppleTimeParseTests: XCTestCase {

    private let tolerance: TimeInterval = 2

    /// Round-trips the Apple-epoch nanoseconds back into a Date.
    private func parsedDate(_ input: String, file: StaticString = #filePath, line: UInt = #line) throws -> Date {
        let ns = try XCTUnwrap(AppleTime.parse(input), "\(input) should parse", file: file, line: line)
        return try XCTUnwrap(AppleTime.toDate(ns), file: file, line: line)
    }

    func testRelativeUnits() throws {
        let table: [(input: String, seconds: TimeInterval)] = [
            ("1h", 3600),
            ("24h", 86400),
            ("7d", 604800),
            ("2w", 1209600),
            ("1m", 2592000),
        ]
        for (input, seconds) in table {
            let expected = Date().addingTimeInterval(-seconds)
            let actual = try parsedDate(input)
            XCTAssertEqual(
                actual.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: tolerance,
                "\(input) should be \(seconds)s before now"
            )
        }
    }

    func testISO8601WithAndWithoutFractionalSeconds() throws {
        let plain = "2026-01-15T10:30:00Z"
        let fractional = "2026-01-15T10:30:00.500Z"

        let plainDate = try parsedDate(plain)
        XCTAssertNotNil(AppleTime.parse(fractional), "\(fractional) should parse")

        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: plain))
        XCTAssertEqual(plainDate, expected, "ISO input without fractional seconds must round-trip exactly")
    }

    func testNaturalKeywords() throws {
        let keywords = [
            "yesterday", "today",
            "this week", "this month", "this year",
            "last week", "last month", "last year",
        ]
        for keyword in keywords {
            XCTAssertNotNil(AppleTime.parse(keyword), "\(keyword) should parse")
        }

        let today = try parsedDate("today")
        let startOfDay = Calendar.current.startOfDay(for: Date())
        XCTAssertEqual(
            today.timeIntervalSince1970, startOfDay.timeIntervalSince1970, accuracy: tolerance,
            "today should be the start of the current day"
        )
    }

    func testNDaysAgo() throws {
        for input in ["3 days ago", "2 weeks ago", "1 month ago"] {
            let date = try parsedDate(input)
            XCTAssertLessThan(date, Date(), "\(input) should be in the past")
        }
    }

    func testLastWeekday() throws {
        let weekdays: [(name: String, weekday: Int)] = [
            ("sunday", 1), ("monday", 2), ("tuesday", 3), ("wednesday", 4),
            ("thursday", 5), ("friday", 6), ("saturday", 7),
        ]
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for (name, weekday) in weekdays {
            let input = "last \(name)"
            let date = try parsedDate(input)
            XCTAssertEqual(
                calendar.component(.weekday, from: date), weekday,
                "\(input) should land on a \(name)"
            )
            let daysBack = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? -1
            XCTAssertTrue((1...7).contains(daysBack), "\(input) should be 1-7 days back, got \(daysBack)")
        }
    }

    func testCaseAndWhitespaceInsensitiveNatural() throws {
        let padded = try parsedDate("  Yesterday ")
        let plain = try parsedDate("yesterday")
        XCTAssertEqual(
            padded.timeIntervalSince1970, plain.timeIntervalSince1970, accuracy: tolerance,
            "the natural parser lowercases and trims its input"
        )
    }

    func testGarbageReturnsNil() {
        for input in ["", "soon", "24 hours", "h24", "2026-13-45"] {
            XCTAssertNil(AppleTime.parse(input), "\(String(reflecting: input)) should not parse")
        }
    }

    func testHugeRelativeValueDoesNotTrap() {
        for input in ["999999999h", "99999999999d", "9999-01-01T00:00:00Z", "0001-01-01T00:00:00Z", "999999999 days ago"] {
            let result = AppleTime.parse(input)
            // Either nil (rejected) or a finite Int64; the point is no trap.
            if let result {
                XCTAssertTrue(result <= Int64.max && result >= Int64.min, input)
            }
        }
        // A relative bound is capped at 100 years, not dropped.
        let capped = try? XCTUnwrap(AppleTime.parse("999999999h"))
        XCTAssertNotNil(capped)
    }
}
