import XCTest
@testable import iMessageMax

final class AppleScriptRunnerValidationTests: XCTestCase {
    func testRunScriptPreservesUnicodeArguments() {
        let message = "Unicode test — “curly quotes” emoji: 🎳🔥\nLine 2"
        let result = AppleScriptRunner.runScriptForTesting(
            script: """
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
            XCTAssertEqual(output.trimmingCharacters(in: .newlines), message)
        }
    }

    func testSendFileToParticipantRejectsMissingFileBeforeAutomation() {
        let result = AppleScriptRunner.sendFileToParticipant(
            handle: "+19175551234",
            filePath: "/definitely/missing/file.png"
        )

        switch result {
        case .success:
            XCTFail("Expected file validation to fail")
        case .failure(let error):
            XCTAssertEqual(
                error.localizedDescription,
                "Could not read file at 'file.png'."
            )
        }
    }

    // MARK: - osascript stderr classification

    /// Verbatim stderr from a real failed send on 2026-08-07: a chat-route send
    /// to an `any;-;` service chat. AppleScript spells "can’t" with the
    /// typographic apostrophe, which the straight-form-only match missed, so
    /// this whole string reached the client instead of `.chatNotFound`.
    func testCurlyApostropheStderrClassifiesAsMissingTarget() {
        let stderr = "186:202: execution error: messages got an error: "
            + "can\u{2019}t get chat id \"any;-;+15555550123\". (-1728)"

        let error = AppleScriptRunner.classifySendStderr(
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
        let error = AppleScriptRunner.classifySendStderr(
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
        let error = AppleScriptRunner.classifySendStderr(
            "execution error: the file photo.png wasn\u{2019}t found. (-43)",
            sentFileName: "photo.png",
            missingTargetError: .chatNotFound("chat1")
        )

        XCTAssertEqual(error.localizedDescription, "Could not read file at 'photo.png'.")
    }

    func testCurlyApostropheDoesNotUnderstandClassifiesAsMissingTarget() {
        let error = AppleScriptRunner.classifySendStderr(
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
        let error = AppleScriptRunner.classifySendStderr(
            String(repeating: "z", count: 400) + "\nsecond line",
            sentFileName: "",
            missingTargetError: .chatNotFound("chat1")
        )

        XCTAssertEqual(error.localizedDescription, "Send failed: " + String(repeating: "z", count: 300))
        XCTAssertFalse(error.localizedDescription.contains("second line"))
    }

    // Plan 049: the classifier lowercases stderr before matching, so the scrub
    // literal must be lowercase too. A mixed-case "/Users/" literal never
    // matched and the operator's home directory reached the client verbatim.
    func testHomeDirectoryPathInStderrClassifiesAsPathRejected() {
        let stderr = "execution error: Messages got an error: Can\u{2019}t get file "
            + "\"/Users/alice/Desktop/x.jpg\". (-1728)"

        let error = AppleScriptRunner.classifySendStderr(
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

    func testSendTextToParticipantRejectsOverlongMessage() {
        let longMessage = String(repeating: "a", count: 20_001)
        let result = AppleScriptRunner.sendTextToParticipant(
            handle: "+19175551234",
            message: longMessage
        )

        switch result {
        case .success:
            XCTFail("Expected invalid params failure")
        case .failure(let error):
            XCTAssertEqual(
                error.localizedDescription,
                "Message too long (max 20,000 chars)"
            )
        }
    }

    func testPrepareTrackedOutgoingFileStagesInPicturesDirectoryWithOriginalName() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let sourceURL = tempDir.appendingPathComponent("imessage-max-source-test.txt")
        try "hello".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let prepared = try AppleScriptRunner.prepareTrackedOutgoingFile(
            sourcePath: sourceURL.path,
            existingOutgoingTransferStatuses: { trackingName in
                XCTAssertEqual(trackingName, "imessage-max-source-test.txt")
                return ["finished"]
            }
        )
        defer { try? FileManager.default.removeItem(at: prepared.fileURL.deletingLastPathComponent()) }

        XCTAssertNotEqual(prepared.fileURL.path, sourceURL.path)
        XCTAssertEqual(prepared.fileURL.pathExtension, "txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.fileURL.path))
        XCTAssertEqual(prepared.trackingName, "imessage-max-source-test.txt")
        XCTAssertEqual(prepared.fileURL.lastPathComponent, "imessage-max-source-test.txt")
        XCTAssertGreaterThanOrEqual(prepared.existingOutgoingTransferCount, 0)
        XCTAssertTrue(prepared.fileURL.path.contains("/Pictures/imessage-max-staging/"))
    }

    // Plan 024: staged copies are deleted at terminal transfer states, so a
    // duplicate of the user's file does not linger in ~/Pictures for 48h.
    func testRemoveStagedDirectoryDeletesOnlyItsOwnDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let sourceURL = tempDir.appendingPathComponent("imessage-max-cleanup-test.txt")
        try "hello".write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let prepared = try AppleScriptRunner.prepareTrackedOutgoingFile(
            sourcePath: sourceURL.path,
            existingOutgoingTransferStatuses: { _ in ["finished"] }
        )
        // Safety net if the assertions below fail before removal happens.
        defer { try? FileManager.default.removeItem(at: prepared.fileURL.deletingLastPathComponent()) }

        let stagedDirectory = prepared.fileURL.deletingLastPathComponent()
        // The UUID directory's parent is the staging root.
        let stagingRoot = stagedDirectory.deletingLastPathComponent()

        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.fileURL.path),
            "Precondition: the staged copy exists before removal")

        AppleScriptRunner.removeStagedDirectory(for: prepared)

        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.fileURL.path),
            "The staged copy must be deleted at a terminal transfer state")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedDirectory.path),
            "The per-send UUID directory must be deleted too, not just the file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingRoot.path),
            "The shared staging root must survive. Only this send's directory is removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path),
            "The user's original file must never be touched")
    }

    // The guard is what makes the helper safe: a PreparedOutgoingFile whose
    // fileURL somehow points outside the staging root must be refused outright.
    func testRemoveStagedDirectoryRefusesPathsOutsideStagingRoot() throws {
        let outsideDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imessage-max-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }

        let outsideFile = outsideDirectory.appendingPathComponent("precious.txt")
        try "do not delete".write(to: outsideFile, atomically: true, encoding: .utf8)

        let forged = AppleScriptRunner.PreparedOutgoingFile(
            fileURL: outsideFile,
            trackingName: "precious.txt",
            existingOutgoingTransferCount: 0
        )

        AppleScriptRunner.removeStagedDirectory(for: forged)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path),
            "The staging-root guard must refuse to delete anything outside the staging root")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideDirectory.path),
            "The containing directory outside the staging root must survive as well")
    }

    func testTransferObservationFinishedWins() {
        let observation = AppleScriptRunner.interpretTransferStatuses(["waiting", "finished"])

        switch observation {
        case .finished:
            break
        default:
            XCTFail("Expected finished observation")
        }
    }

    func testTransferObservationFailedWins() {
        let observation = AppleScriptRunner.interpretTransferStatuses(["waiting", "failed"])

        switch observation {
        case .failed:
            break
        default:
            XCTFail("Expected failed observation")
        }
    }

    func testTransferObservationPendingForWaitingStatuses() {
        let observation = AppleScriptRunner.interpretTransferStatuses(["waiting", "transferring"])

        switch observation {
        case .pending:
            break
        default:
            XCTFail("Expected pending observation")
        }
    }

    func testTransferObservationUnknownForEmptyStatuses() {
        let observation = AppleScriptRunner.interpretTransferStatuses([])

        switch observation {
        case .unknown:
            break
        default:
            XCTFail("Expected unknown observation")
        }
    }
}
