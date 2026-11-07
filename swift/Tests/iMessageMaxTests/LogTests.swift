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
        XCTAssertEqual(
            Log.format(.info, "Database: ok", at: Date(timeIntervalSince1970: 1_790_000_000.25)),
            "2026-09-21T14:13:20.250Z [imessage-max] INFO Database: ok\n"
        )
    }

    func testRedirectAppendsStandardErrorToANewDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-redirect-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("iMessage Max/imessage-max.log")
        let saved = dup(STDERR_FILENO)
        defer {
            dup2(saved, STDERR_FILENO)
            close(saved)
        }
        try Log.redirectStandardError(to: file.path)
        FileHandle.standardError.write(Data("first\n".utf8))
        try Log.redirectStandardError(to: file.path)
        FileHandle.standardError.write(Data("second\n".utf8))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "first\nsecond\n")
    }
}
