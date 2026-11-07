import XCTest
@testable import iMessageMax

final class LogTests: XCTestCase {
    func testFormatIsStable() {
        let epoch = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(
            Log.format(.info, "Database: ok", at: epoch),
            "1970-01-01T00:00:00.000Z [imessage-max] INFO Database: ok\n"
        )
        XCTAssertEqual(
            Log.format(.warning, "Binding to '0.0.0.0'", at: epoch),
            "1970-01-01T00:00:00.000Z [imessage-max] WARN Binding to '0.0.0.0'\n"
        )
        XCTAssertEqual(
            Log.format(.error, "session Server.start failed: boom", at: epoch),
            "1970-01-01T00:00:00.000Z [imessage-max] ERROR session Server.start failed: boom\n"
        )
        XCTAssertEqual(
            Log.format(.info, "Database: ok", at: Date(timeIntervalSince1970: 1_790_000_000.25)),
            "2026-09-21T14:13:20.250Z [imessage-max] INFO Database: ok\n"
        )
    }

    private func temporaryDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-redirect-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Restores this process's stderr after a test points it at a file.
    private func keepStandardError() {
        let saved = dup(STDERR_FILENO)
        addTeardownBlock {
            dup2(saved, STDERR_FILENO)
            close(saved)
        }
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testRedirectAppendsStandardErrorToANewDirectory() throws {
        keepStandardError()
        let file = temporaryDirectory().appendingPathComponent("iMessage Max/imessage-max.log")
        Log.redirectStandardError(to: file.path)
        FileHandle.standardError.write(Data("first\n".utf8))
        Log.redirectStandardError(to: file.path)
        FileHandle.standardError.write(Data("second\n".utf8))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "first\nsecond\n")
        XCTAssertEqual(try permissions(file), 0o600)
    }

    func testAnOlderReadableLogBecomesPrivate() throws {
        keepStandardError()
        let dir = temporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("imessage-max.log")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: file.path, contents: Data("old\n".utf8), attributes: [.posixPermissions: 0o644]))
        Log.redirectStandardError(to: file.path)
        XCTAssertEqual(try permissions(file), 0o600)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old\n")
    }

    func testALargeLogMovesAsideOnStart() throws {
        keepStandardError()
        let dir = temporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("imessage-max.log")
        let previous = dir.appendingPathComponent("imessage-max.log.1")
        try Data("an older rotation\n".utf8).write(to: previous)
        try Data("more than ten bytes\n".utf8).write(to: file)

        Log.redirectStandardError(to: file.path, rotateAbove: 10)
        FileHandle.standardError.write(Data("fresh\n".utf8))

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "fresh\n")
        XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), "more than ten bytes\n")

        Log.redirectStandardError(to: file.path, rotateAbove: 10)
        XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), "more than ten bytes\n",
                       "a log under the limit stays where it is")
    }

    func testAnUnopenableLogKeepsStandardErrorAndSaysWhy() throws {
        keepStandardError()
        let dir = temporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blocker = dir.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        var before = stat()
        XCTAssertEqual(fstat(STDERR_FILENO, &before), 0)

        let capture = Log.Capture()
        Log.$capture.withValue(capture) {
            Log.redirectStandardError(to: blocker.appendingPathComponent("imessage-max.log").path)
        }

        var after = stat()
        XCTAssertEqual(fstat(STDERR_FILENO, &after), 0)
        XCTAssertEqual(before.st_ino, after.st_ino)
        XCTAssertEqual(before.st_dev, after.st_dev)
        XCTAssertEqual(capture.lines.count, 1)
        XCTAssertTrue(capture.lines.first?.contains("logging stays on stderr") == true, "\(capture.lines)")
    }
}
