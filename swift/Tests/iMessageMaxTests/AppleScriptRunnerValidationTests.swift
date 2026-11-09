import XCTest
@testable import iMessageMax

final class AppleScriptRunnerValidationTests: XCTestCase {
    private var createdPaths: [URL] = []

    override func tearDown() {
        for url in createdPaths {
            try? FileManager.default.removeItem(at: url)
        }
        createdPaths.removeAll()
        super.tearDown()
    }

    private func makeStager() -> OutgoingFileStager {
        let root = URL(fileURLWithPath: SecurePath.absoluteLexicalPath(FileManager.default.temporaryDirectory.path)!)
            .appendingPathComponent("xctest-imessage-max-staging-\(UUID().uuidString)", isDirectory: true)
        createdPaths.append(root)
        return OutgoingFileStager(root: root)
    }

    private func stage(_ path: String, with stager: OutgoingFileStager) throws -> OutgoingFileStager.StagedFile {
        let source = try stager.openSource(path)
        defer { source.close() }
        return try stager.stage(source)
    }

    func testRunScriptPreservesUnicodeArguments() {
        let message = "Unicode test — “curly quotes” emoji: 🎳🔥\nLine 2"
        let result = Osascript.run(
            """
            on run argv
                return item 1 of argv
            end run
            """,
            arguments: [message]
        )

        switch result {
        case .failure(let error):
            XCTFail("Expected Unicode round-trip to succeed: \(error.localizedDescription)")
        case .success(let output):
            XCTAssertEqual(output.terminationStatus, 0, output.stderr)
            XCTAssertEqual(output.stdout.trimmingCharacters(in: .newlines), message)
        }
    }

    func testSendFileToParticipantRejectsMissingFileBeforeAutomation() {
        let result = LiveScriptRunner(access: makeTestMessagesAccess(), stager: makeStager()).sendBlocking(
            .file(path: "/definitely/missing/file.png"),
            to: .participant(handle: "+19175551234", chatId: nil)
        )

        switch result {
        case .success:
            XCTFail("Expected file validation to fail")
        case .failure(let failure):
            XCTAssertEqual(
                failure.error.localizedDescription,
                "Could not read file at 'file.png'."
            )
            XCTAssertEqual(failure.disposition, .notStarted)
        }
    }

    /// Verbatim stderr from a real failed send: a chat-route send to an
    /// `any;-;` service chat. AppleScript spells "can’t" with the typographic
    /// apostrophe; it must still classify as `.chatNotFound` rather than
    /// reach the client as raw stderr.
    func testCurlyApostropheStderrClassifiesAsMissingTarget() {
        let stderr = "186:202: execution error: messages got an error: "
            + "can\u{2019}t get chat id \"any;-;+15555550123\". (-1728)"

        let error = SendScript.classifyStderr(
            stderr,
            sentFileName: "",
            missingTargetError: .chatNotFound("any;-;+15555550123")
        )

        XCTAssertEqual(
            error.localizedDescription,
            "Could not find chat 'any;-;+15555550123' in Messages.app."
        )
        XCTAssertFalse(
            error.localizedDescription.contains("186:202"),
            "Raw osascript line and column numbers must not reach the client"
        )
    }

    func testStraightApostropheStderrStillClassifiesAsMissingTarget() {
        let error = SendScript.classifyStderr(
            "execution error: messages got an error: can't get participant \"x\".",
            sentFileName: "",
            missingTargetError: .recipientNotFound("x")
        )

        XCTAssertEqual(
            error.localizedDescription,
            "Could not find recipient 'x' in Messages.app."
        )
    }

    func testCurlyApostropheFileNotFoundStderrReportsFilenameOnly() {
        let error = SendScript.classifyStderr(
            "execution error: the file photo.png wasn\u{2019}t found. (-43)",
            sentFileName: "photo.png",
            missingTargetError: .chatNotFound("chat1")
        )

        XCTAssertEqual(error.localizedDescription, "Could not read file at 'photo.png'.")
    }

