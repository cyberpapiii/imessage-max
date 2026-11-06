import XCTest
@testable import iMessageMax

final class SendVerifierTests: XCTestCase {

    private func makeFixture() throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "send-verifier")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 1, guid: "iMessage;-;alice-guid")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)
        try fixture.insertChat(rowId: 2, guid: "iMessage;+;group-guid", displayName: "Group")
        try fixture.joinChatHandle(chatId: 2, handleId: 1)
        return fixture
    }

    private func makeVerifier(fixture: ToolTestDatabase, maxAttempts: Int = 1) -> SendVerifier {
        SendVerifier(db: fixture.database(), maxAttempts: maxAttempts, pollInterval: .milliseconds(0))
    }

    private func nowNs() -> Int64 { AppleTime.fromDate(Date()) }

    func testConfirmedOnMatchingRowWithNoError() async throws {
        let fixture = try makeFixture()
        let date = nowNs()

        try fixture.insertMessage(
            rowId: 1, guid: "msg-guid-1", text: "Hello Alice",
            date: date, isFromMe: true, error: 0, isSent: 0
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 1)

        let verifier = makeVerifier(fixture: fixture)
        let result = try await verifier.verify(
            intendedChatId: 1,
            handle: "+15550000001",
            afterRowId: 0,
            expectedText: "Hello Alice"
        )

        guard case .confirmed(let guid, _) = result else {
            return XCTFail("Expected .confirmed, got \(result)")
        }
        XCTAssertEqual(guid, "msg-guid-1")
    }

    // Failed iMessage sends write their row with error = 22 at once.
    func testErrorRowClassifiesAsFailedDelivery() async throws {
        let fixture = try makeFixture()
        let date = nowNs()

        try fixture.insertMessage(
            rowId: 2, guid: "msg-guid-error", text: "Hello Alice",
            date: date, isFromMe: true, error: 22, isSent: 0
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 2)

        let verifier = makeVerifier(fixture: fixture)
        let result = try await verifier.verify(
            intendedChatId: 1,
            handle: "+15550000001",
            afterRowId: 0,
            expectedText: "Hello Alice"
        )

        XCTAssertEqual(result, .failedDelivery(guid: "msg-guid-error", errorCode: 22),
            "Row with error=22 must classify as a verified delivery failure, not confirm")
    }

    func testNotFoundWhenNoRowInWindow() async throws {
        let fixture = try makeFixture()

        let verifier = makeVerifier(fixture: fixture)
        let result = try await verifier.verify(
            intendedChatId: 1,
            handle: "+15550000001",
            afterRowId: 0,
            expectedText: "Hello Alice"
        )

        XCTAssertEqual(result, .notFound)
    }

    func testOldRowOutsideWindowIsIgnored() async throws {
        let fixture = try makeFixture()
        let oldDate = AppleTime.fromDate(Date().addingTimeInterval(-5))

        try fixture.insertMessage(
            rowId: 3, guid: "msg-guid-old", text: "Hello Alice",
            date: oldDate, isFromMe: true, error: 0
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 3)

        let verifier = makeVerifier(fixture: fixture)
        let result = try await verifier.verify(
            intendedChatId: 1,
            handle: nil,
            afterRowId: 3,
            expectedText: "Hello Alice"
        )

        XCTAssertEqual(result, .notFound, "A row at or below the baseline predates the send")
    }

    func testMismatchWhenRowIsInDifferentChat() async throws {
        let fixture = try makeFixture()
        let date = nowNs()

        try fixture.insertMessage(
            rowId: 4, guid: "msg-guid-mismatch", text: "Hello Alice",
            date: date, isFromMe: true, error: 0
        )
        try fixture.joinChatMessage(chatId: 2, messageId: 4)

        let verifier = makeVerifier(fixture: fixture)
        let result = try await verifier.verify(
            intendedChatId: 1,
            handle: "+15550000001",
            afterRowId: 0,
            expectedText: "Hello Alice"
        )

        guard case .mismatch(let actualChatId, _) = result else {
            return XCTFail("Expected .mismatch, got \(result)")
        }
        XCTAssertEqual(actualChatId, 2, "Mismatch should report chat 2 as the actual destination")
    }

    func testTextColumnNilRowIsNotConfirmedWithoutAttributedBody() async throws {
        let fixture = try makeFixture()
        let date = nowNs()

        try fixture.insertMessage(
            rowId: 5, guid: "msg-guid-nil-text", text: nil,
            date: date, isFromMe: true, error: 0
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 5)

        let verifier = makeVerifier(fixture: fixture)
        let result = try await verifier.verify(
            intendedChatId: 1,
            handle: nil,
            afterRowId: 0,
            expectedText: "Hello Alice"
        )

        XCTAssertEqual(result, .notFound,
            "Row with nil text and no attributedBody cannot be matched")
    }

    func testAttributedBodyOnlyRowIsConfirmed() async throws {
        let fixture = try makeFixture()
        let date = nowNs()
        let blob = typedstreamBlob(lengthField: [11], payload: Array("Hello Alice".utf8))

        try fixture.insertMessage(
            rowId: 7, guid: "msg-guid-attributed", text: nil,
            date: date, isFromMe: true, error: 0, attributedBody: blob
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 7)

        let verifier = makeVerifier(fixture: fixture)
        let result = try await verifier.verify(
            intendedChatId: 1,
            handle: nil,
            afterRowId: 0,
            expectedText: "Hello Alice"
        )

        guard case .confirmed = result else {
            return XCTFail("Expected .confirmed from an attributedBody-only row, got \(result)")
        }
    }

    func testFailedThenCleanRowConfirms() async throws {
        let fixture = try makeFixture()
        let date = nowNs()

        try fixture.insertMessage(
            rowId: 10, guid: "msg-guid-failed-first", text: "Hello Alice",
            date: date, isFromMe: true, error: 22, isSent: 0
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 10)

        try fixture.insertMessage(
            rowId: 11, guid: "msg-guid-clean-retry", text: "Hello Alice",
            date: date + 1, isFromMe: true, error: 0, isSent: 0
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 11)

        let verifier = makeVerifier(fixture: fixture)
        let result = try await verifier.verify(
            intendedChatId: 1,
            handle: "+15550000001",
            afterRowId: 0,
            expectedText: "Hello Alice"
        )

        guard case .confirmed(let guid, _) = result else {
            return XCTFail("Expected .confirmed (clean row wins over failed row), got \(result)")
        }
        XCTAssertEqual(guid, "msg-guid-clean-retry",
            "The clean retry row should be the one reported as confirmed")
    }

    func testFailedRowInDifferentChatIsInvisible() async throws {
        let fixture = try makeFixture()
        let date = nowNs()

        try fixture.insertMessage(
            rowId: 12, guid: "msg-guid-failed-other-chat", text: "Hello Alice",
            date: date, isFromMe: true, error: 22, isSent: 0
        )
        try fixture.joinChatMessage(chatId: 2, messageId: 12)

        let verifier = makeVerifier(fixture: fixture)
        let result = try await verifier.verify(
            intendedChatId: 1,
            handle: "+15550000001",
            afterRowId: 0,
            expectedText: "Hello Alice"
        )

        XCTAssertEqual(result, .notFound,
            "A failed row in a different chat must not surface as mismatch or failedDelivery")
    }

    func testFallbackFailedRowWithoutIntendedChat() async throws {
        let fixture = try makeFixture()
        let date = nowNs()

        try fixture.insertMessage(
            rowId: 13, guid: "msg-guid-fallback-failed", text: "Hello Alice",
            date: date, isFromMe: true, error: 22, isSent: 0
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 13)

        let verifier = makeVerifier(fixture: fixture)
        let result = try await verifier.verify(
            intendedChatId: nil,
            handle: "+15550000001",
            afterRowId: 0,
            expectedText: "Hello Alice"
        )

        XCTAssertEqual(result, .failedDelivery(guid: "msg-guid-fallback-failed", errorCode: 22),
            "The fallback scan must classify a failed matching row as failedDelivery")
    }

    func testIdenticalSendsCannotConfirmTheSameRow() async throws {
        let fixture = try makeFixture()
        let verifier = makeVerifier(fixture: fixture)
        let baseline = try verifier.baseline()
        try fixture.insertMessage(rowId: 70, guid: "same-70", text: "Same text", date: nowNs(), isFromMe: true)
        try fixture.joinChatMessage(chatId: 1, messageId: 70)

        let first = try await verifier.verify(intendedChatId: 1, handle: nil, afterRowId: baseline, expectedText: "Same text")
        let second = try await verifier.verify(intendedChatId: 1, handle: nil, afterRowId: baseline, expectedText: "Same text")
        guard case .confirmed(let firstGuid, _) = first else { return XCTFail("expected confirmed, got \(first)") }
        XCTAssertEqual(firstGuid, "same-70")
        XCTAssertEqual(second, .notFound, "the row is already claimed by the first send")

        try fixture.insertMessage(rowId: 71, guid: "same-71", text: "Same text", date: nowNs(), isFromMe: true)
        try fixture.joinChatMessage(chatId: 1, messageId: 71)
        let third = try await verifier.verify(intendedChatId: 1, handle: nil, afterRowId: baseline, expectedText: "Same text")
        guard case .confirmed(let thirdGuid, _) = third else { return XCTFail("expected confirmed, got \(third)") }
        XCTAssertEqual(thirdGuid, "same-71", "the second send confirms its own row")
    }

    func testBaselineIsTheNewestMessageRowId() throws {
        let fixture = try makeFixture()
        let verifier = makeVerifier(fixture: fixture)
        XCTAssertEqual(try verifier.baseline(), 0)
        try fixture.insertMessage(rowId: 42, guid: "x", text: "x", date: nowNs(), isFromMe: true)
        XCTAssertEqual(try verifier.baseline(), 42)
    }
}
