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
    /// Runs on every send before the result is returned, standing in for
    /// Messages.app writing its chat.db row. A throw fails the test.
    var onSend: ((SendPayload) throws -> Void)?

    private func takeResult() -> Result<Void, SendFailure> {
        queuedResults.isEmpty ? nextResult : queuedResults.removeFirst()
    }

    func send(_ payload: SendPayload, to target: SendTarget) async -> Result<Void, SendFailure> {
        switch (target, payload) {
        case (.participant(let handle, _), .text(let message)):
            invocations.append(.textToParticipant(handle: handle, message: message))
        case (.participant(let handle, _), .file(let path)):
            invocations.append(.fileToParticipant(handle: handle, filePath: path))
        case (.chat(let guid, _), .text(let message)):
            invocations.append(.textToChat(guid: guid, message: message))
        case (.chat(let guid, _), .file(let path)):
            invocations.append(.fileToChat(guid: guid, filePath: path))
        }
        do {
            try onSend?(payload)
        } catch {
            XCTFail("onSend failed: \(error)")
        }
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

    // A dispatched send with no matching chat.db row is "uncertain".
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
            "Without a matching DB row, status should be 'uncertain'")
        // Something was dispatched, so a retry could duplicate it.
        XCTAssertEqual(json["disposition"] as? String, "completed")
        XCTAssertEqual(json["retry_safe"] as? Bool, false)

        XCTAssertEqual(stub.invocations.count, 1, "Stub should have been called exactly once")
        guard case .textToParticipant(let handle, let message) = stub.invocations.first else {
            return XCTFail("Expected textToParticipant call, got \(String(describing: stub.invocations.first))")
        }
        XCTAssertEqual(handle, "+15550000001", "Handle should be Alice's normalized phone number")
        XCTAssertEqual(message, "Hello Alice", "Message text should be passed through unchanged")
    }

    // A group targeted by exact chat_id sends at once, with no confirm flag,
    // to the chat's guid, and verifies against the group.
    func testSendToChatIdTargetsChatGuidNotParticipant() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        stub.nextResult = .success(())
        stub.onSend = { _ in
            try fixture.insertMessage(
                rowId: 200, guid: "msg-guid-group", text: "Hey group",
                date: AppleTime.fromDate(Date()), isFromMe: true, error: 0, isSent: 0
            )
            try fixture.joinChatMessage(chatId: 2, messageId: 200)
        }

        let tool = SendTool(
            db: fixture.database(),
            resolver: makeSeededResolver(),
            runner: stub,
            verifier: fastVerifier(fixture: fixture)
        )

        let contents = try await tool.execute(args: [
            "chat_id": .string("chat2"),
            "text": .string("Hey group"),
        ])

        let json = try decodeJSONDictionary(from: contents)
        XCTAssertEqual(json["status"] as? String, "confirmed")
        XCTAssertEqual(json["chat_id"] as? String, "chat2")

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
            XCTFail("Expected ToolFailure to be thrown for failed send")
        } catch let error as ToolFailure {
            let json = try decodeJSONDictionary(from: error.content)
            XCTAssertEqual(json["status"] as? String, "failed", "Status should be 'failed' when script errors")
            let errorMsg = json["error"] as? String
            XCTAssertTrue(
                errorMsg?.contains("osascript error") == true,
                "Error field should surface the stub's error message; got \(String(describing: errorMsg))"
            )
            XCTAssertEqual(json["disposition"] as? String, "not_started")
            XCTAssertEqual(json["retry_safe"] as? Bool, true)
        }

        XCTAssertEqual(stub.invocations.count, 1, "Stub should have been called once before the failure was detected")
    }

    // A matching outbound row (error=0) in the DM confirms the send, even
    // though Alice is also in the group chat.
    func testStubSendWithMatchingRowConfirms() async throws {
        let fixture = try makeSendFixture()  // DM chat 1 (Alice) + group chat 2 (Alice+Bob)
        let stub = StubScriptRunner()
        stub.nextResult = .success(())

        // The expected outbound row in chat 1 (Alice DM).
        let rowDate = AppleTime.fromDate(Date())
        // Messages.app writes the row during the send, after the baseline.
        stub.onSend = { _ in
            try fixture.insertMessage(
                rowId: 100, guid: "msg-guid-confirm", text: "Hello Alice",
                date: rowDate, isFromMe: true, error: 0, isSent: 0
            )
            try fixture.joinChatMessage(chatId: 1, messageId: 100)
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
            "With a matching row (error=0) in the DM, status should be 'confirmed' even when the handle is also in a group chat")
        XCTAssertEqual(json["verified_message_guid"] as? String, "msg-guid-confirm",
            "verified_message_guid should carry the message GUID from chat.db")
        XCTAssertNotNil(json["verified_at"], "verified_at should be present for confirmed sends")
        XCTAssertEqual(json["disposition"] as? String, "completed")
        XCTAssertEqual(json["retry_safe"] as? Bool, false)
        let chat = try XCTUnwrap(json["chat"] as? [String: Any])
        XCTAssertEqual(chat["id"] as? String, "chat1")
        XCTAssertEqual(json["delivered_to"] as? [String], ["Alice Smith"])
    }

    // Same setup as testStubSendWithMatchingRowConfirms, but the matching row lands
    // in the GROUP (chat 2) while the send targets Alice's DM (chat 1). The verifier
    // finds the row through Alice's handle, sees it is not in the intended chat, and
    // the tool must surface "mismatch" as a ToolFailure so an agent never treats it as
    // confirmed.
    func testRowInDifferentChatProducesMismatchStatus() async throws {
        let fixture = try makeSendFixture()  // DM chat 1 (Alice) + group chat 2 (Alice+Bob)
        let stub = StubScriptRunner()
        stub.nextResult = .success(())

        let rowDate = AppleTime.fromDate(Date())
        // Messages.app writes the row during the send, after the baseline.
        stub.onSend = { _ in
            try fixture.insertMessage(
                rowId: 103, guid: "msg-guid-mismatch", text: "Hello Alice",
                date: rowDate, isFromMe: true, error: 0, isSent: 0
            )
            try fixture.joinChatMessage(chatId: 2, messageId: 103)
        }

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
            XCTFail("Expected ToolFailure for a routing mismatch")
        } catch let error as ToolFailure {
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

    // The row lands in the DM during the send call, as Messages.app writes
    // it, and verification confirms it with the group present.
    func testStubSideEffectRowInDMConfirmsWithGroupPresent() async throws {
        let fixture = try makeSendFixture()  // DM chat 1 (Alice) + group chat 2 (Alice+Bob)
        let stub = StubScriptRunner()
        stub.nextResult = .success(())
        stub.onSend = { _ in
            // Simulate Messages.app writing the outbound row to the DM at send time.
            try fixture.insertMessage(
                rowId: 102, guid: "msg-guid-side-effect", text: "Hello Alice",
                date: AppleTime.fromDate(Date()), isFromMe: true, error: 0, isSent: 0
            )
            try fixture.joinChatMessage(chatId: 1, messageId: 102)
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
    // and surfaces it as a ToolFailure. Uses the full multi-chat fixture.
    func testFailedRowReturnsFailedDeliveryStatus() async throws {
        let fixture = try makeSendFixture()  // DM chat 1 (Alice) + group chat 2 (Alice+Bob)
        let stub = StubScriptRunner()
        stub.nextResult = .success(())

        let rowDate = AppleTime.fromDate(Date())
        // Messages.app writes the row during the send, after the baseline.
        stub.onSend = { _ in
            try fixture.insertMessage(
                rowId: 101, guid: "msg-guid-error-row", text: "Hello Alice",
                date: rowDate, isFromMe: true, error: 22, isSent: 0
            )
            try fixture.joinChatMessage(chatId: 1, messageId: 101)
        }

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
            XCTFail("Expected ToolFailure for a verified delivery failure")
        } catch let error as ToolFailure {
            let json = try decodeJSONDictionary(from: error.content)
            XCTAssertEqual(json["status"] as? String, "failed_delivery",
                "A row with error=22 is a verified delivery failure, not 'uncertain' (§3 finding 3)")
            XCTAssertEqual(json["verified_message_guid"] as? String, "msg-guid-error-row",
                "The failed row's GUID is the evidence for the failure")
            // Delivery verifiably failed, so resending cannot duplicate it.
            XCTAssertEqual(json["disposition"] as? String, "completed")
            XCTAssertEqual(json["retry_safe"] as? Bool, true)
        }
    }

    // A name two contacts share is refused before anything is sent, with the
    // candidates to choose from.
    func testAmbiguousNameIsRefusedWithCandidates() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        let resolver = ContactResolver(seedCache: [
            "+15550000001": "Alice Smith",
            "+15550000002": "Alice Brown",
        ])
        let tool = SendTool(db: fixture.database(), resolver: resolver, runner: stub)

        let json = try await toolFailureBody {
            try await tool.execute(args: ["to": .string("Alice"), "text": .string("Hi")])
        }
        XCTAssertEqual(json["status"] as? String, "ambiguous")
        XCTAssertEqual(json["disposition"] as? String, "not_started")
        XCTAssertEqual(json["retry_safe"] as? Bool, true)
        let candidates = try decodeJSONArray(json["candidates"])
        XCTAssertEqual(Set(candidates.compactMap { $0["handle"] as? String }), ["+15550000001", "+15550000002"])
        XCTAssertTrue(stub.invocations.isEmpty, "an ambiguous destination must not send")
    }

    // An unknown number fails before the runner is touched.
    func testRecipientNotFoundDoesNotInvokeRunner() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()

        let tool = SendTool(db: fixture.database(), resolver: makeSeededResolver(), runner: stub)

        do {
            _ = try await tool.execute(args: [
                "to": .string("+15559999999"),  // not in the fixture DB
                "text": .string("Hi"),
            ])
            XCTFail("Expected ToolFailure for unresolvable recipient")
        } catch let error as ToolFailure {
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

    // MARK: - No confirmation gate

    // 501-char text with no confirm flag sends immediately.
    func testLongTextSendsWithoutConfirm() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        stub.nextResult = .success(())

        let longText = String(repeating: "a", count: 501)
        stub.onSend = { _ in
            try fixture.insertMessage(
                rowId: 111, guid: "msg-guid-long-017", text: longText,
                date: AppleTime.fromDate(Date()), isFromMe: true, error: 0, isSent: 0
            )
            try fixture.joinChatMessage(chatId: 1, messageId: 111)
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
            "Long text (>500 chars) without confirm must send immediately")
        XCTAssertEqual(stub.invocations.count, 1, "Stub should have been invoked exactly once")
    }

    // Every payload is validated before the first is dispatched, so an
    // overlong text stops the file that would go out ahead of it.
    func testOverlongTextAfterFileFailsBeforeAnythingIsSent() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        let tool = SendTool(db: fixture.database(), resolver: makeSeededResolver(), runner: stub)

        do {
            _ = try await tool.execute(args: [
                "to": .string("+15550000001"),
                "file_paths": .array([.string("/tmp/a.jpg")]),
                "text": .string(String(repeating: "a", count: 20_001)),
            ])
            XCTFail("Expected ToolFailure for an overlong message")
        } catch let error as ToolFailure {
            let json = try decodeJSONDictionary(from: error.content)
            XCTAssertEqual(json["status"] as? String, "failed")
            XCTAssertEqual(json["error"] as? String, "Message too long (max 20,000 chars)")
            XCTAssertEqual(json["disposition"] as? String, "not_started")
            XCTAssertEqual(json["retry_safe"] as? Bool, true)
        }
        XCTAssertTrue(stub.invocations.isEmpty, "Nothing may be dispatched when any payload is invalid")
    }

    func testOverlongRecipientHandleFailsBeforeAnythingIsSent() async throws {
        let fixture = try makeSendFixture()
        let longEmail = String(repeating: "a", count: 95) + "@x.com"
        try fixture.insertHandle(rowId: 3, handle: longEmail)
        let stub = StubScriptRunner()
        let tool = SendTool(db: fixture.database(), resolver: makeSeededResolver(), runner: stub)

        do {
            _ = try await tool.execute(args: [
                "to": .string(longEmail),
                "file_paths": .array([.string("/tmp/a.jpg")]),
                "text": .string("hi"),
            ])
            XCTFail("Expected ToolFailure for an overlong recipient")
        } catch let error as ToolFailure {
            let json = try decodeJSONDictionary(from: error.content)
            XCTAssertEqual(json["status"] as? String, "failed")
            XCTAssertEqual(json["error"] as? String, "Recipient too long")
            XCTAssertEqual(json["disposition"] as? String, "not_started")
        }
        XCTAssertTrue(stub.invocations.isEmpty)
    }

    // The deprecated confirm flag is inert: true, false and absent all send
    // to the exact chat at once and verify to "confirmed".
    func testConfirmFlagIsInert() async throws {
        let cases: [(confirm: Bool?, rowId: Int)] = [(true, 120), (false, 121), (nil, 122)]
        for (confirmValue, rowId) in cases {
            let guid = "msg-guid-inert-\(rowId)"
            let fixture = try makeSendFixture()
            let stub = StubScriptRunner()
            stub.nextResult = .success(())
            stub.onSend = { _ in
                try fixture.insertMessage(
                    rowId: rowId, guid: guid, text: "Hello Alice",
                    date: AppleTime.fromDate(Date()), isFromMe: true, error: 0, isSent: 0
                )
                try fixture.joinChatMessage(chatId: 1, messageId: rowId)
            }

            let tool = SendTool(
                db: fixture.database(),
                resolver: makeSeededResolver(),
                runner: stub,
                verifier: fastVerifier(fixture: fixture)
            )

            var args: [String: Value] = [
                "chat_id": .string("chat1"),
                "text": .string("Hello Alice"),
            ]
            args["confirm"] = confirmValue.map { .bool($0) }
            let contents = try await tool.execute(args: args)

            let json = try decodeJSONDictionary(from: contents)
            let label = confirmValue.map { "confirm: \($0)" } ?? "no confirm"
            XCTAssertEqual(json["status"] as? String, "confirmed",
                "\(label) must be inert; outcome should be identical 'confirmed'")
            XCTAssertEqual(stub.invocations.count, 1,
                "Stub should have been invoked exactly once with \(label)")
        }
    }

    // MARK: - Partial multi-payload send reporting

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
            XCTFail("Expected ToolFailure for a partial send failure")
        } catch let error as ToolFailure {
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
            // The failed payload never started, but the earlier one went out.
            XCTAssertEqual(json["disposition"] as? String, "not_started")
            XCTAssertEqual(json["retry_safe"] as? Bool, false)
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
            XCTFail("Expected ToolFailure when the first payload fails")
        } catch let error as ToolFailure {
            let json = try decodeJSONDictionary(from: error.content)
            XCTAssertEqual(json["status"] as? String, "failed",
                "Nothing was dispatched, so this stays a plain 'failed', not 'partial_failure'")
        }

        XCTAssertEqual(stub.invocations.count, 1,
            "The loop must stop at the first hard failure; the text must never be attempted")
    }

    // A soft transfer outcome is not a hard failure: sending continues, and the
    // aggregate stays pending_confirmation.
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

    // MARK: - Disposition and retry_safe

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
        } catch let error as ToolFailure {
            let json = try decodeJSONDictionary(from: error.content)
            XCTAssertEqual(json["status"] as? String, "failed")
            XCTAssertEqual(json["disposition"] as? String, "may_have_completed")
            XCTAssertEqual(json["retry_safe"] as? Bool, false)
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
        } catch let error as ToolFailure {
            let json = try decodeJSONDictionary(from: error.content)
            XCTAssertEqual(json["status"] as? String, "failed")
            XCTAssertEqual(json["disposition"] as? String, "not_started")
            XCTAssertEqual(json["retry_safe"] as? Bool, true)
        }
        XCTAssertTrue(stub.invocations.isEmpty)
    }

    // MARK: - Verification window

    /// A retry of the same text does not confirm against the earlier
    /// attempt's row.
    func testEarlierIdenticalTextDoesNotConfirmARetry() async throws {
        let fixture = try makeSendFixture()
        try insertOutbound(fixture, rowId: 50, text: "Hello Alice", date: Date())
        let stub = StubScriptRunner()   // this send writes no row
        let tool = SendTool(db: fixture.database(), resolver: makeSeededResolver(), runner: stub, verifier: fastVerifier(fixture: fixture))

        let json = try decodeJSONDictionary(from: try await tool.execute(args: [
            "to": .string("+15550000001"),
            "text": .string("Hello Alice"),
        ]))

        XCTAssertEqual(json["status"] as? String, "uncertain")
        XCTAssertNil(json["verified_message_guid"])
    }

    /// Files go first; a slow transfer can push the text's row well past a
    /// minute after the send began. It still confirms.
    func testTextAfterSlowFileTransferStillConfirms() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        stub.onSend = { payload in
            guard case .text(let text) = payload else { return }
            try insertOutbound(fixture, rowId: 60, text: text, date: Date().addingTimeInterval(90))
        }
        let tool = SendTool(db: fixture.database(), resolver: makeSeededResolver(), runner: stub, verifier: fastVerifier(fixture: fixture))

        let json = try decodeJSONDictionary(from: try await tool.execute(args: [
            "to": .string("+15550000001"),
            "text": .string("Here is the file"),
            "file_paths": .array([.string("/tmp/a.jpg")]),
        ]))

        XCTAssertEqual(stub.invocations.count, 2)
        XCTAssertEqual(json["status"] as? String, "confirmed")
        XCTAssertEqual(json["verified_message_guid"] as? String, "outbound-60")
    }

    func testUncertainFollowUpNamesTheChatIdOrTheIntendedChat() {
        let withChat = SendResponse.uncertain(deliveredTo: ["A"], chat: ChatReference(id: "chat7", name: "Alice"))
        XCTAssertTrue(withChat.message?.hasSuffix("Use get_messages on chat7 to confirm.") == true, withChat.message ?? "nil")
        let withoutChat = SendResponse.uncertain(deliveredTo: ["A"], chat: nil)
        XCTAssertTrue(withoutChat.message?.hasSuffix("Use get_messages on the intended chat to confirm.") == true, withoutChat.message ?? "nil")
    }

    // MARK: - Cancellation

    /// A send cancelled after its first payload went out dispatches nothing
    /// further and reports partial_failure.
    func testCancelledSendDispatchesNothingFurther() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        stub.onSend = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let tool = SendTool(db: fixture.database(), resolver: makeSeededResolver(), runner: stub, verifier: fastVerifier(fixture: fixture))

        let call = Task {
            try await tool.execute(args: [
                "to": .string("+15550000001"),
                "text": .string("Hello"),
                "file_paths": .array([.string("/tmp/a.jpg"), .string("/tmp/b.jpg")]),
            ])
        }
        let json = try await toolFailureBody { try await call.value }
        XCTAssertEqual(json["status"] as? String, "partial_failure")
        XCTAssertEqual(json["disposition"] as? String, "not_started")
        XCTAssertEqual(json["retry_safe"] as? Bool, false)
        let message = json["message"] as? String ?? ""
        XCTAssertTrue(message.contains("file 'a.jpg'"), message)
        XCTAssertTrue((json["error"] as? String ?? "").contains("cancelled"), "\(json)")
        XCTAssertEqual(stub.invocations.count, 1, "nothing may be dispatched after cancellation")
    }

    /// Cancelled before the first payload: nothing is sent, and the answer
    /// says so.
    func testSendCancelledBeforeDispatchSendsNothing() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        let tool = SendTool(db: fixture.database(), resolver: makeSeededResolver(), runner: stub, verifier: fastVerifier(fixture: fixture))

        let call = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await tool.execute(args: ["to": .string("+15550000001"), "text": .string("Hello")])
        }
        let json = try await toolFailureBody { try await call.value }
        XCTAssertEqual(json["status"] as? String, "failed")
        XCTAssertEqual(json["disposition"] as? String, "not_started")
        XCTAssertTrue(stub.invocations.isEmpty)
    }
}

/// An outbound row in chat 1, guid `outbound-<rowId>`.
private func insertOutbound(_ fixture: ToolTestDatabase, rowId: Int, text: String, date: Date) throws {
    try fixture.insertMessage(rowId: rowId, guid: "outbound-\(rowId)", text: text, date: AppleTime.fromDate(date), isFromMe: true)
    try fixture.joinChatMessage(chatId: 1, messageId: rowId)
}
