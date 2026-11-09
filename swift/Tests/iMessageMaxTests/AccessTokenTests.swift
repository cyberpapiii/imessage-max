import XCTest
import IMessageMaxContract
@testable import iMessageMax

final class AccessTokenTests: XCTestCase {
    private var directory: URL!
    private var standard: AccessToken.Location { .appSupport(home: directory) }
    private var file: URL { standard.file }
    private var customFolder: URL { directory.appendingPathComponent("custom") }
    private var customFile: URL { customFolder.appendingPathComponent("token") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AccessTokenTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testFirstStartCreatesPrivateFileAndDirectory() throws {
        let token = try AccessToken.loadOrCreate(standard)

        XCTAssertEqual(try permissions(file.path), 0o600)
        XCTAssertEqual(try permissions(file.deletingLastPathComponent().path), 0o700)
        let contents = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(contents, token.encoded + "\n")
        XCTAssertEqual(token.encoded.count, 43)
        XCTAssertTrue(token.authorizes("Bearer \(token.encoded)"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["token"], "the temporary file is removed")
    }

    func testRestartReusesTheExistingToken() throws {
        let first = try AccessToken.loadOrCreate(standard)
        let second = try AccessToken.loadOrCreate(standard)
        XCTAssertEqual(first.encoded, second.encoded)
    }

    func testTokensDiffer() {
        XCTAssertNotEqual(AccessToken.generate().encoded, AccessToken.generate().encoded)
    }

    /// A custom --token-file is the developer's file, so a loose mode stops
    /// the server and the file is left as it was.
    func testGroupOrWorldReadableCustomFileIsRejectedAndLeftAlone() throws {
        try FileManager.default.createDirectory(at: customFolder, withIntermediateDirectories: true)
        let original = try AccessToken.loadOrCreate(.custom(customFile))
        for mode: mode_t in [0o644, 0o640, 0o604] {
            XCTAssertEqual(chmod(customFile.path, mode), 0)
            XCTAssertThrowsError(try AccessToken.loadOrCreate(.custom(customFile))) { error in
                XCTAssertEqual(error as? AccessToken.LoadError, .insecurePermissions(path: customFile.path, mode: S_IFREG | mode))
                XCTAssertTrue("\(error)".contains("chmod 600"), "\(error)")
            }
            XCTAssertEqual(try permissions(customFile.path), Int(mode))
            XCTAssertEqual(try String(contentsOf: customFile, encoding: .utf8), original.encoded + "\n")
        }
    }

    /// The standard token file with a loose mode would stop the helper on
    /// every launchd relaunch, forever (088 #15). The server tightens its
    /// own file to 0600, keeps the token, and logs a warning.
    func testGroupOrWorldReadableStandardFileIsTightenedWithAWarning() throws {
        let original = try AccessToken.loadOrCreate(standard)
        for mode: mode_t in [0o644, 0o640, 0o604, 0o666] {
            XCTAssertEqual(chmod(file.path, mode), 0)
            let capture = Log.Capture()
            let token = try Log.$capture.withValue(capture) { try AccessToken.loadOrCreate(standard) }

            XCTAssertEqual(token.encoded, original.encoded, "clients keep working with the same token")
            XCTAssertEqual(try permissions(file.path), 0o600)
            XCTAssertEqual(capture.lines.count, 1, "\(capture.lines)")
            XCTAssertTrue(capture.lines.first?.contains("had mode \(String(mode, radix: 8)); set it to 600") == true, "\(capture.lines)")
        }
    }

    func testSymlinkIsRejected() throws {
        let target = directory.appendingPathComponent("elsewhere")
        try (AccessToken.generate().encoded + "\n").write(to: target, atomically: false, encoding: .utf8)
        XCTAssertEqual(chmod(target.path, 0o600), 0)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)

        XCTAssertThrowsError(try AccessToken.loadOrCreate(standard)) { error in
            XCTAssertEqual(error as? AccessToken.LoadError, .notRegularFile(path: file.path))
        }
    }

    func testFileThatIsNotATokenIsLeftAloneAndStartupFails() throws {
        try FileManager.default.createDirectory(at: customFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oversized = String(repeating: "a", count: 2048)
        let contents = ["", "precious data", String(repeating: "a", count: 42), String(repeating: "+", count: 43), oversized]
        for location in [AccessToken.Location.custom(customFile), standard] {
            for content in contents {
                try content.write(to: location.file, atomically: false, encoding: .utf8)
                XCTAssertEqual(chmod(location.file.path, 0o600), 0)

                XCTAssertThrowsError(try AccessToken.loadOrCreate(location)) { error in
                    XCTAssertEqual(error as? AccessToken.LoadError, .malformed(path: location.file.path))
                }
                XCTAssertEqual(try String(contentsOf: location.file, encoding: .utf8), content)
            }
        }
    }

    func testCustomPathCreatesTheTokenAndLeavesItsFolderAlone() throws {
        try FileManager.default.createDirectory(
            at: customFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

        let token = try AccessToken.loadOrCreate(.custom(customFile))
        XCTAssertEqual(try String(contentsOf: customFile, encoding: .utf8), token.encoded + "\n")
        XCTAssertEqual(try permissions(customFile.path), 0o600)
        XCTAssertEqual(try permissions(customFolder.path), 0o755)
        XCTAssertEqual(try AccessToken.loadOrCreate(.custom(customFile)).encoded, token.encoded)
    }

    func testCustomPathNeedsAnExistingFolder() throws {
        XCTAssertThrowsError(try AccessToken.loadOrCreate(.custom(customFile))) { error in
            guard case .io(let path, _, _) = error as? AccessToken.LoadError else { return XCTFail("\(error)") }
            XCTAssertEqual(path, customFolder.path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: customFolder.path))
    }

    func testCustomPathInAnotherUsersFolderIsRefused() throws {
        let rootOwned = URL(fileURLWithPath: "/private/tmp/imessage-max-token-\(UUID().uuidString)")
        XCTAssertThrowsError(try AccessToken.loadOrCreate(.custom(rootOwned))) { error in
            XCTAssertEqual(error as? AccessToken.LoadError, .unsafeFolder(path: "/private/tmp"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootOwned.path))
    }

    func testFifoIsRejectedWithoutBlocking() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)

        XCTAssertThrowsError(try AccessToken.loadOrCreate(standard)) { error in
            XCTAssertEqual(error as? AccessToken.LoadError, .notRegularFile(path: file.path))
        }
    }

    func testOpenExistingDirectoryIsTightened() throws {
        let parent = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

        _ = try AccessToken.loadOrCreate(standard)
        XCTAssertEqual(try permissions(parent.path), 0o700)
    }

    func testHandWrittenTokenWithTrailingNewlineIsAccepted() throws {
        let encoded = AccessToken.generate().encoded
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "\(encoded)\n".write(to: file, atomically: false, encoding: .utf8)
        XCTAssertEqual(chmod(file.path, 0o600), 0)

        XCTAssertEqual(try AccessToken.loadOrCreate(standard).encoded, encoded)
    }

    func testTokenFileOptionOverridesTheDefault() throws {
        let command = try iMessageMax.parse(["--http", "--token-file", file.path])
        XCTAssertEqual(command.tokenFile, file.path)
        XCTAssertNil(try iMessageMax.parse(["--http"]).tokenFile)
        XCTAssertEqual(
            AccessToken.Location.appSupport(home: URL(fileURLWithPath: "/Users/someone")).file.path,
            "/Users/someone/Library/Application Support/iMessage Max/token")
    }

    private func permissions(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try XCTUnwrap(attributes[.posixPermissions] as? Int)
    }
}
