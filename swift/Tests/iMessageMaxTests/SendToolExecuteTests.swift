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

// MARK: - Tests

final class SendToolExecuteTests: XCTestCase {

    func testSendTextToKnownHandleInvokesParticipantSend() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        stub.nextResult = .success(())

        let tool = SendTool(db: fixture.database(), resolver: makeSeededResolver(), runner: stub)

        // DM to Alice by phone number; short text, single recipient → no confirmation required
        let contents = try await tool.execute(args: [
            "to": .string("+15550000001"),
            "text": .string("Hello Alice"),
        ])

        let json = try decodeJSONDictionary(from: contents)
        XCTAssertEqual(json["status"] as? String, "sent", "Response status should be 'sent'")

        XCTAssertEqual(stub.invocations.count, 1, "Stub should have been called exactly once")
        guard case .textToParticipant(let handle, let message) = stub.invocations.first else {
            return XCTFail("Expected textToParticipant call, got \(String(describing: stub.invocations.first))")
        }
        XCTAssertEqual(handle, "+15550000001", "Handle should be Alice's normalized phone number")
        XCTAssertEqual(message, "Hello Alice", "Message text should be passed through unchanged")
    }

    func testSendToChatIdTargetsChatGuidNotParticipant() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        stub.nextResult = .success(())

        let tool = SendTool(db: fixture.database(), resolver: makeSeededResolver(), runner: stub)

        // Sending to chat_id → chat target; confirm required for chat sends, so pass confirm: true
        let contents = try await tool.execute(args: [
            "chat_id": .string("chat2"),
            "text": .string("Hey group"),
            "confirm": .bool(true),
        ])

        let json = try decodeJSONDictionary(from: contents)
        XCTAssertEqual(json["status"] as? String, "sent", "Response status should be 'sent'")

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
