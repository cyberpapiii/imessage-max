import XCTest
@testable import iMessageMax

// Tests for AsyncTimeout helper and the bounded send-confirmation elicitation path.
// Plan 014: Bound the send-confirmation elicitation wait.

final class ElicitationTimeoutTests: XCTestCase {

    // MARK: - AsyncTimeout unit tests

    func testTimeoutReturnsNilWhenOperationHangs() async {
        let start = ContinuousClock().now
        let result = await AsyncTimeout.withTimeout(.milliseconds(50)) {
            try await Task.sleep(for: .seconds(30))
            return 1
        }
        let elapsed = ContinuousClock().now - start

        XCTAssertNil(result, "Should return nil when operation exceeds the timeout")
        XCTAssertLessThan(elapsed, .seconds(1), "Should complete well under 1 second despite 30s sleep")
    }

    func testFastOperationWinsOverTimeout() async {
        let start = ContinuousClock().now
        let result: Int? = await AsyncTimeout.withTimeout(.seconds(5)) {
            return 42
        }
        let elapsed = ContinuousClock().now - start

        XCTAssertEqual(result, 42, "Fast operation should return its value before the timeout fires")
        XCTAssertLessThan(elapsed, .seconds(1), "Should complete well under 1 second")
    }

    func testThrowingOperationReturnsNil() async {
        struct TestError: Error {}

        let result: Int? = await AsyncTimeout.withTimeout(.seconds(5)) {
            throw TestError()
        }

        XCTAssertNil(result, "Throwing operation should be reported as nil (same as timeout)")
    }

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

    /// withTimeout cancels the operation task on deadline so the operation
    /// exits soon after nil is returned to the caller.
    func testTimeoutCancelsOperationTask() async {
        let exitedExpectation = expectation(description: "operation exits after cancellation")

        let result: Int? = await AsyncTimeout.withTimeout(.milliseconds(50)) {
            while !Task.isCancelled {
                await AsyncTimeout.sleep(.milliseconds(10))
            }
            exitedExpectation.fulfill()
            return 99
        }

        XCTAssertNil(result, "withTimeout should return nil when the deadline fires first")
        await fulfillment(of: [exitedExpectation], timeout: 1.0)
    }

    // MARK: - End-to-end graceful path

    /// Pins the existing graceful path that the timeout now also routes to:
    /// a chat-route send without `confirm: true` and `server: nil` should return
    /// `pending_confirmation` with re-call guidance, not hang or crash.
    func testHangingConfirmationYieldsPendingStatus() async throws {
        let fixture = try makeSendFixture014()
        let stub = StubScriptRunner()

        let tool = SendTool(
            db: fixture.database(),
            resolver: makeSeededResolver(),
            runner: stub
            // server: nil (default) — confirmSendWithClientIfAvailable short-circuits to .unavailable
        )

        // chat_id send without confirm: true → shouldConfirmSend returns true → .unavailable → .pending
        let contents = try await tool.execute(args: [
            "chat_id": .string("chat2"),
            "text": .string("Hello group"),
            // confirm omitted → defaults to false
        ])

        let json = try decodeJSONDictionary(from: contents)
        XCTAssertEqual(json["status"] as? String, "pending_confirmation",
            "With server nil (no elicitation available) the send should enter the pending state, not hang")
        let message = json["message"] as? String ?? ""
        XCTAssertTrue(
            message.contains("confirm: true") || message.contains("confirm"),
            "Pending message should instruct the agent to re-call with confirm: true; got: \(message)"
        )

        XCTAssertTrue(stub.invocations.isEmpty, "No script invocation should have occurred for a pending send")
    }
}

// MARK: - Fixture for plan-014 tests

private func makeSendFixture014() throws -> ToolTestDatabase {
    let fixture = try ToolTestDatabase(name: "send-014")

    try fixture.insertHandle(rowId: 1, handle: "+15550000001")  // Alice
    try fixture.insertHandle(rowId: 2, handle: "+15550000002")  // Bob

    // Chat 1: DM with Alice
    try fixture.insertChat(rowId: 1, guid: "iMessage;-;alice-014-guid")
    try fixture.joinChatHandle(chatId: 1, handleId: 1)

    // Chat 2: group chat with Alice and Bob
    try fixture.insertChat(rowId: 2, guid: "iMessage;+;group-014-guid", displayName: "Group Chat")
    try fixture.joinChatHandle(chatId: 2, handleId: 1)
    try fixture.joinChatHandle(chatId: 2, handleId: 2)

    return fixture
}
