import XCTest
@testable import iMessageMax

final class LogTests: XCTestCase {
    func testFormatIsStable() {
        XCTAssertEqual(
            Log.format(.info, "Database: ok"),
            "[imessage-max] INFO Database: ok\n"
        )
        XCTAssertEqual(
            Log.format(.warning, "Binding to '0.0.0.0'"),
            "[imessage-max] WARN Binding to '0.0.0.0'\n"
        )
        XCTAssertEqual(
            Log.format(.error, "session Server.start failed: boom"),
            "[imessage-max] ERROR session Server.start failed: boom\n"
        )
    }
}
