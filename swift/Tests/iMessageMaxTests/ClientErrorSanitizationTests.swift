// Tests/iMessageMaxTests/ClientErrorSanitizationTests.swift
import XCTest
@testable import iMessageMax

// Tests for ClientErrorMessages.sanitized — the seam that keeps filesystem
// paths out of client-visible error payloads (plan 023). DatabaseError carries
// paths in its description for the log side; clients get fixed guidance strings.
// Assertion idiom borrowed from AttachmentPathContainmentTests:126-132.

final class ClientErrorSanitizationTests: XCTestCase {

    private let samplePath = "/Users/x/Library/Messages/chat.db"

    // 1. permissionDenied maps to the fixed guidance string and drops the path.
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

    // 2. notFound maps to databaseNotFound; queryFailed/invalidData map to
    //    internalError — and none of them echo their payload.
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
    }

    // 3. Non-DatabaseError passes through unchanged: SendError descriptions are
    //    deliberately client-facing and must survive the sanitizer untouched.
    func testNonDatabaseErrorPassesThroughUnchanged() {
        let sanitized = ClientErrorMessages.sanitized(SendError.timeout)

        XCTAssertEqual(sanitized, SendError.timeout.localizedDescription)
        XCTAssertEqual(sanitized, "Send operation timed out. Messages.app may be unresponsive.")
    }

    // 4. The underlying DatabaseError still carries the path — the detail is
    //    preserved for the stderr log, only withheld from the client payload.
    func testDatabaseErrorDescriptionStillCarriesDetailForLogging() {
        XCTAssertTrue(
            DatabaseError.permissionDenied(samplePath).localizedDescription.contains(samplePath),
            "The log-side description must keep the path; only the client payload is sanitized")
    }
}
