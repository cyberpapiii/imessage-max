import XCTest
@testable import iMessageMax

// Tests for ClientErrorMessages.sanitized, the seam that keeps filesystem
// paths out of client-visible error payloads (plan 023). DatabaseError carries
// paths in its description for the log side; clients get fixed guidance strings.
// Assertion idiom borrowed from AttachmentPathContainmentTests:126-132.

final class ClientErrorSanitizationTests: XCTestCase {

    private let samplePath = "/Users/x/Library/Messages/chat.db"

    func testPermissionDeniedIsSanitizedAndDropsPath() {
        let sanitized = ClientErrorMessages.sanitized(
            DatabaseError.permissionDenied(samplePath)
        )

        XCTAssertEqual(sanitized, ClientErrorMessages.permissionDenied)
        XCTAssertFalse(sanitized.contains("/Users"),
            "Sanitized client error must not leak the home directory or username")
        XCTAssertFalse(sanitized.contains(samplePath),
            "Sanitized client error must not echo the database path")
    }

    func testOtherDatabaseErrorsMapToFixedStrings() {
        let notFound = ClientErrorMessages.sanitized(DatabaseError.notFound(samplePath))
        XCTAssertEqual(notFound, ClientErrorMessages.databaseNotFound)
        XCTAssertFalse(notFound.contains("/Users"),
            "notFound must not leak the database path")

        let queryFailed = ClientErrorMessages.sanitized(DatabaseError.queryFailed("boom"))
        XCTAssertEqual(queryFailed, ClientErrorMessages.internalError)
        XCTAssertFalse(queryFailed.contains("boom"),
            "Raw SQL failure text must not reach the client")

        let invalidData = ClientErrorMessages.sanitized(DatabaseError.invalidData("bad blob"))
        XCTAssertEqual(invalidData, ClientErrorMessages.internalError)
        XCTAssertFalse(invalidData.contains("bad blob"),
            "Raw invalid-data detail must not reach the client")

        let cancelled = ClientErrorMessages.sanitized(DatabaseError.cancelled)
        XCTAssertEqual(cancelled, ClientErrorMessages.cancelled)
    }

    // Non-DatabaseError passes through unchanged: SendError descriptions are
    // deliberately client-facing and must survive the sanitizer untouched.
    func testNonDatabaseErrorPassesThroughUnchanged() {
        let sanitized = ClientErrorMessages.sanitized(SendError.timeout)

        XCTAssertEqual(sanitized, SendError.timeout.localizedDescription)
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
    // sanitized, it drops non-DatabaseError detail too. That is the whole
    // point at FileManager/Process catch sites, where the description
    // embeds the staging path and the operator's username (plan 039).
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

        XCTAssertTrue(detail.hasSuffix("failed. Check the server log for details."),
            "internalDetail guidance wording changed: \(detail)")
        XCTAssertEqual(detail, "Running AppleScript failed. Check the server log for details.")
    }
}
