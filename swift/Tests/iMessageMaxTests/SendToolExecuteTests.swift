import XCTest
import MCP
@testable import iMessageMax

// Execute-path tests for SendTool using an injected stub runner.
// These tests characterize the routing logic (participant vs chat target,
// success vs failure propagation) without touching Messages.app.

// MARK: - Stub

final class StubScriptRunner: ScriptRunning, @unchecked Sendable {
    enum Call: Equatable {
        case textToParticipant(handle: String, message: String)
        case fileToParticipant(handle: String, filePath: String)
        case textToChat(guid: String, message: String)
        case fileToChat(guid: String, filePath: String)
    }

    private(set) var invocations: [Call] = []
    var nextResult: Result<Void, SendFailure> = .success(())
    /// When non-empty, each call pops the next result; nextResult is the fallback.
    /// Lets a test express "payload 1 succeeds, payload 2 fails".
    var queuedResults: [Result<Void, SendFailure>] = []
    /// Optional side effect run on every send call before nextResult is returned.
    /// Used to simulate Messages.app writing the chat.db row between send and verify.
    var onSend: (() -> Void)?

    private func takeResult() -> Result<Void, SendFailure> {
        queuedResults.isEmpty ? nextResult : queuedResults.removeFirst()
    }

    func sendTextToParticipant(handle: String, message: String) async -> Result<Void, SendFailure> {
        invocations.append(.textToParticipant(handle: handle, message: message))
        onSend?()
        return takeResult()
    }

    func sendFileToParticipant(handle: String, filePath: String) async -> Result<Void, SendFailure> {
        invocations.append(.fileToParticipant(handle: handle, filePath: filePath))
        onSend?()
        return takeResult()
    }

    func sendTextToChat(guid: String, message: String) async -> Result<Void, SendFailure> {
        invocations.append(.textToChat(guid: guid, message: message))
        onSend?()
        return takeResult()
    }

    func sendFileToChat(guid: String, filePath: String) async -> Result<Void, SendFailure> {
        invocations.append(.fileToChat(guid: guid, filePath: filePath))
        onSend?()
        return takeResult()
    }
}

// MARK: - Fixture helpers

private func makeSendFixture() throws -> ToolTestDatabase {
    let fixture = try ToolTestDatabase(name: "send-execute")

    try fixture.insertHandle(rowId: 1, handle: "+15550000001")  // Alice
    try fixture.insertHandle(rowId: 2, handle: "+15550000002")  // Bob

    // Chat 1: DM with Alice (one participant)
    try fixture.insertChat(rowId: 1, guid: "iMessage;-;alice-send-guid")
    try fixture.joinChatHandle(chatId: 1, handleId: 1)

    // Chat 2: group chat with Alice and Bob
    try fixture.insertChat(rowId: 2, guid: "iMessage;+;group-send-guid", displayName: "Group Chat")
    try fixture.joinChatHandle(chatId: 2, handleId: 1)
    try fixture.joinChatHandle(chatId: 2, handleId: 2)

    return fixture
}

// MARK: - Fast-poll verifier helper

/// Returns a SendVerifier with maxAttempts: 1 so tests that send text but have no
/// matching DB row get "uncertain" immediately without waiting for polling intervals.
private func fastVerifier(fixture: ToolTestDatabase) -> SendVerifier {
    SendVerifier(db: fixture.database(), maxAttempts: 1, pollInterval: .milliseconds(0))
}

// MARK: - Tests

final class SendToolExecuteTests: XCTestCase {

    // Stub success with no DB row → "uncertain" (plan Step 4, sanctioned contract change).
    func testSendTextToKnownHandleInvokesParticipantSend() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        stub.nextResult = .success(())

        let tool = SendTool(
            db: fixture.database(),
            resolver: makeSeededResolver(),
            runner: stub,
            verifier: fastVerifier(fixture: fixture)
        )

        // No matching DB row → verifier returns notFound → "uncertain".
        let contents = try await tool.execute(args: [
            "to": .string("+15550000001"),
            "text": .string("Hello Alice"),
        ])

        let json = try decodeJSONDictionary(from: contents)
        XCTAssertEqual(json["status"] as? String, "uncertain",
            "Without a matching DB row, status should be 'uncertain' (sanctioned contract change per plan 012)")

