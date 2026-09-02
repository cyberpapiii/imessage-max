import Foundation
import XCTest
@testable import iMessageMax

final class AttachmentStagingSecurityTests: XCTestCase {
    private var scratch: URL!
    private var stagedToClean: [URL] = []

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("xctest-085-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        stagedToClean = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        for url in stagedToClean { try? FileManager.default.removeItem(at: url) }
    }

    private func requireStagingRoot() throws {
        let root = AppleScriptRunner.stagingRootDirectory()
        if ProcessInfo.processInfo.environment["CI"] != nil,
           !FileManager.default.isWritableFile(atPath: root.deletingLastPathComponent().path) {
            throw XCTSkip("~/Pictures is not writable on this runner")
        }
    }

    private func makeSecret() throws -> URL {
        let secret = scratch.appendingPathComponent("id_rsa")
        try "SECRET".data(using: .utf8)!.write(to: secret)
        return secret
    }

    private func symlink(_ link: URL, to target: URL) throws {
        do { try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target) }
        catch { throw XCTSkip("cannot create symlinks here: \(error)") }
    }

    private static let finished: @Sendable (String) throws -> [String] = { _ in ["finished"] }

    private func stagingRootEntryCount() throws -> Int {
        let root = AppleScriptRunner.stagingRootDirectory()
        guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(atPath: root.path).count
    }

    func testAliasPrefixesNormalizeToPrivate() {
        XCTAssertEqual(SecurePath.absoluteLexicalPath("/tmp/x.png"), "/private/tmp/x.png")
        XCTAssertEqual(SecurePath.absoluteLexicalPath("/var/folders/a/b.png"), "/private/var/folders/a/b.png")
        XCTAssertEqual(SecurePath.absoluteLexicalPath("/etc/hosts"), "/private/etc/hosts")
        XCTAssertEqual(SecurePath.absoluteLexicalPath("/tmp"), "/private/tmp")
        XCTAssertEqual(SecurePath.absoluteLexicalPath("/tmpfoo/x"), "/tmpfoo/x")       // prefix must be a whole component
        XCTAssertEqual(SecurePath.absoluteLexicalPath("/private/tmp/x"), "/private/tmp/x") // idempotent
    }

    func testTildeAndDotSegmentsAreResolvedLexically() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(SecurePath.absoluteLexicalPath("~/Pictures/../Downloads/a.png"), home + "/Downloads/a.png")
    }

    func testRelativePathsAreNotAbsolutized() {
        XCTAssertNil(SecurePath.absoluteLexicalPath("Pictures/a.png"))
        XCTAssertNil(SecurePath.absoluteLexicalPath("./a.png"))
        XCTAssertNil(SecurePath.absoluteLexicalPath(""))
    }

    func testSymlinkLeafIsRejectedWithoutStaging() throws {
        let secret = try makeSecret()
        let link = scratch.appendingPathComponent("photo.png")
        try symlink(link, to: secret)
        let before = try stagingRootEntryCount()

        XCTAssertThrowsError(
            try AppleScriptRunner.prepareTrackedOutgoingFile(
                sourcePath: link.path,
                existingOutgoingTransferStatuses: Self.finished
            )
        ) { error in
            XCTAssertTrue(error is SendError, "\(error)")
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("symbolic link"), text)
            XCTAssertTrue(text.contains("'photo.png'"), text)
            XCTAssertFalse(text.contains(scratch.path), text)
        }

        XCTAssertEqual(try stagingRootEntryCount(), before, "rejected symlink must not create a staging entry")
    }

    func testSymlinkDirectoryComponentIsRejected() throws {
        let realDir = scratch.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let file = realDir.appendingPathComponent("a.png")
        try "OK".data(using: .utf8)!.write(to: file)
        let alias = scratch.appendingPathComponent("alias")
        try symlink(alias, to: realDir)

        XCTAssertThrowsError(
            try AppleScriptRunner.prepareTrackedOutgoingFile(
                sourcePath: alias.appendingPathComponent("a.png").path,
                existingOutgoingTransferStatuses: Self.finished
            )
        ) { error in
            XCTAssertTrue(error is SendError, "\(error)")
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("symbolic link"), text)
            XCTAssertFalse(text.contains(scratch.path), text)
        }
    }

    func testTmpAliasIsAccepted() throws {
        try requireStagingRoot()
        let varFile = scratch.appendingPathComponent("a.png")
        try "VAR".data(using: .utf8)!.write(to: varFile)

        let fromVar = try AppleScriptRunner.prepareTrackedOutgoingFile(
            sourcePath: varFile.path,
            existingOutgoingTransferStatuses: Self.finished
        )
        stagedToClean.append(fromVar.fileURL.deletingLastPathComponent())

        let tmpDir = URL(fileURLWithPath: "/tmp").appendingPathComponent("xctest-085-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let tmpFile = tmpDir.appendingPathComponent("a.png")
        try "TMP".data(using: .utf8)!.write(to: tmpFile)

        let fromTmp = try AppleScriptRunner.prepareTrackedOutgoingFile(
            sourcePath: tmpFile.path,
            existingOutgoingTransferStatuses: Self.finished
        )
        stagedToClean.append(fromTmp.fileURL.deletingLastPathComponent())

        XCTAssertTrue(FileManager.default.fileExists(atPath: fromVar.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fromTmp.fileURL.path))
    }

    func testStagedCopyIsIndependentOfSource() throws {
        try requireStagingRoot()
        let source = scratch.appendingPathComponent("a.png")
        try "ORIGINAL".data(using: .utf8)!.write(to: source)

        let prepared = try AppleScriptRunner.prepareTrackedOutgoingFile(
            sourcePath: source.path,
            existingOutgoingTransferStatuses: Self.finished
        )
        stagedToClean.append(prepared.fileURL.deletingLastPathComponent())

        try "CHANGED".data(using: .utf8)!.write(to: source)
        let secret = try makeSecret()
        try FileManager.default.removeItem(at: source)
        try symlink(source, to: secret)

        let staged = try String(contentsOf: prepared.fileURL, encoding: .utf8)
        XCTAssertEqual(staged, "ORIGINAL")
        let type = try FileManager.default.attributesOfItem(atPath: prepared.fileURL.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeRegular)
    }

    func testStagingDirectoriesAre0700() throws {
        try requireStagingRoot()
        let source = scratch.appendingPathComponent("a.png")
        try "PERM".data(using: .utf8)!.write(to: source)

        let prepared = try AppleScriptRunner.prepareTrackedOutgoingFile(
            sourcePath: source.path,
            existingOutgoingTransferStatuses: Self.finished
        )
        let stagedDir = prepared.fileURL.deletingLastPathComponent()
        stagedToClean.append(stagedDir)

        let dirPerms = try FileManager.default.attributesOfItem(atPath: stagedDir.path)[.posixPermissions] as? Int
        XCTAssertEqual(dirPerms, 0o700)
        let rootPerms = try FileManager.default.attributesOfItem(
            atPath: AppleScriptRunner.stagingRootDirectory().path
        )[.posixPermissions] as? Int
        XCTAssertEqual(rootPerms, 0o700)
        let filePerms = try FileManager.default.attributesOfItem(atPath: prepared.fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(filePerms, 0o600)
    }

    func testRelativePathIsRejected() {
        XCTAssertThrowsError(
            try AppleScriptRunner.prepareTrackedOutgoingFile(
                sourcePath: "Pictures/a.png",
                existingOutgoingTransferStatuses: Self.finished
            )
        ) { error in
            guard case SendError.invalidParams(let message) = error else {
                return XCTFail("expected invalidParams, got \(error)")
            }
            XCTAssertTrue(message.contains("absolute"), message)
        }
    }

    func testNonRegularFileIsRejected() {
        XCTAssertThrowsError(
            try AppleScriptRunner.prepareTrackedOutgoingFile(
                sourcePath: "/dev/null",
                existingOutgoingTransferStatuses: Self.finished
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("regular file"), error.localizedDescription)
        }
    }

    func testMissingFileStillReportsBasenameOnly() {
        XCTAssertThrowsError(
            try AppleScriptRunner.prepareTrackedOutgoingFile(
                sourcePath: scratch.path + "/nope/missing.png",
                existingOutgoingTransferStatuses: Self.finished
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, "Could not read file at 'missing.png'.")
        }
    }
}
