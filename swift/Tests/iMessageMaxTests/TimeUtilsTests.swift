import XCTest
@testable import iMessageMax

final class TimeUtilsTests: XCTestCase {
    func testOldDateFormatsAsEnglishMonthDay() throws {
        let date = Date().addingTimeInterval(-30 * 24 * 3600)
        let formatted = try XCTUnwrap(TimeUtils.formatCompactRelative(date))
        XCTAssertNotNil(
            formatted.range(of: #"^[A-Z][a-z]{2} \d{1,2}$"#, options: .regularExpression),
            "expected English month-day, got \(formatted)"
        )
    }
}
