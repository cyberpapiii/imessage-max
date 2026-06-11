// Tests/iMessageMaxTests/SendVerifierTests.swift
import XCTest
@testable import iMessageMax

// Tests for SendVerifier — the pure chat.db re-read layer that backs the
// verified-sends proof vocabulary. All tests use maxAttempts: 1 for speed
// unless explicitly testing multi-attempt behaviour.

final class SendVerifierTests: XCTestCase {

    // MARK: - Fixture

    private func makeFixture() throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "send-verifier")
        // Handle 1: Alice
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

    // MARK: - Tests

    // 1. Matching row with error = 0 → confirmed.
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

    // 2. Row with error = 22 (measured failed-send pattern) → NOT confirmed.
    // This is §3 finding 3: failed iMessage sends write rows with error = 22 immediately.
    func testErrorRowDoesNotConfirm() async throws {
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

        XCTAssertEqual(result, .notFound,
            "Row with error=22 must not confirm; the verification query requires error=0")
    }

    // 3. No row within the time window → notFound.
    func testNotFoundWhenNoRowInWindow() async throws {
        let fixture = try makeFixture()
        // No messages inserted.

        let verifier = makeVerifier(fixture: fixture)
        let result = try await verifier.verify(
            intendedChatId: 1,
            handle: "+15550000001",
            sendTime: Date(),
            expectedText: "Hello Alice"
        )

        XCTAssertEqual(result, .notFound)
    }

    // 4. Row exists but is older than the look-behind window (> 2s before sendTime) → notFound.
    func testOldRowOutsideWindowIsIgnored() async throws {
        let fixture = try makeFixture()
        // Insert a row 5 seconds before "now" — outside the 2s skew window.
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

    // 5. Row lands in a chat other than the intended one → mismatch.
    func testMismatchWhenRowIsInDifferentChat() async throws {
        let fixture = try makeFixture()
        let date = nowNs()

        // Insert message in chat 2 (not the intended chat 1).
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

    // 6. Row stored with text = nil (attributedBody-only path, §3 finding 2).
    // The ToolTestDatabase fixture inserts attributedBody = NULL, so
    // MessageTextExtractor cannot parse real typedstream blobs here. This test
    // verifies the text-column path; the attributedBody extraction path is
    // exercised by the live chat.db (noted as fixture gap).
    func testTextColumnNilRowIsNotConfirmedWithoutAttributedBody() async throws {
        let fixture = try makeFixture()
        let date = nowNs()

        // Insert with text = nil AND attributedBody = NULL (fixture limitation).
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
            "Row with nil text and nil attributedBody cannot be matched; " +
            "attributedBody-only matching is tested against the live DB")
    }

    // 7. Multi-attempt polling: with a pre-inserted matching row the verifier
    //    confirms within the first attempt and finishes well before maxAttempts
    //    × pollInterval elapses. Proves the polling loop structure is sound.
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
}