        XCTAssertEqual(stub.invocations.count, 1, "Stub should have been called exactly once")
        guard case .textToParticipant(let handle, let message) = stub.invocations.first else {
            return XCTFail("Expected textToParticipant call, got \(String(describing: stub.invocations.first))")
        }
        XCTAssertEqual(handle, "+15550000001", "Handle should be Alice's normalized phone number")
        XCTAssertEqual(message, "Hello Alice", "Message text should be passed through unchanged")
    }

    // Stub success with no DB row → "uncertain" for chat-target sends too.
    func testSendToChatIdTargetsChatGuidNotParticipant() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        stub.nextResult = .success(())

        let tool = SendTool(
            db: fixture.database(),
            resolver: makeSeededResolver(),
            runner: stub,
            verifier: fastVerifier(fixture: fixture)
        )

        // No matching DB row → verifier returns notFound → "uncertain".
        let contents = try await tool.execute(args: [
            "chat_id": .string("chat2"),
            "text": .string("Hey group"),
            "confirm": .bool(true),
        ])

        let json = try decodeJSONDictionary(from: contents)
        XCTAssertEqual(json["status"] as? String, "uncertain",
            "Without a matching DB row, status should be 'uncertain' (sanctioned contract change per plan 012)")

        XCTAssertEqual(stub.invocations.count, 1, "Stub should have been called exactly once")
        guard case .textToChat(let guid, let message) = stub.invocations.first else {
            return XCTFail("Expected textToChat call; got \(String(describing: stub.invocations.first)). Guards the 'never silently convert group target to DM' invariant.")
        }
        XCTAssertEqual(guid, "iMessage;+;group-send-guid", "Stub should receive the chat's guid, not a participant handle")
        XCTAssertEqual(message, "Hey group")
    }

    func testScriptFailureProducesFailedStatus() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        stub.nextResult = .failure(SendFailure(.failed("osascript error -1712"), disposition: .notStarted))

        let tool = SendTool(db: fixture.database(), resolver: makeSeededResolver(), runner: stub)

        do {
            _ = try await tool.execute(args: [
                "to": .string("+15550000001"),
                "text": .string("Hello"),
            ])
            XCTFail("Expected ToolError to be thrown for failed send")
        } catch let error as ToolError {
            let json = try decodeJSONDictionary(from: error.content)
            XCTAssertEqual(json["status"] as? String, "failed", "Status should be 'failed' when script errors")
            let errorMsg = json["error"] as? String
            XCTAssertTrue(
                errorMsg?.contains("osascript error") == true,
                "Error field should surface the stub's error message; got \(String(describing: errorMsg))"
            )
        }

        XCTAssertEqual(stub.invocations.count, 1, "Stub should have been called once before the failure was detected")
    }

    // Regression test for the findDirectChatForHandle bug: the old SQL applied
    // `WHERE h.id = ?` before GROUP BY, so HAVING COUNT(DISTINCT handle_id) = 1
    // counted only the filtered handle's rows. Every chat containing the handle
    // passed, and ORDER BY ROWID DESC picked the group (chat 2) over the DM (chat 1).
    func testResolverPicksDirectChatNotGroupForParticipantSend() async throws {
        let fixture = try makeSendFixture()  // DM chat 1 (Alice) + group chat 2 (Alice+Bob)

        let resolver = SendResolver(db: fixture.database(), resolver: makeSeededResolver())
        let result = await resolver.resolve(chatId: nil, to: "+15550000001")

        switch result {
        case .failure(let message):
            XCTFail("Unexpected failure: \(message)")
        case .ambiguous:
            XCTFail("Unexpected ambiguity")
        case .success(let resolved):
            guard case .participant(let handle, let chatId) = resolved.target else {
                return XCTFail("Expected participant target, got \(resolved.target)")
            }
            XCTAssertEqual(handle, "+15550000001")
            XCTAssertEqual(chatId, 1,
                "Participant send must resolve to the true 1:1 DM (chat 1), not the group (chat 2) that also contains the handle")
        }
    }

    // Pre-insert a matching outbound row (error=0) in the DM → verifier returns confirmed.
    // Uses the FULL multi-chat fixture (DM chat 1 + group chat 2, both containing Alice):
    // this is the common real-world topology that previously produced a false mismatch
    // via the findDirectChatForHandle resolver bug.
    // Row is inserted before execute() so its date falls within the 2s skew window
    // (date = now, sendTime = now + tiny delta; skew covers this).
    func testStubSendWithMatchingRowConfirms() async throws {
        let fixture = try makeSendFixture()  // DM chat 1 (Alice) + group chat 2 (Alice+Bob)
        let stub = StubScriptRunner()
        stub.nextResult = .success(())

        // Pre-insert the expected outbound row in chat 1 (Alice DM).
        let rowDate = AppleTime.fromDate(Date())
        try fixture.insertMessage(
            rowId: 100, guid: "msg-guid-confirm", text: "Hello Alice",
            date: rowDate, isFromMe: true, error: 0, isSent: 0
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 100)

        let tool = SendTool(
            db: fixture.database(),
            resolver: makeSeededResolver(),
            runner: stub,
            verifier: fastVerifier(fixture: fixture)
        )

        let contents = try await tool.execute(args: [
            "to": .string("+15550000001"),
            "text": .string("Hello Alice"),
        ])

        let json = try decodeJSONDictionary(from: contents)
        XCTAssertEqual(json["status"] as? String, "confirmed",
            "With a matching row (error=0) in the DM, status should be 'confirmed' even when the handle is also in a group chat")
        XCTAssertEqual(json["verified_message_guid"] as? String, "msg-guid-confirm",
            "verified_message_guid should carry the message GUID from chat.db")
        XCTAssertNotNil(json["verified_at"], "verified_at should be present for confirmed sends")
    }

    // Same setup as testStubSendWithMatchingRowConfirms, but the matching row lands
    // in the GROUP (chat 2) while the send targets Alice's DM (chat 1). The verifier
    // finds the row through Alice's handle, sees it is not in the intended chat, and
    // the tool must surface "mismatch" as a ToolError so an agent never treats it as
    // confirmed. Pins the response envelope that plans 045 and 049 will touch.
    func testRowInDifferentChatProducesMismatchStatus() async throws {
        let fixture = try makeSendFixture()  // DM chat 1 (Alice) + group chat 2 (Alice+Bob)
        let stub = StubScriptRunner()
        stub.nextResult = .success(())

        let rowDate = AppleTime.fromDate(Date())
        try fixture.insertMessage(
            rowId: 103, guid: "msg-guid-mismatch", text: "Hello Alice",
            date: rowDate, isFromMe: true, error: 0, isSent: 0
        )
        try fixture.joinChatMessage(chatId: 2, messageId: 103)

        let tool = SendTool(
            db: fixture.database(),
            resolver: makeSeededResolver(),
            runner: stub,
            verifier: fastVerifier(fixture: fixture)
        )

        do {
            _ = try await tool.execute(args: [
                "to": .string("+15550000001"),
                "text": .string("Hello Alice"),
            ])
            XCTFail("Expected ToolError for a routing mismatch")
        } catch let error as ToolError {
            let json = try decodeJSONDictionary(from: error.content)
            XCTAssertEqual(json["status"] as? String, "mismatch",
                "A matching row in a chat other than the intended one is a routing mismatch")
            let message = json["message"] as? String ?? ""
            XCTAssertTrue(message.contains("routing mismatch"),
                "The message must say it is a routing mismatch; got: \(message)")
            XCTAssertEqual(json["actual_chat_id"] as? String, "chat2",
                "actual_chat_id names the chat the row was actually found in")
            XCTAssertNil(json["chat_id"], "chat_id is nil for a mismatch so it cannot be mistaken for the delivered chat")
            XCTAssertNil(json["verified_message_guid"], "a mismatch is not a verified send")
        }

        XCTAssertEqual(stub.invocations.count, 1, "The send itself was dispatched exactly once")
    }

    // A file-only send has no text payload to verify against chat.db, so the tool
    // skips verification and reports the transport-only "sent" status. This is the
    // one reachable path to "sent" via the stub: verification also falls back to
    // "sent" when the DB is unreadable, which the fixture cannot simulate.
    func testFileSendWithoutVerificationRowReportsPendingOrSent() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        stub.nextResult = .success(())

        let tool = SendTool(
            db: fixture.database(),
            resolver: makeSeededResolver(),
            runner: stub,
            verifier: fastVerifier(fixture: fixture)
        )

        let contents = try await tool.execute(args: [
            "to": .string("+15550000001"),
            "file_paths": .array([.string("/tmp/a.jpg")]),
        ])

        let json = try decodeJSONDictionary(from: contents)
        XCTAssertEqual(json["status"] as? String, "sent",
            "A file-only send skips DB verification and reports the transport-only 'sent'")
        XCTAssertEqual(json["chat_id"] as? String, "chat1", "The resolved DM is reported as chat_id")
        XCTAssertNil(json["verified_message_guid"], "'sent' carries no verification proof")
        XCTAssertEqual(stub.invocations.count, 1)
        guard case .fileToParticipant(let handle, let filePath) = stub.invocations.first else {
            return XCTFail("Expected fileToParticipant call, got \(String(describing: stub.invocations.first))")
        }
        XCTAssertEqual(handle, "+15550000001")
        XCTAssertEqual(filePath, "/tmp/a.jpg")
    }

    // End-to-end variant of the previously false-mismatch scenario: the stub runner's
    // side effect inserts the matching row into the DM during the send call (simulating
    // Messages.app writing chat.db), then verification runs and must confirm.
    func testStubSideEffectRowInDMConfirmsWithGroupPresent() async throws {
        let fixture = try makeSendFixture()  // DM chat 1 (Alice) + group chat 2 (Alice+Bob)
        let stub = StubScriptRunner()
        stub.nextResult = .success(())
        stub.onSend = {
            // Simulate Messages.app writing the outbound row to the DM at send time.
            try? fixture.insertMessage(
                rowId: 102, guid: "msg-guid-side-effect", text: "Hello Alice",
                date: AppleTime.fromDate(Date()), isFromMe: true, error: 0, isSent: 0
            )
            try? fixture.joinChatMessage(chatId: 1, messageId: 102)
        }

        let tool = SendTool(
            db: fixture.database(),
            resolver: makeSeededResolver(),
            runner: stub,
            verifier: fastVerifier(fixture: fixture)
        )

        let contents = try await tool.execute(args: [
            "to": .string("+15550000001"),
            "text": .string("Hello Alice"),
        ])

        let json = try decodeJSONDictionary(from: contents)
        XCTAssertEqual(json["status"] as? String, "confirmed",
            "Row written to the DM between send and verify must confirm; this exact topology previously produced a false mismatch")
        XCTAssertEqual(json["verified_message_guid"] as? String, "msg-guid-side-effect")
    }

    // Pre-insert a row with error=22 (measured failed-send pattern) → NOT confirmed.
    // The row is a verified delivery failure, so the tool reports "failed_delivery"
    // and surfaces it as a ToolError. Uses the full multi-chat fixture.
    func testFailedRowReturnsFailedDeliveryStatus() async throws {
        let fixture = try makeSendFixture()  // DM chat 1 (Alice) + group chat 2 (Alice+Bob)
        let stub = StubScriptRunner()
        stub.nextResult = .success(())

        let rowDate = AppleTime.fromDate(Date())
        try fixture.insertMessage(
            rowId: 101, guid: "msg-guid-error-row", text: "Hello Alice",
            date: rowDate, isFromMe: true, error: 22, isSent: 0
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 101)

        let tool = SendTool(
            db: fixture.database(),
            resolver: makeSeededResolver(),
            runner: stub,
            verifier: fastVerifier(fixture: fixture)
        )

        do {
            _ = try await tool.execute(args: [
                "to": .string("+15550000001"),
                "text": .string("Hello Alice"),
            ])
            XCTFail("Expected ToolError for a verified delivery failure")
        } catch let error as ToolError {
            let json = try decodeJSONDictionary(from: error.content)
            XCTAssertEqual(json["status"] as? String, "failed_delivery",
                "A row with error=22 is a verified delivery failure, not 'uncertain' (§3 finding 3)")
            XCTAssertEqual(json["verified_message_guid"] as? String, "msg-guid-error-row",
                "The failed row's GUID is the evidence for the failure")
        }
    }

    func testRecipientNotFoundDoesNotInvokeRunner() async throws {
        // NOTE: The plan intended to test the 'ambiguous' path (two contacts matching a name
        // query) to prove that runner is never invoked before resolution completes.
        // However, resolveContactName() checks CNContactStore.authorizationStatus() before
        // searching the seeded cache; on this machine and in CI the status is notDetermined,
        // so name-based resolution always returns a 'failed' status rather than 'ambiguous'.
        // This test characterizes the same invariant, that the runner is never invoked
        // when send cannot resolve a recipient, via a path that does not require Contacts
        // authorization: a phone number that does not exist in the fixture DB.
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()

        let tool = SendTool(db: fixture.database(), resolver: makeSeededResolver(), runner: stub)

        do {
            _ = try await tool.execute(args: [
                "to": .string("+15559999999"),  // not in the fixture DB
                "text": .string("Hi"),
            ])
            XCTFail("Expected ToolError for unresolvable recipient")
        } catch let error as ToolError {
            let json = try decodeJSONDictionary(from: error.content)
            XCTAssertEqual(
                json["status"] as? String,
                "failed",
                "Status should be 'failed' for unresolvable recipient"
            )
        }

        XCTAssertTrue(
            stub.invocations.isEmpty,
            "Runner should never be invoked when recipient resolution fails; got \(stub.invocations)"
        )
    }

    // MARK: - Agent-native send contract (plan 017): no confirmation gate

    // 1:1 DM targeted by exact chat_id with NO confirm flag sends immediately
    // and verifies to "confirmed" via the staged-row side effect.
    func testOneToOneChatSendWithoutConfirmSends() async throws {
        let fixture = try makeSendFixture()  // DM chat 1 (Alice) + group chat 2
        let stub = StubScriptRunner()
        stub.nextResult = .success(())
        stub.onSend = {
            try? fixture.insertMessage(
                rowId: 110, guid: "msg-guid-dm-017", text: "Hello Alice",
                date: AppleTime.fromDate(Date()), isFromMe: true, error: 0, isSent: 0
            )
            try? fixture.joinChatMessage(chatId: 1, messageId: 110)
        }

        let tool = SendTool(
            db: fixture.database(),
            resolver: makeSeededResolver(),
            runner: stub,
            verifier: fastVerifier(fixture: fixture)
        )

        let contents = try await tool.execute(args: [
            "chat_id": .string("chat1"),
            "text": .string("Hello Alice"),
        ])

        let json = try decodeJSONDictionary(from: contents)
        XCTAssertEqual(json["status"] as? String, "confirmed",
            "1:1 chat_id send without confirm must send immediately and verify to 'confirmed'")
        XCTAssertEqual(stub.invocations.count, 1, "Stub should have been invoked exactly once")
    }

    // 501-char text with NO confirm flag sends immediately (long text no longer gates).
    func testLongTextSendsWithoutConfirm() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        stub.nextResult = .success(())

        let longText = String(repeating: "a", count: 501)
        stub.onSend = {
            try? fixture.insertMessage(
                rowId: 111, guid: "msg-guid-long-017", text: longText,
                date: AppleTime.fromDate(Date()), isFromMe: true, error: 0, isSent: 0
            )
            try? fixture.joinChatMessage(chatId: 1, messageId: 111)
        }

        let tool = SendTool(
            db: fixture.database(),
            resolver: makeSeededResolver(),
            runner: stub,
            verifier: fastVerifier(fixture: fixture)
        )

        let contents = try await tool.execute(args: [
            "to": .string("+15550000001"),
            "text": .string(longText),
        ])

        let json = try decodeJSONDictionary(from: contents)
        XCTAssertEqual(json["status"] as? String, "confirmed",
            "Long text (>500 chars) without confirm must send immediately; long text no longer gates")
        XCTAssertEqual(stub.invocations.count, 1, "Stub should have been invoked exactly once")
    }

    // The confirm flag is inert: explicit true and explicit false produce the
    // identical "confirmed" outcome.
    func testConfirmFlagIsInert() async throws {
        for (confirmValue, rowId, guid) in [(true, 120, "msg-guid-inert-true"), (false, 121, "msg-guid-inert-false")] {
            let fixture = try makeSendFixture()
            let stub = StubScriptRunner()
            stub.nextResult = .success(())
            stub.onSend = {
                try? fixture.insertMessage(
                    rowId: rowId, guid: guid, text: "Hello Alice",
                    date: AppleTime.fromDate(Date()), isFromMe: true, error: 0, isSent: 0
                )
                try? fixture.joinChatMessage(chatId: 1, messageId: rowId)
            }

            let tool = SendTool(
                db: fixture.database(),
                resolver: makeSeededResolver(),
                runner: stub,
                verifier: fastVerifier(fixture: fixture)
            )

            let contents = try await tool.execute(args: [
                "chat_id": .string("chat1"),
                "text": .string("Hello Alice"),
                "confirm": .bool(confirmValue),
            ])

            let json = try decodeJSONDictionary(from: contents)
            XCTAssertEqual(json["status"] as? String, "confirmed",
                "confirm: \(confirmValue) must be inert; outcome should be identical 'confirmed'")
            XCTAssertEqual(stub.invocations.count, 1,
                "Stub should have been invoked exactly once with confirm: \(confirmValue)")
        }
    }

    // MARK: - Partial multi-payload send reporting (plan 026)

    // NOTE on payload order: SendPayload.build appends FILES first, then the
    // text. So for `text` + one `file_paths` entry the dispatch order is
    // [file, text]. The file is payload 0 and the text is payload 1.

    // An earlier payload was dispatched and a later one hard-failed: the
    // response must say so, not report a blanket "failed" that invites a
    // retry duplicating what the recipient already received.
    func testPartialFailureWhenLaterPayloadFails() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        // Payload 0 (the file) succeeds; payload 1 (the text) hard-fails.
        stub.queuedResults = [.success(()), .failure(SendFailure(.messagesAppUnavailable, disposition: .notStarted))]

        let tool = SendTool(
            db: fixture.database(),
            resolver: makeSeededResolver(),
            runner: stub,
            verifier: fastVerifier(fixture: fixture)
        )

        do {
            _ = try await tool.execute(args: [
                "to": .string("+15550000001"),
                "text": .string("Hello Alice"),
                "file_paths": .array([.string("/tmp/x.jpg")]),
            ])
            XCTFail("Expected ToolError for a partial send failure")
        } catch let error as ToolError {
            let json = try decodeJSONDictionary(from: error.content)
            XCTAssertEqual(json["status"] as? String, "partial_failure",
                "A dispatched payload followed by a hard failure must not report a blanket 'failed'")

            let message = json["message"] as? String ?? ""
            XCTAssertTrue(message.contains("file 'x.jpg'"),
                "The message must name the already-dispatched file; got: \(message)")
            XCTAssertTrue(message.contains("text message"),
                "The message must name the failed payload; got: \(message)")
            XCTAssertFalse(message.contains("/tmp/"),
                "The breakdown must name files by filename only, never a full path")
        }

        XCTAssertEqual(stub.invocations.count, 2,
            "Both payloads should have been attempted before the failure stopped the loop")
    }

    // When the very first payload fails, nothing was dispatched. The response
    // stays a plain "failed", and later payloads are never attempted.
    func testFirstPayloadFailureReturnsPlainFailedAndStopsSending() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        // Payload 0 (the file) hard-fails immediately.
        stub.queuedResults = [.failure(SendFailure(.messagesAppUnavailable, disposition: .notStarted))]

        let tool = SendTool(
            db: fixture.database(),
            resolver: makeSeededResolver(),
            runner: stub,
            verifier: fastVerifier(fixture: fixture)
        )

        do {
            _ = try await tool.execute(args: [
                "to": .string("+15550000001"),
                "text": .string("Hello Alice"),
                "file_paths": .array([.string("/tmp/x.jpg")]),
            ])
            XCTFail("Expected ToolError when the first payload fails")
        } catch let error as ToolError {
            let json = try decodeJSONDictionary(from: error.content)
            XCTAssertEqual(json["status"] as? String, "failed",
                "Nothing was dispatched, so this stays a plain 'failed', not 'partial_failure'")
        }

        XCTAssertEqual(stub.invocations.count, 1,
            "The loop must stop at the first hard failure; the text must never be attempted")
    }

    // A soft transfer outcome is not a hard failure: sending continues, and the
    // aggregate stays pending_confirmation. Unchanged behavior, now locked down.
    func testSoftPendingKeepsSendingRemainingPayloads() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        // Two files: the first reports a pending transfer, the second succeeds.
        stub.queuedResults = [.failure(SendFailure(.transferPending("a.jpg"), disposition: .mayHaveCompleted)), .success(())]

        let tool = SendTool(
            db: fixture.database(),
            resolver: makeSeededResolver(),
            runner: stub,
            verifier: fastVerifier(fixture: fixture)
        )

        let contents = try await tool.execute(args: [
            "to": .string("+15550000001"),
            "file_paths": .array([.string("/tmp/a.jpg"), .string("/tmp/b.jpg")]),
        ])

        let json = try decodeJSONDictionary(from: contents)
        XCTAssertEqual(json["status"] as? String, "pending_confirmation",
            "A pending transfer is a soft outcome and must not become a hard failure")
        XCTAssertEqual(stub.invocations.count, 2,
            "A soft outcome must not stop the loop; the second file must still be sent")
    }

    // MARK: - Disposition and retry_safe (plan 079)

    func testConfirmedSendReportsCompletedNotRetrySafe() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        stub.nextResult = .success(())
        try fixture.insertMessage(
            rowId: 130, guid: "msg-guid-079-confirm", text: "Hello Alice",
            date: AppleTime.fromDate(Date()), isFromMe: true, error: 0, isSent: 0
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 130)
        let tool = SendTool(
            db: fixture.database(),
            resolver: makeSeededResolver(),
            runner: stub,
            verifier: fastVerifier(fixture: fixture)
        )
        let json = try decodeJSONDictionary(from: try await tool.execute(args: [
            "to": .string("+15550000001"),
            "text": .string("Hello Alice"),
        ]))
        XCTAssertEqual(json["status"] as? String, "confirmed")
        XCTAssertEqual(json["disposition"] as? String, "completed")
        XCTAssertEqual(json["retry_safe"] as? Bool, false)
    }

    func testUncertainSendReportsCompletedNotRetrySafe() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        stub.nextResult = .success(())
        let tool = SendTool(
            db: fixture.database(),
            resolver: makeSeededResolver(),
            runner: stub,
            verifier: fastVerifier(fixture: fixture)
        )
        let json = try decodeJSONDictionary(from: try await tool.execute(args: [
            "to": .string("+15550000001"),
            "text": .string("Hello Alice"),
        ]))
        XCTAssertEqual(json["status"] as? String, "uncertain")
        XCTAssertEqual(json["disposition"] as? String, "completed")
        XCTAssertEqual(json["retry_safe"] as? Bool, false)
    }

    func testNotStartedFailureIsRetrySafe() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        stub.nextResult = .failure(SendFailure(.chatNotFound("x"), disposition: .notStarted))
        let tool = SendTool(db: fixture.database(), resolver: makeSeededResolver(), runner: stub)
        do {
            _ = try await tool.execute(args: [
                "to": .string("+15550000001"),
                "text": .string("Hello"),
            ])
            XCTFail("expected failed")
        } catch let error as ToolError {
            let json = try decodeJSONDictionary(from: error.content)
            XCTAssertEqual(json["status"] as? String, "failed")
            XCTAssertEqual(json["disposition"] as? String, "not_started")
            XCTAssertEqual(json["retry_safe"] as? Bool, true)
        }
    }

    func testMayHaveCompletedFailureIsNotRetrySafe() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        stub.nextResult = .failure(SendFailure(.timeout, disposition: .mayHaveCompleted))
        let tool = SendTool(db: fixture.database(), resolver: makeSeededResolver(), runner: stub)
        do {
            _ = try await tool.execute(args: [
                "to": .string("+15550000001"),
                "text": .string("Hello"),
            ])
            XCTFail("expected failed")
        } catch let error as ToolError {
            let json = try decodeJSONDictionary(from: error.content)
            XCTAssertEqual(json["status"] as? String, "failed")
            XCTAssertEqual(json["disposition"] as? String, "may_have_completed")
            XCTAssertEqual(json["retry_safe"] as? Bool, false)
        }
    }

    func testPartialFailureIsNeverRetrySafe() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        stub.queuedResults = [
            .success(()),
            .failure(SendFailure(.messagesAppUnavailable, disposition: .notStarted)),
        ]
        let tool = SendTool(
            db: fixture.database(),
            resolver: makeSeededResolver(),
            runner: stub,
            verifier: fastVerifier(fixture: fixture)
        )
        do {
            _ = try await tool.execute(args: [
                "to": .string("+15550000001"),
                "text": .string("Hello Alice"),
                "file_paths": .array([.string("/tmp/x.jpg")]),
            ])
            XCTFail("expected partial_failure")
        } catch let error as ToolError {
            let json = try decodeJSONDictionary(from: error.content)
            XCTAssertEqual(json["status"] as? String, "partial_failure")
            XCTAssertEqual(json["disposition"] as? String, "not_started")
            XCTAssertEqual(json["retry_safe"] as? Bool, false)
        }
    }

    func testFailedDeliveryRowIsRetrySafe() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        stub.nextResult = .success(())
        try fixture.insertMessage(
            rowId: 131, guid: "msg-guid-079-fail-row", text: "Hello Alice",
            date: AppleTime.fromDate(Date()), isFromMe: true, error: 22, isSent: 0
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 131)
        let tool = SendTool(
            db: fixture.database(),
            resolver: makeSeededResolver(),
            runner: stub,
            verifier: fastVerifier(fixture: fixture)
        )
        do {
            _ = try await tool.execute(args: [
                "to": .string("+15550000001"),
                "text": .string("Hello Alice"),
            ])
            XCTFail("expected failed_delivery")
        } catch let error as ToolError {
            let json = try decodeJSONDictionary(from: error.content)
            XCTAssertEqual(json["status"] as? String, "failed_delivery")
            XCTAssertEqual(json["disposition"] as? String, "completed")
            XCTAssertEqual(json["retry_safe"] as? Bool, true)
        }
    }

    func testValidationErrorIsNotStartedRetrySafe() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        let tool = SendTool(db: fixture.database(), resolver: makeSeededResolver(), runner: stub)
        do {
            _ = try await tool.execute(args: [
                "text": .string("Hello"),
            ])
            XCTFail("expected failed")
        } catch let error as ToolError {
            let json = try decodeJSONDictionary(from: error.content)
            XCTAssertEqual(json["status"] as? String, "failed")
            XCTAssertEqual(json["disposition"] as? String, "not_started")
            XCTAssertEqual(json["retry_safe"] as? Bool, true)
        }
        XCTAssertTrue(stub.invocations.isEmpty)
    }

    func testAmbiguousIsNotStartedRetrySafe() throws {
        let encoded = try FormatUtils.encodeJSON(SendResponse.ambiguous(candidates: [
            RecipientCandidate(name: "Nick Jones", handle: "+15555550123", lastContact: "today"),
            RecipientCandidate(name: "Andrew Jones", handle: "+15555550124", lastContact: "never"),
        ]))
        let json = try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any]
        XCTAssertEqual(json?["status"] as? String, "ambiguous")
        XCTAssertEqual(json?["disposition"] as? String, "not_started")
        XCTAssertEqual(json?["retry_safe"] as? Bool, true)
    }
}

