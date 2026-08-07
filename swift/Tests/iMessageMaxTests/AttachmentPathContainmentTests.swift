import Foundation
import XCTest
@testable import iMessageMax

final class AttachmentPathContainmentTests: XCTestCase {

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

    func testGetAttachmentRejectsOutOfRootPath() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContainmentE2E-\(UUID().uuidString)")
        let allowedRoot = base.appendingPathComponent("Messages")
        let outsideDir = base.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: allowedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

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
            XCTAssertFalse(
                message.contains(outsideFile.path),
                "Error message must not contain the attacker-supplied file path"
            )
        }
    }

    func testGetMessagesDoesNotProbeOutOfRootPaths() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContainmentGetMessages-\(UUID().uuidString)")
        let allowedRoot = base.appendingPathComponent("Messages")
        let outsideDir = base.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: allowedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // A real file outside the allowed root. Junk bytes are enough: if getMetadata
        // were ever reached it would fail to decode anyway, so the assertion below is on
        // the response shape (never probed), not on whether decoding succeeds.
        let outsideFile = outsideDir.appendingPathComponent("secret.jpg")
        try Data("not a real image".utf8).write(to: outsideFile)

        let fixtureDB = try ToolTestDatabase(name: "get-messages-containment-e2e")
        try fixtureDB.insertHandle(rowId: 1, handle: "+15550000001")
        try fixtureDB.insertChat(rowId: 10, guid: "chat-containment-guid", displayName: "Containment DM")
        try fixtureDB.joinChatHandle(chatId: 10, handleId: 1)
        try fixtureDB.insertMessage(rowId: 100, guid: "gm-containment-100", text: "look at this", date: 1_000_000_000_000, isFromMe: false, handleId: 1)
        try fixtureDB.joinChatMessage(chatId: 10, messageId: 100)
        try fixtureDB.insertAttachment(
            rowId: 99,
            filename: outsideFile.path,
            mimeType: "image/jpeg",
            uti: "public.jpeg"
        )
        try fixtureDB.joinMessageAttachment(messageId: 100, attachmentId: 99)

        let tool = GetMessagesTool(
            db: fixtureDB.database(),
            resolver: makeSeededResolver(),
            allowedRoots: [allowedRoot.path]
        )

        let contents = try await tool.execute(args: ["chat_id": .string("chat10")])
        let rawJSON = try decodeJSONString(from: contents)
        let response = try decodeJSONDictionary(from: rawJSON)

        let messages = try decodeJSONArray(try XCTUnwrap(response["messages"]))
        let target = try XCTUnwrap(messages.first(where: { $0["id"] as? String == "msg_100" }))

        let media = target["media"] as? [[String: Any]]
        XCTAssertTrue(media == nil || media!.isEmpty, "Out-of-root attachment must not appear under media")

        // Falls through to the plain summary, which only carries the last path component.
        let attachments = try decodeJSONArray(try XCTUnwrap(target["attachments"]))
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?["filename"] as? String, "secret.jpg")

        XCTAssertFalse(
            rawJSON.contains(outsideFile.path),
            "Encoded response must not contain the attacker-supplied file path"
        )
    }

    func testGetMessagesEnrichesInRootImage() async throws {
        let allowedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContainmentGetMessagesInRoot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: allowedRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: allowedRoot) }

        let imageURL = try makeFixtureImage(name: "in-root.jpg", width: 40, height: 20)
        let inRootURL = allowedRoot.appendingPathComponent(imageURL.lastPathComponent)
        try FileManager.default.moveItem(at: imageURL, to: inRootURL)
        defer { try? FileManager.default.removeItem(at: inRootURL) }

        let fixtureDB = try ToolTestDatabase(name: "get-messages-containment-inroot")
        try fixtureDB.insertHandle(rowId: 1, handle: "+15550000001")
        try fixtureDB.insertChat(rowId: 11, guid: "chat-inroot-guid", displayName: "InRoot DM")
        try fixtureDB.joinChatHandle(chatId: 11, handleId: 1)
        try fixtureDB.insertMessage(rowId: 101, guid: "gm-inroot-101", text: "here", date: 1_000_000_000_000, isFromMe: false, handleId: 1)
        try fixtureDB.joinChatMessage(chatId: 11, messageId: 101)
        try fixtureDB.insertAttachment(
            rowId: 98,
            filename: inRootURL.path,
            mimeType: "image/jpeg",
            uti: "public.jpeg"
        )
        try fixtureDB.joinMessageAttachment(messageId: 101, attachmentId: 98)

        let tool = GetMessagesTool(
            db: fixtureDB.database(),
            resolver: makeSeededResolver(),
            allowedRoots: [allowedRoot.path]
        )

        let contents = try await tool.execute(args: ["chat_id": .string("chat11")])
        let response = try decodeJSONDictionary(from: contents)

        let messages = try decodeJSONArray(try XCTUnwrap(response["messages"]))
        let target = try XCTUnwrap(messages.first(where: { $0["id"] as? String == "msg_101" }))

        let media = try decodeJSONArray(target["media"])
        XCTAssertEqual(media.count, 1)
        XCTAssertEqual(media.first?["type"] as? String, "image")
        let dimensions = try XCTUnwrap(media.first?["dimensions"] as? [String: Any])
        XCTAssertEqual(dimensions["width"] as? Int, 40)
        XCTAssertEqual(dimensions["height"] as? Int, 20)
    }
}
