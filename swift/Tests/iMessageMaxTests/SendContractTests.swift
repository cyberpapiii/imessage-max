import XCTest
@testable import iMessageMax

// Tests for the agent-native send contract (plan 017) and the Dispatch-backed
// sleep helper (plan 015). Exact destinations send immediately without any
// confirmation gate; results are verified post-send via chat.db.

final class SendContractTests: XCTestCase {

    // MARK: - Dispatch-timer mechanism tests (plan 015)

    /// AsyncTimeout.sleep uses a Dispatch timer, not Task.sleep.
    /// Verifies the Dispatch-backed sleep fires within a sensible window.
    func testDispatchSleepCompletes() async {
        let start = ContinuousClock().now
        await AsyncTimeout.sleep(.milliseconds(50))
        let elapsed = ContinuousClock().now - start
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(40),
            "Dispatch sleep should last at least 40ms")
        XCTAssertLessThan(elapsed, .seconds(2),
            "Dispatch sleep should complete well under 2s")
    }

    // MARK: - Agent-native send contract (plan 017)

    /// A group-chat send targeted by exact chat_id with NO confirm flag sends
    /// immediately — no gate, no pending state, no interactive wait — and is
    /// verified post-send to `confirmed`.
    func testGroupChatSendWithoutConfirmSendsImmediately() async throws {
        let fixture = try makeSendContractFixture()
        let stub = StubScriptRunner()
        stub.nextResult = .success(())
        stub.onSend = {
            // Simulate Messages.app writing the outbound row to the group chat.
            try? fixture.insertMessage(
                rowId: 200, guid: "msg-guid-group-017", text: "Hello group",
                date: AppleTime.fromDate(Date()), isFromMe: true, error: 0, isSent: 0
            )
            try? fixture.joinChatMessage(chatId: 2, messageId: 200)
        }

        let tool = SendTool(
            db: fixture.database(),
            resolver: makeSeededResolver(),
            runner: stub,
            verifier: SendVerifier(db: fixture.database(), maxAttempts: 1, pollInterval: .milliseconds(0))
        )

        let start = ContinuousClock().now
        let contents = try await tool.execute(args: [
            "chat_id": .string("chat2"),
            "text": .string("Hello group"),
            // confirm omitted — sends must not gate on it.
        ])
        let elapsed = ContinuousClock().now - start

        let json = try decodeJSONDictionary(from: contents)
        XCTAssertEqual(json["status"] as? String, "confirmed",
            "Group chat send without confirm must send immediately and verify to 'confirmed'")
        XCTAssertEqual(stub.invocations.count, 1,
            "Stub runner should have been invoked exactly once")
        guard case .textToChat(let guid, _) = stub.invocations.first else {
            return XCTFail("Expected textToChat call, got \(String(describing: stub.invocations.first))")
        }
        XCTAssertEqual(guid, "iMessage;+;group-017-guid")
        XCTAssertLessThan(elapsed, .seconds(2),
            "Send must return synchronously without waiting on any interactive channel")
    }
}

// MARK: - Fixture

private func makeSendContractFixture() throws -> ToolTestDatabase {
    let fixture = try ToolTestDatabase(name: "send-contract-017")

    try fixture.insertHandle(rowId: 1, handle: "+15550000001")  // Alice
    try fixture.insertHandle(rowId: 2, handle: "+15550000002")  // Bob

    // Chat 1: DM with Alice
    try fixture.insertChat(rowId: 1, guid: "iMessage;-;alice-017-guid")
    try fixture.joinChatHandle(chatId: 1, handleId: 1)

    // Chat 2: group chat with Alice and Bob
    try fixture.insertChat(rowId: 2, guid: "iMessage;+;group-017-guid", displayName: "Group Chat")
    try fixture.joinChatHandle(chatId: 2, handleId: 1)
    try fixture.joinChatHandle(chatId: 2, handleId: 2)

    return fixture
}
