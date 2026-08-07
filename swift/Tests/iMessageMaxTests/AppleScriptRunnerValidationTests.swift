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
                "Could not read file at '/definitely/missing/file.png'."
            )
        }
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
            "The shared staging root must survive — only this send's directory is removed")
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
            XCTAssertTrue(true)
        default:
            XCTFail("Expected finished observation")
        }
    }

    func testTransferObservationFailedWins() {
        let observation = AppleScriptRunner.interpretTransferStatuses(["waiting", "failed"])

        switch observation {
        case .failed:
            XCTAssertTrue(true)
        default:
            XCTFail("Expected failed observation")
        }
    }

    func testTransferObservationPendingForWaitingStatuses() {
        let observation = AppleScriptRunner.interpretTransferStatuses(["waiting", "transferring"])

        switch observation {
        case .pending:
            XCTAssertTrue(true)
        default:
            XCTFail("Expected pending observation")
        }
    }

    func testTransferObservationUnknownForEmptyStatuses() {
        let observation = AppleScriptRunner.interpretTransferStatuses([])

        switch observation {
        case .unknown:
            XCTAssertTrue(true)
        default:
            XCTFail("Expected unknown observation")
        }
    }
}
