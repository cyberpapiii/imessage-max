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
    var nextResult: Result<Void, SendError> = .success(())

    func sendTextToParticipant(handle: String, message: String) -> Result<Void, SendError> {
        invocations.append(.textToParticipant(handle: handle, message: message))
        return nextResult
    }

    func sendFileToParticipant(handle: String, filePath: String) -> Result<Void, SendError> {
        invocations.append(.fileToParticipant(handle: handle, filePath: filePath))
        return nextResult
    }

    func sendTextToChat(guid: String, message: String) -> Result<Void, SendError> {
        invocations.append(.textToChat(guid: guid, message: message))
        return nextResult
    }

    func sendFileToChat(guid: String, filePath: String) -> Result<Void, SendError> {
        invocations.append(.fileToChat(guid: guid, filePath: filePath))
        return nextResult
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

        // DM to Alice by phone number; short text, single recipient → no confirmation required.
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

        // Sending to chat_id → chat target; confirm required for chat sends, so pass confirm: true.
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
        stub.nextResult = .failure(.failed("osascript error -1712"))

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

    // Pre-insert a matching outbound row (error=0) → verifier returns confirmed.
    // Uses a minimal fixture with ONLY the DM chat (Alice not in any other chat)
    // to avoid any join cross-product artefact from the group chat in makeSendFixture().
    // Row is inserted before execute() so its date falls within the 2s skew window
    // (date = now, sendTime = now + tiny delta; skew covers this).
    func testStubSendWithMatchingRowConfirms() async throws {
        // Minimal fixture: one handle, one DM chat. No group chats.
        let fixture = try ToolTestDatabase(name: "send-confirm")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 1, guid: "iMessage;-;alice-dm")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)

        let stub = StubScriptRunner()
        stub.nextResult = .success(())

        // Pre-insert the expected outbound row in chat 1 (Alice DM).
        // Date = now; sendTime is captured inside execute() a few ms later,
        // so the row falls within the 2s look-behind skew.
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
            "With a matching row (error=0) in the DB, status should be 'confirmed'")
        XCTAssertEqual(json["verified_message_guid"] as? String, "msg-guid-confirm",
            "verified_message_guid should carry the message GUID from chat.db")
        XCTAssertNotNil(json["verified_at"], "verified_at should be present for confirmed sends")
    }

    // Pre-insert a row with error=22 (measured failed-send pattern) → NOT confirmed.
    // Verifier must check error=0; a row with error=22 should yield "uncertain".
    // Also uses a minimal fixture (no group chat) for the same reason as the confirm test.
    func testFailedRowDoesNotConfirm() async throws {
        let fixture = try ToolTestDatabase(name: "send-error-row")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 1, guid: "iMessage;-;alice-dm-2")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)

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

        let contents = try await tool.execute(args: [
            "to": .string("+15550000001"),
            "text": .string("Hello Alice"),
        ])

        let json = try decodeJSONDictionary(from: contents)
        XCTAssertEqual(json["status"] as? String, "uncertain",
            "A row with error=22 must not confirm; verifier requires error=0 (§3 finding 3)")
    }

    func testRecipientNotFoundDoesNotInvokeRunner() async throws {
        // NOTE: The plan intended to test the 'ambiguous' path (two contacts matching a name
        // query) to prove that runner is never invoked before resolution completes.
        // However, resolveContactName() checks CNContactStore.authorizationStatus() before
        // searching the seeded cache; on this machine and in CI the status is notDetermined,
        // so name-based resolution always returns a 'failed' status rather than 'ambiguous'.
        // This test characterizes the same invariant — runner is never invoked when send
        // cannot resolve a recipient — via a path that does not require Contacts authorization:
        // a phone number that does not exist in the fixture DB.
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
