import XCTest
@testable import iMessageMax

final class ClientErrorSanitizationTests: XCTestCase {

    private let samplePath = "/Users/x/Library/Messages/chat.db"

    func testCancelledMapsToTheCancelledGuidance() {
        XCTAssertEqual(ClientErrorMessages.sanitized(DatabaseError.cancelled), ClientErrorMessages.cancelled)
    }

    func testNonDatabaseErrorPassesThroughUnchanged() {
        let sanitized = ClientErrorMessages.sanitized(SendError.timeout)

        XCTAssertEqual(sanitized, "Send operation timed out. Messages.app may be unresponsive.")
    }

    func testDatabaseErrorDescriptionStillCarriesDetailForLogging() {
        XCTAssertTrue(
            DatabaseError.permissionDenied(samplePath).localizedDescription.contains(samplePath),
            "The log-side description must keep the path; only the client payload is sanitized")
    }

    func testInternalDetailNeverEchoesTheUnderlyingDescription() {
        let stagingPath = "/Users/testuser/Pictures/imessage-max-staging/abc/photo.jpg"
        let underlying = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteUnknownError,
            userInfo: [NSLocalizedDescriptionKey: "Could not copy file to \(stagingPath)"]
        )

        let detail = ClientErrorMessages.internalDetail(
            underlying, context: "Preparing the attachment"
        )

        XCTAssertFalse(detail.contains("imessage-max-staging"),
            "internalDetail must not leak the staging directory name")
        XCTAssertFalse(detail.contains("/Users/"),
            "internalDetail must not leak the home directory or username")
        XCTAssertFalse(detail.contains(stagingPath),
            "internalDetail must not echo the staged file path")
        XCTAssertTrue(detail.contains("Preparing the attachment"),
            "internalDetail must name the operation that failed")
    }

    func testInternalDetailReturnsStableGuidance() {
        let detail = ClientErrorMessages.internalDetail(
            SendError.timeout, context: "Running AppleScript"
        )

        XCTAssertEqual(detail, "Running AppleScript failed. Check the server log for details.")
    }
}