    func testCurlyApostropheDoesNotUnderstandClassifiesAsMissingTarget() {
        let error = SendScript.classifyStderr(
            "execution error: messages doesn\u{2019}t understand the \"send\" message. (-1708)",
            sentFileName: "",
            missingTargetError: .chatNotFound("chat1")
        )

        XCTAssertEqual(
            error.localizedDescription,
            "Could not find chat 'chat1' in Messages.app."
        )
    }

    func testUnrecognizedStderrKeepsFirstLineClamped() {
        let error = SendScript.classifyStderr(
            String(repeating: "z", count: 400) + "\nsecond line",
            sentFileName: "",
            missingTargetError: .chatNotFound("chat1")
        )

        XCTAssertEqual(error.localizedDescription, "Send failed: " + String(repeating: "z", count: 300))
        XCTAssertFalse(error.localizedDescription.contains("second line"))
    }

    func testHomeDirectoryPathInStderrClassifiesAsPathRejected() {
        let stderr = "execution error: Messages got an error: Can\u{2019}t get file "
            + "\"/Users/alice/Desktop/x.jpg\". (-1728)"

        let error = SendScript.classifyStderr(
            stderr,
            sentFileName: "x.jpg",
            missingTargetError: .chatNotFound("chat1")
        )

        XCTAssertEqual(
            error.localizedDescription,
            "Send failed: Send failed. Check the server log for details."
        )
        XCTAssertFalse(error.localizedDescription.lowercased().contains("/users/"))
        XCTAssertFalse(error.localizedDescription.contains("alice"))
        XCTAssertFalse(error.localizedDescription.contains("imessage-max-staging"))
    }

    func testDefaultStagingRootIsInPicturesDirectory() {
        XCTAssertTrue(OutgoingFileStager().root.path.hasSuffix("/Pictures/imessage-max-staging"))
    }

    func testStageCopiesUnderRootWithOriginalName() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let sourceURL = tempDir.appendingPathComponent("imessage-max-source-test.txt")
        try "hello".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let stager = makeStager()
        let prepared = try stage(sourceURL.path, with: stager)

        XCTAssertNotEqual(prepared.fileURL.path, sourceURL.path)
        XCTAssertEqual(prepared.fileURL.pathExtension, "txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.fileURL.path))
        XCTAssertEqual(prepared.trackingName, "imessage-max-source-test.txt")
        XCTAssertEqual(prepared.fileURL.lastPathComponent, "imessage-max-source-test.txt")
        XCTAssertTrue(prepared.fileURL.path.hasPrefix(stager.root.path + "/"))
    }

    func testRemoveStagedDirectoryDeletesOnlyItsOwnDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let sourceURL = tempDir.appendingPathComponent("imessage-max-cleanup-test.txt")
        try "hello".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let stager = makeStager()
        let prepared = try stage(sourceURL.path, with: stager)

        let stagedDirectory = prepared.fileURL.deletingLastPathComponent()
        let stagingRoot = stagedDirectory.deletingLastPathComponent()

        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.fileURL.path),
            "Precondition: the staged copy exists before removal")

        stager.remove(prepared)

        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.fileURL.path),
            "The staged copy must be deleted at a terminal transfer state")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedDirectory.path),
            "The per-send UUID directory must be deleted too, not just the file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingRoot.path),
            "The shared staging root must survive. Only this send's directory is removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path),
            "The user's original file must never be touched")
    }

    func testTransferObservationFinishedWins() {
        let observation = TransferMonitor.interpret(["waiting", "finished"])

        switch observation {
        case .finished:
            break
        default:
            XCTFail("Expected finished observation")
        }
    }

    func testTransferObservationFailedWins() {
        let observation = TransferMonitor.interpret(["waiting", "failed"])

        switch observation {
        case .failed:
            break
        default:
            XCTFail("Expected failed observation")
        }
    }

    func testTransferObservationPendingForWaitingStatuses() {
        let observation = TransferMonitor.interpret(["waiting", "transferring"])

        switch observation {
        case .pending:
            break
        default:
            XCTFail("Expected pending observation")
        }
    }

    func testTransferObservationUnknownForEmptyStatuses() {
        let observation = TransferMonitor.interpret([])

        switch observation {
        case .unknown:
            break
        default:
            XCTFail("Expected unknown observation")
        }
    }
}
