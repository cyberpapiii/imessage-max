import XCTest
import MCP
@testable import iMessageMax

final class StubScriptRunner: ScriptRunning, @unchecked Sendable {
    enum Call: Equatable {
        case textToParticipant(handle: String, message: String)
        case fileToParticipant(handle: String, filePath: String)
        case textToChat(guid: String, message: String)
        case fileToChat(guid: String, filePath: String)
    }

    private(set) var invocations: [Call] = []
    var nextResult: Result<Void, SendFailure> = .success(())
    var queuedResults: [Result<Void, SendFailure>] = []
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

private func makeSendFixture() throws -> ToolTestDatabase {
    let fixture = try ToolTestDatabase(name: "send-execute")

    try fixture.insertHandle(rowId: 1, handle: "+15550000001")
    try fixture.insertHandle(rowId: 2, handle: "+15550000002")

    try fixture.insertChat(rowId: 1, guid: "iMessage;-;alice-send-guid")
    try fixture.joinChatHandle(chatId: 1, handleId: 1)

    try fixture.insertChat(rowId: 2, guid: "iMessage;+;group-send-guid", displayName: "Group Chat")
    try fixture.joinChatHandle(chatId: 2, handleId: 1)
    try fixture.joinChatHandle(chatId: 2, handleId: 2)

    return fixture
}

private func fastVerifier(fixture: ToolTestDatabase) -> SendVerifier {
    SendVerifier(db: fixture.database(), maxAttempts: 1, pollInterval: .milliseconds(0))
}

final class SendToolExecuteTests: XCTestCase {

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

        let contents = try await tool.execute(args: [
            "to": .string("+15550000001"),
            "text": .string("Hello Alice"),
        ])

        let json = try decodeJSONDictionary(from: contents)
        XCTAssertEqual(json["status"] as? String, "uncertain",
            "Without a matching DB row, status should be 'uncertain'")
        XCTAssertEqual(json["disposition"] as? String, "completed")
        XCTAssertEqual(json["retry_safe"] as? Bool, false)

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
                "Error field should contain the stub's error message; got \(String(describing: errorMsg))"
            )
            XCTAssertEqual(json["disposition"] as? String, "not_started")
            XCTAssertEqual(json["retry_safe"] as? Bool, true)
        }

        XCTAssertEqual(stub.invocations.count, 1, "Stub should have been called once before the failure was detected")
    }

    func testStubSendWithMatchingRowConfirms() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        stub.nextResult = .success(())

        let rowDate = AppleTime.fromDate(Date())
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

    func testRowInDifferentChatProducesMismatchStatus() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        stub.nextResult = .success(())

        let rowDate = AppleTime.fromDate(Date())
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

    func testStubSideEffectRowInDMConfirmsWithGroupPresent() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        stub.nextResult = .success(())
        stub.onSend = { _ in
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
            "Row written to the DM between send and verify must confirm; this exact setup previously produced a false mismatch")
        XCTAssertEqual(json["verified_message_guid"] as? String, "msg-guid-side-effect")
    }

    func testFailedRowReturnsFailedDeliveryStatus() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        stub.nextResult = .success(())

        let rowDate = AppleTime.fromDate(Date())
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
                "A row with error=22 is a verified delivery failure, not 'uncertain'")
            XCTAssertEqual(json["verified_message_guid"] as? String, "msg-guid-error-row",
                "The failed row's GUID is the evidence for the failure")
            XCTAssertEqual(json["disposition"] as? String, "completed")
            XCTAssertEqual(json["retry_safe"] as? Bool, true)
        }
    }

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

    func testNameMatchMissingFromMessagesIsRefusedAndNeverSends() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
        let resolver = ContactResolver(seedCache: ["+15550009999": "Zed Stranger"])
        let tool = SendTool(db: fixture.database(), resolver: resolver, runner: stub)

        let json = try await toolFailureBody {
            try await tool.execute(args: ["to": .string("Zed"), "text": .string("Hi")])
        }
        XCTAssertEqual(json["status"] as? String, "ambiguous")
        XCTAssertEqual(json["disposition"] as? String, "not_started")
        XCTAssertEqual(json["retry_safe"] as? Bool, true)
        XCTAssertTrue((json["message"] as? String ?? "").contains("no conversation in Messages"))
        let candidates = try decodeJSONArray(json["candidates"])
        XCTAssertEqual(candidates.compactMap { $0["handle"] as? String }, ["+15550009999"])
        XCTAssertTrue(stub.invocations.isEmpty, "a Contacts-only handle must not send")
    }

    func testRecipientNotFoundDoesNotInvokeRunner() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()

        let tool = SendTool(db: fixture.database(), resolver: makeSeededResolver(), runner: stub)

        do {
            _ = try await tool.execute(args: [
                "to": .string("+15559999999"),
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
            "Long text (over 500 characters) without confirm must send immediately")
        XCTAssertEqual(stub.invocations.count, 1, "Stub should have been invoked exactly once")
    }

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
                "\(label) must have no effect; the outcome should still be 'confirmed'")
            XCTAssertEqual(stub.invocations.count, 1,
                "Stub should have been invoked exactly once with \(label)")
        }
    }

    func testPartialFailureWhenLaterPayloadFails() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
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
            XCTAssertEqual(json["disposition"] as? String, "not_started")
            XCTAssertEqual(json["retry_safe"] as? Bool, false)
        }

        XCTAssertEqual(stub.invocations.count, 2,
            "Both payloads should have been attempted before the failure stopped the loop")
    }

    func testFirstPayloadFailureReturnsPlainFailedAndStopsSending() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
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

    func testSoftPendingKeepsSendingRemainingPayloads() async throws {
        let fixture = try makeSendFixture()
        let stub = StubScriptRunner()
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

    func testEarlierIdenticalTextDoesNotConfirmARetry() async throws {
        let fixture = try makeSendFixture()
        try insertOutbound(fixture, rowId: 50, text: "Hello Alice", date: Date())
        let stub = StubScriptRunner()
        let tool = SendTool(db: fixture.database(), resolver: makeSeededResolver(), runner: stub, verifier: fastVerifier(fixture: fixture))

        let json = try decodeJSONDictionary(from: try await tool.execute(args: [
            "to": .string("+15550000001"),
            "text": .string("Hello Alice"),
        ]))

        XCTAssertEqual(json["status"] as? String, "uncertain")
        XCTAssertNil(json["verified_message_guid"])
    }

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

private func insertOutbound(_ fixture: ToolTestDatabase, rowId: Int, text: String, date: Date) throws {
    try fixture.insertMessage(rowId: rowId, guid: "outbound-\(rowId)", text: text, date: AppleTime.fromDate(date), isFromMe: true)
    try fixture.joinChatMessage(chatId: 1, messageId: rowId)
}
