import XCTest
@testable import iMessageMax

final class AppleScriptStagingTests: XCTestCase {
    private var createdPaths: [URL] = []

    override func tearDown() {
        for url in createdPaths {
            try? FileManager.default.removeItem(at: url)
        }
        createdPaths.removeAll()
        super.tearDown()
    }

    func testRemoveStagedDirectoryRefusesPathsOutsideRoot() throws {
        let outsideDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xctest-imessage-max-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        createdPaths.append(outsideDirectory)

        let outsideFile = outsideDirectory.appendingPathComponent("precious.txt")
        try "do not delete".write(to: outsideFile, atomically: true, encoding: .utf8)

        let forged = OutgoingFileStager.StagedFile(fileURL: outsideFile, trackingName: "precious.txt")

        makeStager().remove(forged)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outsideDirectory.path),
            "The staging-root guard must refuse to delete a directory outside the staging root"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outsideFile.path),
            "The file outside the staging root must survive as well"
        )
    }

    func testSweepRemovesDirectoriesOlderThanCutoff() throws {
        let stager = makeStager()
        let testDir = stager.root.appendingPathComponent(
            "xctest-\(UUID().uuidString)",
            isDirectory: true
        )
        createdPaths.append(testDir)

        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-2 * 60 * 60)],
            ofItemAtPath: testDir.path
        )

        stager.sweepExpired()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: testDir.path),
            "A staging subdirectory older than the 1-hour cutoff must be removed"
        )
    }

    /// A failed transfer-status query still schedules removal of the staged
    /// copy, whether the query failed with a SendError or anything else.
    func testFailedStatusQueryRemovesTheStagedCopy() async throws {
        struct StatusQueryFailure: Error {}
        let errors: [any Error] = [SendError.failed("status probe failed"), StatusQueryFailure()]
        for error in errors {
            // /private form: the stager refuses a root behind the /var symlink.
            let tmp = try XCTUnwrap(SecurePath.absoluteLexicalPath(FileManager.default.temporaryDirectory.path))
            let scratch = URL(fileURLWithPath: tmp, isDirectory: true)
                .appendingPathComponent("xctest-transfer-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            createdPaths.append(scratch)
            let source = scratch.appendingPathComponent("source.txt")
            try Data("payload".utf8).write(to: source)
            let stager = OutgoingFileStager(root: scratch.appendingPathComponent("staging", isDirectory: true))
            let opened = try stager.openSource(source.path)
            let staged = try stager.stage(opened)
            opened.close()
            XCTAssertTrue(FileManager.default.fileExists(atPath: staged.fileURL.path))

            let result = TransferMonitor.waitForCompletion(
                of: staged, baseline: 0, stager: stager,
                statusQuery: { _ in throw error },
                removalDelay: .zero
            )

            guard case .failure(let failure) = result else { return XCTFail("expected failure for \(error)") }
            XCTAssertEqual(failure.disposition, .mayHaveCompleted)
            let removed = await waitForRemoval(of: staged.fileURL.deletingLastPathComponent())
            XCTAssertTrue(removed, "staged copy should be removed after \(error)")
        }
    }

    /// Polls for up to two seconds for `directory` to disappear.
    private func waitForRemoval(of directory: URL) async -> Bool {
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: directory.path) { return true }
            await AsyncTimeout.sleep(.milliseconds(20))
        }
        return false
    }

    private func makeStager() -> OutgoingFileStager {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xctest-imessage-max-staging-\(UUID().uuidString)", isDirectory: true)
        createdPaths.append(root)
        return OutgoingFileStager(root: root)
    }
}
