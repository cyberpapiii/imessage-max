import XCTest
import IMessageMaxContract
@testable import iMessageMax

final class AccessTokenTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("iMessage Max/token") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AccessTokenTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testFirstStartCreatesPrivateFileAndDirectory() throws {
        let token = try AccessToken.loadOrCreate(at: file)

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
        let first = try AccessToken.loadOrCreate(at: file)
        let second = try AccessToken.loadOrCreate(at: file)
        XCTAssertEqual(first.encoded, second.encoded)
    }

    func testTokensDiffer() {
        XCTAssertNotEqual(AccessToken.generate().encoded, AccessToken.generate().encoded)
    }

    func testGroupOrWorldReadableFileIsRejectedAndLeftAlone() throws {
        let original = try AccessToken.loadOrCreate(at: file)
        for mode: mode_t in [0o644, 0o640, 0o604] {
            XCTAssertEqual(chmod(file.path, mode), 0)
            XCTAssertThrowsError(try AccessToken.loadOrCreate(at: file)) { error in
                XCTAssertEqual(error as? AccessToken.LoadError, .insecurePermissions(path: file.path, mode: S_IFREG | mode))
                XCTAssertTrue("\(error)".contains("chmod 600"), "\(error)")
            }
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original.encoded + "\n")
        }
    }

    func testSymlinkIsRejected() throws {
        let target = directory.appendingPathComponent("elsewhere")
        try (AccessToken.generate().encoded + "\n").write(to: target, atomically: false, encoding: .utf8)
        XCTAssertEqual(chmod(target.path, 0o600), 0)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)

        XCTAssertThrowsError(try AccessToken.loadOrCreate(at: file)) { error in
            XCTAssertEqual(error as? AccessToken.LoadError, .notRegularFile(path: file.path))
        }
    }

    func testMalformedFileIsReplaced() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        for contents in ["", "short", String(repeating: "a", count: 42), String(repeating: "+", count: 43)] {
            try contents.write(to: file, atomically: false, encoding: .utf8)
            XCTAssertEqual(chmod(file.path, 0o600), 0)

            let token = try AccessToken.loadOrCreate(at: file)
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), token.encoded + "\n")
            XCTAssertEqual(try permissions(file.path), 0o600)
        }
    }

    func testOpenExistingDirectoryIsTightened() throws {
        let parent = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

        _ = try AccessToken.loadOrCreate(at: file)
        XCTAssertEqual(try permissions(parent.path), 0o700)
    }

    func testHandWrittenTokenWithTrailingNewlineIsAccepted() throws {
        let encoded = AccessToken.generate().encoded
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "\(encoded)\n".write(to: file, atomically: false, encoding: .utf8)
        XCTAssertEqual(chmod(file.path, 0o600), 0)

        XCTAssertEqual(try AccessToken.loadOrCreate(at: file).encoded, encoded)
    }

    func testTokenFileOptionOverridesTheDefault() throws {
        let command = try iMessageMax.parse(["--http", "--token-file", file.path])
        XCTAssertEqual(command.tokenFile, file.path)
        XCTAssertNil(try iMessageMax.parse(["--http"]).tokenFile)
        XCTAssertEqual(
            AccessToken.defaultFile(home: URL(fileURLWithPath: "/Users/someone")).path,
            "/Users/someone/Library/Application Support/iMessage Max/token")
    }

    private func permissions(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try XCTUnwrap(attributes[.posixPermissions] as? Int)
    }
}
