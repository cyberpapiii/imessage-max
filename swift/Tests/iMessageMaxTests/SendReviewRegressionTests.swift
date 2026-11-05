import XCTest
import MCP
@testable import iMessageMax

/// Regressions for the send-path review (verification window, short codes,
/// chat names, staged-file cleanup). Never touches Messages.app.
final class SendReviewRegressionTests: XCTestCase {

    /// Records payloads and runs `onSend` for each, standing in for
    /// Messages.app writing its chat.db row during the dispatch.
    private final class RecordingRunner: ScriptRunning, @unchecked Sendable {
        var payloads: [SendPayload] = []
        var onSend: ((SendPayload) -> Void)?

        func send(_ payload: SendPayload, to target: SendTarget) async -> Result<Void, SendFailure> {
            payloads.append(payload)
            onSend?(payload)
            return .success(())
        }
    }

    private func makeFixture() throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "send-review")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 1, guid: "iMessage;-;alice-review-guid")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)
        return fixture
    }

    private func makeTool(_ fixture: ToolTestDatabase, runner: RecordingRunner) -> SendTool {
        SendTool(
            db: fixture.database(),
            resolver: makeSeededResolver(),
            runner: runner,
            verifier: SendVerifier(db: fixture.database(), maxAttempts: 1, pollInterval: .milliseconds(0))
        )
    }

    private func insertOutbound(_ fixture: ToolTestDatabase, rowId: Int, text: String, date: Date) {
        try? fixture.insertMessage(
            rowId: rowId, guid: "review-\(rowId)", text: text,
            date: AppleTime.fromDate(date), isFromMe: true, error: 0
        )
        try? fixture.joinChatMessage(chatId: 1, messageId: rowId)
    }

    // MARK: - 1. Verification baseline

    /// A quick retry of the same text must not confirm against the first
    /// attempt's row. The old 2 s look-behind matched it.
    func testEarlierIdenticalTextDoesNotConfirmARetry() async throws {
        let fixture = try makeFixture()
        insertOutbound(fixture, rowId: 50, text: "Hello Alice", date: Date())
        let runner = RecordingRunner()   // this send writes no row

        let json = try decodeJSONDictionary(from: try await makeTool(fixture, runner: runner).execute(args: [
            "to": .string("+15550000001"),
            "text": .string("Hello Alice"),
        ]))

        XCTAssertEqual(json["status"] as? String, "uncertain")
        XCTAssertNil(json["verified_message_guid"])
    }

    /// Files go first; a slow transfer can push the text's row well past the
    /// old 60 s forward window. It still confirms.
    func testTextAfterSlowFileTransferStillConfirms() async throws {
        let fixture = try makeFixture()
        let runner = RecordingRunner()
        runner.onSend = { [fixture] payload in
            guard case .text(let text) = payload else { return }
            self.insertOutbound(fixture, rowId: 60, text: text, date: Date().addingTimeInterval(90))
        }

        let json = try decodeJSONDictionary(from: try await makeTool(fixture, runner: runner).execute(args: [
            "to": .string("+15550000001"),
            "text": .string("Here is the file"),
            "file_paths": .array([.string("/tmp/review.jpg")]),
        ]))

        XCTAssertEqual(runner.payloads.count, 2)
        XCTAssertEqual(json["status"] as? String, "confirmed")
        XCTAssertEqual(json["verified_message_guid"] as? String, "review-60")
    }

    /// Two concurrent identical sends share one verifier. Each row confirms
    /// at most one of them.
    func testIdenticalSendsCannotConfirmTheSameRow() async throws {
        let fixture = try makeFixture()
        let verifier = SendVerifier(db: fixture.database(), maxAttempts: 1, pollInterval: .milliseconds(0))
        let baseline = try verifier.baseline()
        insertOutbound(fixture, rowId: 70, text: "Same text", date: Date())

        let first = try await verifier.verify(intendedChatId: 1, handle: nil, afterRowId: baseline, expectedText: "Same text")
        let second = try await verifier.verify(intendedChatId: 1, handle: nil, afterRowId: baseline, expectedText: "Same text")
        guard case .confirmed(let guid, _) = first else { return XCTFail("expected confirmed, got \(first)") }
        XCTAssertEqual(guid, "review-70")
        XCTAssertEqual(second, .notFound, "the row is already claimed by the first send")

        insertOutbound(fixture, rowId: 71, text: "Same text", date: Date())
        let third = try await verifier.verify(intendedChatId: 1, handle: nil, afterRowId: baseline, expectedText: "Same text")
        guard case .confirmed(let thirdGuid, _) = third else { return XCTFail("expected confirmed, got \(third)") }
        XCTAssertEqual(thirdGuid, "review-71", "the second send confirms its own row")
    }

    func testBaselineIsTheNewestMessageRowId() throws {
        let fixture = try makeFixture()
        let verifier = SendVerifier(db: fixture.database())
        XCTAssertEqual(try verifier.baseline(), 0)
        insertOutbound(fixture, rowId: 42, text: "x", date: Date())
        XCTAssertEqual(try verifier.baseline(), 42)
    }

    // MARK: - 2. Short codes

    /// A carrier short code with a conversation resolves to its handle. It
    /// used to skip the phone path and fail as a contact name.
    func testShortCodeResolvesToItsHandle() async throws {
        let fixture = try makeFixture()
        try fixture.insertHandle(rowId: 9, handle: "12345", service: "SMS")
        try fixture.insertChat(rowId: 9, guid: "SMS;-;12345")
        try fixture.joinChatHandle(chatId: 9, handleId: 9)

        let resolver = SendResolver(db: fixture.database(), resolver: ContactResolver(seedCache: [:]))
        guard case .success(let resolved) = await resolver.resolve(.recipient("12345")) else {
            return XCTFail("a short code with a conversation should resolve")
        }
        XCTAssertEqual(resolved.target, .participant(handle: "12345", chatId: 9))
    }

    // MARK: - 3. Chat name

    /// `to` and `chat_id` name the same unnamed 1:1 the same way, as every
    /// other tool does. `to` used to answer "chat1".
    func testChatNameMatchesAcrossEntryPoints() async throws {
        let fixture = try makeFixture()
        let resolver = SendResolver(db: fixture.database(), resolver: makeSeededResolver())

        guard case .success(let byRecipient) = await resolver.resolve(.recipient("+15550000001")),
              case .success(let byChatId) = await resolver.resolve(.chatId("chat1")) else {
            return XCTFail("both entry points should resolve")
        }
        let expected = try await ChatPage.identities(
            [ChatPage.Chat(id: 1, guid: "iMessage;-;alice-review-guid", explicitName: nil)],
            db: fixture.database(), resolver: makeSeededResolver()
        )[1]?.displayName
        XCTAssertEqual(byRecipient.chat?.name, "Alice Smith")
        XCTAssertEqual(byRecipient.chat?.name, byChatId.chat?.name)
        XCTAssertEqual(byRecipient.chat?.name, expected)
        XCTAssertEqual(byRecipient.chat?.id, "chat1")
    }

    /// A named chat keeps its explicit name on both paths.
    func testNamedChatKeepsItsNameViaRecipient() async throws {
        let fixture = try ToolTestDatabase(name: "send-review-named")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 1, guid: "iMessage;-;named", displayName: "  Alice Work  ")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)
        let resolver = SendResolver(db: fixture.database(), resolver: makeSeededResolver())

        guard case .success(let resolved) = await resolver.resolve(.recipient("+15550000001")) else {
            return XCTFail("should resolve")
        }
        XCTAssertEqual(resolved.chat?.name, "Alice Work")
    }

    // MARK: - 9. Uncertain follow-up wording (dead fallback removed)

    func testUncertainFollowUpNamesTheChatIdOrTheIntendedChat() {
        let withChat = SendResponse.uncertain(deliveredTo: ["A"], chat: ChatReference(id: "chat7", name: "Alice"))
        XCTAssertTrue(withChat.message?.hasSuffix("Use get_messages on chat7 to confirm.") == true)
        let withoutChat = SendResponse.uncertain(deliveredTo: ["A"], chat: nil)
        XCTAssertTrue(withoutChat.message?.hasSuffix("Use get_messages on the intended chat to confirm.") == true)
    }

    // MARK: - 4. Staged copy cleanup

    private struct StatusQueryFailure: Error {}

    private func stagedFile(root: URL) throws -> (OutgoingFileStager, OutgoingFileStager.StagedFile) {
        let source = root.deletingLastPathComponent().appendingPathComponent("review-source.txt")
        try Data("payload".utf8).write(to: source)
        let stager = OutgoingFileStager(root: root)
        let opened = try stager.openSource(source.path)
        defer { opened.close() }
        return (stager, try stager.stage(opened))
    }

    /// Waits on a Dispatch timer (no Task.sleep) for the staged directory to go.
    private func waitForRemoval(of staged: OutgoingFileStager.StagedFile) async -> Bool {
        let directory = staged.fileURL.deletingLastPathComponent().path
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: directory) { return true }
            await AsyncTimeout.sleep(.milliseconds(20))
        }
        return false
    }

    /// A failed status query used to leave the staged copy behind until the
    /// hourly sweep. Both catch arms now schedule its removal.
    func testFailedStatusQueryRemovesTheStagedCopy() async throws {
        let errors: [any Error] = [SendError.failed("status probe failed"), StatusQueryFailure()]
        for error in errors {
            // /private form: the stager refuses a root behind the /var symlink.
            let tmp = try XCTUnwrap(SecurePath.absoluteLexicalPath(FileManager.default.temporaryDirectory.path))
            let scratch = URL(fileURLWithPath: tmp, isDirectory: true)
                .appendingPathComponent("send-review-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let (stager, staged) = try stagedFile(root: scratch.appendingPathComponent("staging", isDirectory: true))
            XCTAssertTrue(FileManager.default.fileExists(atPath: staged.fileURL.path))

            let result = TransferMonitor.waitForCompletion(
                of: staged, baseline: 0, stager: stager,
                statusQuery: { _ in throw error },
                removalDelay: .zero
            )

            guard case .failure(let failure) = result else { return XCTFail("expected failure for \(error)") }
            XCTAssertEqual(failure.disposition, .mayHaveCompleted)
            let removed = await waitForRemoval(of: staged)
            XCTAssertTrue(removed, "staged copy should be removed after \(error)")
        }
    }
}
