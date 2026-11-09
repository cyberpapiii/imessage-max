import Foundation
import MCP
import XCTest
@testable import iMessageMax

final class AppleTimeParseTests: XCTestCase {

    private let tolerance: TimeInterval = 2

    private func onOneDay<T>(_ body: (Date) throws -> T) rethrows -> (today: Date, value: T) {
        while true {
            let today = Calendar.current.startOfDay(for: Date())
            let value = try body(today)
            if Calendar.current.startOfDay(for: Date()) == today { return (today, value) }
        }
    }

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
            ("30min", 1800),
            ("3mo", 7776000),
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

        let (startOfDay, today) = try onOneDay { _ in try parsedDate("today") }
        XCTAssertEqual(
            today.timeIntervalSince1970, startOfDay.timeIntervalSince1970, accuracy: tolerance,
            "today should be the start of the current day"
        )

        let (startOfToday, yesterday) = try onOneDay { _ in try parsedDate("yesterday") }
        let startOfYesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: startOfToday))
        XCTAssertEqual(
            yesterday.timeIntervalSince1970, startOfYesterday.timeIntervalSince1970, accuracy: tolerance,
            "yesterday should be the start of the previous day"
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
        let (today, dates) = try onOneDay { _ in
            try weekdays.map { try parsedDate("last \($0.name)") }
        }
        for ((name, weekday), date) in zip(weekdays, dates) {
            let input = "last \(name)"
            XCTAssertEqual(
                calendar.component(.weekday, from: date), weekday,
                "\(input) should land on a \(name)"
            )
            let daysBack = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? -1
            XCTAssertTrue((1...7).contains(daysBack), "\(input) should be 1-7 days back, got \(daysBack)")
        }
    }

    func testCaseAndWhitespaceInsensitiveNatural() throws {
        let (_, (padded, plain)) = try onOneDay { _ in
            (try parsedDate("  Yesterday "), try parsedDate("yesterday"))
        }
        XCTAssertEqual(
            padded.timeIntervalSince1970, plain.timeIntervalSince1970, accuracy: tolerance,
            "the natural parser lowercases and trims its input"
        )
    }

    func testGarbageReturnsNil() {
        for input in ["", "soon", "24 hours", "h24", "2026-13-45", "30m", "1m"] {
            XCTAssertNil(AppleTime.parse(input), "\(String(reflecting: input)) should not parse")
        }
    }

    func testEveryTimeBoundToolRefusesABareM() async throws {
        let fixture = try ToolTestDatabase(name: "bare-m")
        let db = fixture.database()
        let calls: [(tool: String, arguments: [String: Value])] = [
            ("search", ["query": "x", "since": "30m"]),
            ("search", ["query": "x", "before": "30m"]),
            ("get_messages", ["chat_id": "chat1", "since": "30m"]),
            ("list_chats", ["since": "30m"]),
            ("list_attachments", ["before": "30m"]),
            ("get_unread", ["since": "30m"]),
        ]
        for (tool, arguments) in calls {
            let body = try await callTool(tool, arguments, database: db)
            XCTAssertEqual(body["error"] as? String, "validation_error", "\(tool) \(arguments)")
            let message = body["message"] as? String ?? ""
            XCTAssertTrue(message.contains("\"30min\"") && message.contains("\"30mo\""), "\(tool): \(message)")
        }
    }

    func testUnparseableTimeBoundIsAnErrorNotAnIgnoredFilter() async throws {
        let fixture = try ToolTestDatabase(name: "bad-bound")
        let db = fixture.database()
        let body = try await callTool("list_chats", ["since": "soon"], database: db)
        XCTAssertEqual(body["error"] as? String, "validation_error")
        XCTAssertTrue((body["message"] as? String ?? "").contains("30min"))

        let all = try await callTool("get_unread", ["since": "all"], database: db)
        XCTAssertNil(all["error"], "get_unread keeps its all-time keyword")
    }

    func testHugeRelativeValueDoesNotTrap() {
        for input in ["999999999h", "99999999999d", "9999-01-01T00:00:00Z", "0001-01-01T00:00:00Z", "999999999 days ago"] {
            _ = AppleTime.parse(input)
        }
        XCTAssertNotNil(AppleTime.parse("999999999h"))
    }
}