// MARK: - Decode helper (reuse pattern from existing tests)

private func decodeJSONDictionary(from contents: [Tool.Content]) throws -> [String: Any] {
    let text: String
    switch contents.first {
    case .text(let t, _, _):
        text = t
    default:
        throw NSError(domain: "SendToolExecuteTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected text content"])
    }
    let data = Data(text.utf8)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func decodeJSONDictionary(from error: ToolError) throws -> [String: Any] {
    return try decodeJSONDictionary(from: error.content)
}

// MARK: - Moved from PlaceholderTests.swift (plan 032)

final class SendToolExecutionTests: XCTestCase {
    func testSendSchemaDoesNotAdvertiseReplyTo() async throws {
        ToolHandlerRegistry.shared.resetForTesting()

        let server = Server(name: "test", version: "0")
        await ToolRegistry.registerAll(on: server, db: Database(), resolver: ContactResolver(seedCache: [:]))

        let tools = Dictionary(
            uniqueKeysWithValues: ToolHandlerRegistry.shared.getTools().map { ($0.name, $0) }
        )
        let send = try XCTUnwrap(tools["send"])
        guard case .object(let schema) = send.inputSchema,
              case .object(let properties) = schema["properties"] else {
            return XCTFail("Expected send inputSchema.properties to be an object")
        }
        XCTAssertNil(properties["reply_to"], "send schema must not advertise reply_to")
    }
}
