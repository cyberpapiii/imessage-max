import XCTest
@testable import iMessageMax

// Tests for SendVerifier, the pure chat.db re-read layer that backs the
// verified-sends proof vocabulary. All tests use maxAttempts: 1 for speed
// unless explicitly testing multi-attempt behaviour.

final class SendVerifierTests: XCTestCase {

    private func makeFixture() throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "send-verifier")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        // Chat 1: DM with Alice (intended chat)
        try fixture.insertChat(rowId: 1, guid: "iMessage;-;alice-guid")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)
        // Chat 2: another chat also containing Alice (for mismatch tests)
        try fixture.insertChat(rowId: 2, guid: "iMessage;+;group-guid", displayName: "Group")
        try fixture.joinChatHandle(chatId: 2, handleId: 1)
        return fixture
    }

    private func makeVerifier(fixture: ToolTestDatabase, maxAttempts: Int = 1) -> SendVerifier {
        SendVerifier(db: fixture.database(), maxAttempts: maxAttempts, pollInterval: .milliseconds(0))
    }

    /// Apple-epoch nanoseconds for the current moment, suitable for insertMessage date.
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
            sendTime: Date(),
            expectedText: "Hello Alice"
        )

        guard case .confirmed(let guid, _) = result else {
            return XCTFail("Expected .confirmed, got \(result)")
        }
        XCTAssertEqual(guid, "msg-guid-1")
    }

    // Row with error = 22 (measured failed-send pattern) → failedDelivery, not confirmed.
    // This is §3 finding 3: failed iMessage sends write rows with error = 22 immediately.
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
            sendTime: Date(),
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
            sendTime: Date(),
            expectedText: "Hello Alice"
        )

        XCTAssertEqual(result, .notFound)
    }

    // Row older than the look-behind window (> 2s before sendTime) → notFound.
    func testOldRowOutsideWindowIsIgnored() async throws {
        let fixture = try makeFixture()
        // Insert a row 5 seconds before "now", outside the 2s skew window.
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
            sendTime: Date(),   // window lower bound = now - 2s; row is at now - 5s
            expectedText: "Hello Alice"
        )

        XCTAssertEqual(result, .notFound, "Row older than the 2s skew should be outside the window")
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
            intendedChatId: 1,          // intended: chat 1
            handle: "+15550000001",     // handle is in chat 1 AND chat 2
            sendTime: Date(),
            expectedText: "Hello Alice"
        )

        guard case .mismatch(let actualChatId, _) = result else {
            return XCTFail("Expected .mismatch, got \(result)")
        }
        XCTAssertEqual(actualChatId, 2, "Mismatch should report chat 2 as the actual destination")
    }

    // Row stored with text = nil and no attributedBody: extractor returns nil,
    // so the verifier cannot match. The attributedBody-only path is covered by
    // testAttributedBodyOnlyRowIsConfirmed below.
    func testTextColumnNilRowIsNotConfirmedWithoutAttributedBody() async throws {
        let fixture = try makeFixture()
        let date = nowNs()

        // Insert with text = nil AND attributedBody = NULL.
        // MessageTextExtractor.extract returns nil → no match → notFound.
        try fixture.insertMessage(
            rowId: 5, guid: "msg-guid-nil-text", text: nil,
            date: date, isFromMe: true, error: 0
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 5)

        let verifier = makeVerifier(fixture: fixture)
        let result = try await verifier.verify(
            intendedChatId: 1,
            handle: nil,
            sendTime: Date(),
            expectedText: "Hello Alice"
        )

        // With both text and attributedBody nil, extractor returns nil → notFound.
        XCTAssertEqual(result, .notFound,
            "Row with nil text and no attributedBody cannot be matched")
    }

    // Row stored with text = nil and the text carried only in attributedBody
    // (the common real-world shape on modern macOS): the verifier must extract
    // the typedstream text and confirm.
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
            sendTime: Date(),
            expectedText: "Hello Alice"
        )

        guard case .confirmed = result else {
            return XCTFail("Expected .confirmed from an attributedBody-only row, got \(result)")
        }
    }

    /// Builds: <prefix junk> + marker + 5 filler bytes + length field + payload.
    /// Copied from MessageTextExtractorTests (private there).
    private func typedstreamBlob(marker: String = "NSString", lengthField: [UInt8], payload: [UInt8]) -> Data {
        var bytes: [UInt8] = [0x04, 0x0B]                 // arbitrary prefix junk
        bytes += Array(marker.utf8)
        bytes += [0x01, 0x94, 0x84, 0x01, 0x2B]           // 5 filler bytes (skipped)
        bytes += lengthField
        bytes += payload
        return Data(bytes)
    }

    // Multi-attempt polling: with a pre-inserted matching row the verifier
    // confirms within the first attempt and finishes well before maxAttempts
    // × pollInterval elapses. Proves the polling loop structure is sound.
    func testMultiAttemptPollingFindsExistingRow() async throws {
        let fixture = try makeFixture()
        let date = nowNs()

        try fixture.insertMessage(
            rowId: 6, guid: "msg-guid-poll", text: "Polling test",
            date: date, isFromMe: true, error: 0
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 6)

        // Use maxAttempts: 3 with a tiny interval; row is already present so
        // the first attempt finds it.
        let verifier = SendVerifier(
            db: fixture.database(),
            maxAttempts: 3,
            pollInterval: .milliseconds(50)
        )
        let result = try await verifier.verify(
            intendedChatId: 1,
            handle: nil,
            sendTime: Date(),
            expectedText: "Polling test"
        )

        guard case .confirmed(let guid, _) = result else {
            return XCTFail("Expected .confirmed within 3 attempts, got \(result)")
        }
        XCTAssertEqual(guid, "msg-guid-poll")
    }

    // MARK: - Failed-delivery classification (plan 021)

    // A failed row AND a clean row both match in the intended chat → confirmed.
    // Covers Messages' own immediate-retry behaviour: a clean row anywhere in the
    // window beats a failed one.
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
            sendTime: Date(),
            expectedText: "Hello Alice"
        )

        guard case .confirmed(let guid, _) = result else {
            return XCTFail("Expected .confirmed (clean row wins over failed row), got \(result)")
        }
        XCTAssertEqual(guid, "msg-guid-clean-retry",
            "The clean retry row should be the one reported as confirmed")
    }

    // A failed row in a chat OTHER than the intended one stays invisible → notFound.
    // Mismatch fires only on clean rows, exactly as before this change.
    func testFailedRowInDifferentChatIsInvisible() async throws {
        let fixture = try makeFixture()
        let date = nowNs()

        // Failed row lands in chat 2 while chat 1 is intended; the handle joins both.
        try fixture.insertMessage(
            rowId: 12, guid: "msg-guid-failed-other-chat", text: "Hello Alice",
            date: date, isFromMe: true, error: 22, isSent: 0
        )
        try fixture.joinChatMessage(chatId: 2, messageId: 12)

        let verifier = makeVerifier(fixture: fixture)
        let result = try await verifier.verify(
            intendedChatId: 1,
            handle: "+15550000001",
            sendTime: Date(),
            expectedText: "Hello Alice"
        )

        XCTAssertEqual(result, .notFound,
            "A failed row in a different chat must not surface as mismatch or failedDelivery")
    }

    // Fallback path with no intended chat: a failed matching row → failedDelivery.
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
            intendedChatId: nil,        // no intended chat → fallback handle scan only
            handle: "+15550000001",
            sendTime: Date(),
            expectedText: "Hello Alice"
        )

        XCTAssertEqual(result, .failedDelivery(guid: "msg-guid-fallback-failed", errorCode: 22),
            "The fallback scan must classify a failed matching row as failedDelivery")
    }
}
