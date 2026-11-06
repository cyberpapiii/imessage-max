import XCTest
@testable import iMessageMax

/// ClientErrorMessages keeps filesystem paths out of client-visible errors.
/// DatabaseError carries paths in its description for the log; clients get
/// fixed guidance. How each DatabaseError reaches a client through a tool
/// call is pinned in ToolErrorMappingTests.
final class ClientErrorSanitizationTests: XCTestCase {

    private let samplePath = "/Users/x/Library/Messages/chat.db"

    func testCancelledMapsToTheCancelledGuidance() {
        XCTAssertEqual(ClientErrorMessages.sanitized(DatabaseError.cancelled), ClientErrorMessages.cancelled)
    }

    // Non-DatabaseError passes through unchanged: SendError descriptions are
    // deliberately client-facing and must survive the sanitizer untouched.
    func testNonDatabaseErrorPassesThroughUnchanged() {
        let sanitized = ClientErrorMessages.sanitized(SendError.timeout)

        XCTAssertEqual(sanitized, "Send operation timed out. Messages.app may be unresponsive.")
    }

    // The underlying DatabaseError still carries the path. The detail is
    // preserved for the stderr log, only withheld from the client payload.
    func testDatabaseErrorDescriptionStillCarriesDetailForLogging() {
        XCTAssertTrue(
            DatabaseError.permissionDenied(samplePath).localizedDescription.contains(samplePath),
            "The log-side description must keep the path; only the client payload is sanitized")
    }

    // internalDetail never echoes the underlying description. Unlike
    // sanitized, it drops non-DatabaseError detail too, for FileManager and
    // Process catch sites, where the description embeds the staging path
    // and the operator's username.
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

    // The guidance wording is pinned so it cannot drift accidentally.
    func testInternalDetailReturnsStableGuidance() {
        let detail = ClientErrorMessages.internalDetail(
            SendError.timeout, context: "Running AppleScript"
        )

        XCTAssertEqual(detail, "Running AppleScript failed. Check the server log for details.")
    }
}
