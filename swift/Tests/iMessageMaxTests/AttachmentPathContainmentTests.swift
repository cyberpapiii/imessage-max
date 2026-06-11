// Tests/iMessageMaxTests/AttachmentPathContainmentTests.swift
import Foundation
import XCTest
@testable import iMessageMax

final class AttachmentPathContainmentTests: XCTestCase {

    // MARK: - AttachmentPathPolicy unit tests

    func testPathInsideRootValidates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContainmentRoot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("image.jpg")
        try Data("fake".utf8).write(to: file)

        let result = AttachmentPathPolicy.validatedPath(file.path, allowedRoots: [root.path])
        XCTAssertNotNil(result, "Path inside allowed root should validate")
    }

    func testPathOutsideRootRejected() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContainmentBase-\(UUID().uuidString)")
        let rootA = base.appendingPathComponent("A")
        let rootB = base.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let file = rootB.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: file)

        let result = AttachmentPathPolicy.validatedPath(file.path, allowedRoots: [rootA.path])
        XCTAssertNil(result, "Path in sibling directory should be rejected")
    }

    func testPrefixCousinDirectoryRejected() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContainmentPrefix-\(UUID().uuidString)")
        let root = base.appendingPathComponent("Messages")
        let cousin = base.appendingPathComponent("MessagesEvil")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cousin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let file = cousin.appendingPathComponent("f.txt")
        try Data("evil".utf8).write(to: file)

        let result = AttachmentPathPolicy.validatedPath(file.path, allowedRoots: [root.path])
        XCTAssertNil(result, "Directory with same prefix as root but different name should be rejected")
    }

    func testDotDotEscapeRejected() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContainmentDotDot-\(UUID().uuidString)")
        let root = base.appendingPathComponent("Messages")
        let outside = base.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: base) }

        // Path that traverses up via ../
        let escapePath = root.path + "/sub/../../outside.txt"
        let result = AttachmentPathPolicy.validatedPath(escapePath, allowedRoots: [root.path])
        XCTAssertNil(result, "Path using ../ to escape root should be rejected after standardization")
    }

    func testSymlinkEscapeRejected() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContainmentSymlink-\(UUID().uuidString)")
        let root = base.appendingPathComponent("Messages")
        let outside = base.appendingPathComponent("outside.txt")
        let symlink = root.appendingPathComponent("link.txt")

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("outside".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        } catch {
            throw XCTSkip("Could not create symlink (sandboxing may prevent it): \(error)")
        }
        defer { try? FileManager.default.removeItem(at: base) }

        let result = AttachmentPathPolicy.validatedPath(symlink.path, allowedRoots: [root.path])
        XCTAssertNil(result, "Symlink inside root pointing outside should be rejected after resolution")
    }

    // MARK: - End-to-end: GetAttachment rejects out-of-root paths

    func testGetAttachmentRejectsOutOfRootPath() async throws {
        // Create an allowed root and a separate "outside" directory
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContainmentE2E-\(UUID().uuidString)")
        let allowedRoot = base.appendingPathComponent("Messages")
        let outsideDir = base.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: allowedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // Create a real file outside the allowed root
        let outsideFile = outsideDir.appendingPathComponent("secret.jpg")
        try Data("secret".utf8).write(to: outsideFile)

        // Build a fixture DB whose attachment row points to the outside file.
        // ToolTestDatabase cleans up on deinit.
        let fixtureDB = try ToolTestDatabase(name: "containment-e2e")
        try fixtureDB.insertAttachment(
            rowId: 99,
            filename: outsideFile.path,
            mimeType: "image/jpeg",
            uti: "public.jpeg"
        )

        let tool = GetAttachment(db: fixtureDB.database())
        let result = await tool.execute(
            attachmentId: "att99",
            variant: "vision",
            allowedRoots: [allowedRoot.path]
        )

        switch result {
        case .success:
            XCTFail("Expected attachment_path_invalid error for out-of-root path")
        case .error(let type, let message, _):
            XCTAssertEqual(type, "attachment_path_invalid")
            // The message must NOT echo back the offending path
            XCTAssertFalse(
                message.contains(outsideFile.path),
                "Error message must not contain the attacker-supplied file path"
            )
        }
    }
}
