import XCTest
@testable import iMessageMax

final class LogTests: XCTestCase {
    func testFormatIsStable() {
        let epoch = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(
            Log.format(.info, "Database: ok", at: epoch),
            "1970-01-01T00:00:00.000Z [imessage-max] INFO Database: ok\n"
        )
        XCTAssertEqual(
            Log.format(.warning, "Binding to '0.0.0.0'", at: epoch),
            "1970-01-01T00:00:00.000Z [imessage-max] WARN Binding to '0.0.0.0'\n"
        )
        XCTAssertEqual(
            Log.format(.error, "session Server.start failed: boom", at: epoch),
            "1970-01-01T00:00:00.000Z [imessage-max] ERROR session Server.start failed: boom\n"
        )
    }
}
