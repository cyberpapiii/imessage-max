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

    private func makeStager() -> OutgoingFileStager {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xctest-imessage-max-staging-\(UUID().uuidString)", isDirectory: true)
        createdPaths.append(root)
        return OutgoingFileStager(root: root)
    }
}
