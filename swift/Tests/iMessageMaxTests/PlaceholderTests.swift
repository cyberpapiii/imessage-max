import XCTest
import SQLite3
import MCP
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import iMessageMax

final class SendPayloadTests: XCTestCase {
    func testBuildReturnsFailureWhenNoTextOrFilesProvided() {
        switch SendPayload.build(text: nil, filePaths: nil) {
        case .success:
            XCTFail("Expected validation failure")
        case .failure(let message):
            XCTAssertTrue(message.contains("At least one"))
        }
    }

    func testBuildOrdersFilesBeforeText() {
        switch SendPayload.build(text: "hello", filePaths: ["/tmp/a.png", "/tmp/b.png"]) {
        case .failure(let message):
            XCTFail("Unexpected failure: \(message)")
        case .success(let payloads):
            XCTAssertEqual(payloads.count, 3)

            guard case .file(let first) = payloads[0] else {
                return XCTFail("Expected first payload to be file")
            }
            guard case .file(let second) = payloads[1] else {
                return XCTFail("Expected second payload to be file")
            }
            guard case .text(let body) = payloads[2] else {
                return XCTFail("Expected final payload to be text")
            }

            XCTAssertEqual(first, "/tmp/a.png")
            XCTAssertEqual(second, "/tmp/b.png")
            XCTAssertEqual(body, "hello")
        }
    }

    func testBuildIgnoresEmptyFileEntries() {
        switch SendPayload.build(text: nil, filePaths: ["", "/tmp/a.png"]) {
        case .failure(let message):
            XCTFail("Unexpected failure: \(message)")
        case .success(let payloads):
            XCTAssertEqual(payloads.count, 1)
            guard case .file(let path) = payloads[0] else {
                return XCTFail("Expected file payload")
            }
            XCTAssertEqual(path, "/tmp/a.png")
        }
    }
}

final class SendResponseTests: XCTestCase {
    func testSuccessResponseUsesSentStatus() {
        let response = SendResponse.success(
            deliveredTo: ["Rob Dezendorf"],
            chat: ChatReference(id: "chat123", name: "Rob Dezendorf")
        )

        XCTAssertEqual(response.status, "sent")
        XCTAssertNil(response.message)
        XCTAssertEqual(response.chat?.id, "chat123")
        XCTAssertEqual(response.chat?.name, "Rob Dezendorf")
        XCTAssertEqual(response.chatId, "chat123")
    }

    func testPendingResponseUsesPendingConfirmationStatus() {
        let response = SendResponse.pending(
            "Attachment accepted but still pending",
            deliveredTo: ["Rob Dezendorf"],
            chat: ChatReference(id: "chat456", name: "Project Group")
        )

        XCTAssertEqual(response.status, "pending_confirmation")
        XCTAssertEqual(response.message, "Attachment accepted but still pending")
        XCTAssertNil(response.error)
        XCTAssertEqual(response.chat?.name, "Project Group")
        XCTAssertEqual(response.chatId, "chat456")
    }

    func testErrorResponseUsesFailedStatus() {
        let response = SendResponse.error("Send failed")

        XCTAssertEqual(response.status, "failed")
        XCTAssertEqual(response.error, "Send failed")
        XCTAssertNil(response.message)
    }

    func testAmbiguousResponseUsesAmbiguousStatus() {
        let response = SendResponse.ambiguous(candidates: [
            RecipientCandidate(name: "Rob Dezendorf", handle: "+16317087185", lastContact: "today")
        ])

        XCTAssertEqual(response.status, "ambiguous")
        XCTAssertNil(response.error)
        XCTAssertEqual(response.message, "Multiple contacts match. Please specify using a phone number, email, or chat_id.")
        XCTAssertEqual(response.candidates?.count, 1)
    }
}

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

        let prepared = try AppleScriptRunner.prepareTrackedOutgoingFile(sourcePath: sourceURL.path)
        defer { try? FileManager.default.removeItem(at: prepared.fileURL.deletingLastPathComponent()) }

        XCTAssertNotEqual(prepared.fileURL.path, sourceURL.path)
        XCTAssertEqual(prepared.fileURL.pathExtension, "txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.fileURL.path))
        XCTAssertEqual(prepared.trackingName, "imessage-max-source-test.txt")
        XCTAssertEqual(prepared.fileURL.lastPathComponent, "imessage-max-source-test.txt")
        XCTAssertGreaterThanOrEqual(prepared.existingOutgoingTransferCount, 0)
        XCTAssertTrue(prepared.fileURL.path.contains("/Pictures/imessage-max-staging/"))
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

final class ToolRegistryTests: XCTestCase {
    func testRegisterAllDoesNotExposeLegacyUpdateTool() async {
        ToolHandlerRegistry.shared.resetForTesting()

        let server = Server(name: "test", version: "0")
        await ToolRegistry.registerAll(on: server, db: Database(), resolver: ContactResolver())

        let tools = ToolHandlerRegistry.shared.getTools()
        let names = Set(tools.map(\.name))

        XCTAssertFalse(names.contains("update"))
    }

    func testCatchUpToolDescriptionsBiasTowardBroadOverviewThenNarrowing() async throws {
        ToolHandlerRegistry.shared.resetForTesting()

        let server = Server(name: "test", version: "0")
        await ToolRegistry.registerAll(on: server, db: Database(), resolver: ContactResolver())

        let tools = Dictionary(
            uniqueKeysWithValues: ToolHandlerRegistry.shared.getTools().map { ($0.name, $0) }
        )

        let listChats = try XCTUnwrap(tools["list_chats"])
        let listChatsDescription = try XCTUnwrap(listChats.description)
        XCTAssertTrue(listChatsDescription.contains("broad catch-ups"))
        XCTAssertTrue(listChatsDescription.contains("discovery before drilling deeper"))

        let getUnread = try XCTUnwrap(tools["get_unread"])
        let getUnreadDescription = try XCTUnwrap(getUnread.description)
        XCTAssertTrue(getUnreadDescription.contains("follow-up check"))
        XCTAssertTrue(getUnreadDescription.contains("not a complete recent conversation overview"))

        let getActive = try XCTUnwrap(tools["get_active_conversations"])
        let getActiveDescription = try XCTUnwrap(getActive.description)
        XCTAssertTrue(getActiveDescription.contains("deserve attention first"))
        XCTAssertTrue(getActiveDescription.contains("not a complete recent overview"))

        let findChat = try XCTUnwrap(tools["find_chat"])
        let findChatDescription = try XCTUnwrap(findChat.description)
        XCTAssertTrue(findChatDescription.contains("specific chat"))
        XCTAssertTrue(findChatDescription.contains("targeted conversation"))
    }

    func testChatToolDescriptionsKeepIdsInternalAndNamesUserFacing() async throws {
        ToolHandlerRegistry.shared.resetForTesting()

        let server = Server(name: "test", version: "0")
        await ToolRegistry.registerAll(on: server, db: Database(), resolver: ContactResolver())

        let tools = Dictionary(
            uniqueKeysWithValues: ToolHandlerRegistry.shared.getTools().map { ($0.name, $0) }
        )

        for name in [
            "find_chat",
            "get_chat_details",
            "get_messages",
            "get_context",
            "search",
            "list_chats",
            "get_active_conversations",
            "list_attachments",
            "get_unread",
        ] {
            let tool = try XCTUnwrap(tools[name], "Expected \(name) to be registered")
            let description = try XCTUnwrap(tool.description, "Expected \(name) to have a description")
            XCTAssertTrue(description.contains("follow-up tool calls"), "\(name) should explain ids are for tool calls")
            XCTAssertTrue(description.contains("refer to chats by name") || description.contains("refer to chat.name"), "\(name) should tell agents to use names in user-facing summaries")
        }
    }
}

final class GetAttachmentToolTests: XCTestCase {
    func testExecuteReturnsResizedImageForVisionVariant() async throws {
        let imageURL = try makeTestImage(width: 2000, height: 1000, filename: "attachment-large.jpg")
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let dbPath = try makeAttachmentTestDatabase(rows: [
            (1, imageURL.path, "image/jpeg", "public.jpeg", 0, "attachment-large.jpg")
        ])
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let tool = GetAttachment(db: Database(path: dbPath))
        let result = await tool.execute(attachmentId: "att1", variant: "vision")

        switch result {
        case .success(let metadata, let imageData, let mimeType):
            XCTAssertEqual(mimeType, "image/jpeg")
            XCTAssertEqual(metadata.id, "att1")
            XCTAssertEqual(metadata.type, "image")
            XCTAssertEqual(metadata.name, "attachment-large.jpg")
            XCTAssertTrue(metadata.available)
            XCTAssertFalse(imageData.isEmpty)
        case .error(let type, let message, _):
            XCTFail("Expected image success, got \(type): \(message)")
        }
    }

    func testExecuteReturnsUnsupportedTypeForVideoAttachment() async throws {
        let videoURL = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-video.mp4")
        try Data("video".utf8).write(to: videoURL)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let dbPath = try makeAttachmentTestDatabase(rows: [
            (2, videoURL.path, "video/mp4", "public.mpeg-4", 5, "attachment-video.mp4")
        ])
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let tool = GetAttachment(db: Database(path: dbPath))
        let result = await tool.execute(attachmentId: "2", variant: "full")

        switch result {
        case .success:
            XCTFail("Expected unsupported video error")
        case .error(let type, let message, let details):
            XCTAssertEqual(type, "unsupported_type")
            XCTAssertTrue(message.contains("Video attachments are not yet supported"))
            XCTAssertEqual(details?["type"] as? String, "video")
        }
    }

    func testExecuteReturnsOffloadedErrorWhenImageFileIsMissing() async throws {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("definitely-missing-attachment.jpg").path

        let dbPath = try makeAttachmentTestDatabase(rows: [
            (3, missingPath, "image/jpeg", "public.jpeg", 12, "missing.jpg")
        ])
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let tool = GetAttachment(db: Database(path: dbPath))
        let result = await tool.execute(attachmentId: "att3", variant: "thumb")

        switch result {
        case .success:
            XCTFail("Expected offloaded attachment error")
        case .error(let type, let message, _):
            XCTAssertEqual(type, "attachment_offloaded")
            XCTAssertTrue(message.contains("offloaded") || message.contains("iCloud"))
        }
    }
}

final class SendToolExecutionTests: XCTestCase {
    func testExecuteRejectsReplyToBeforeAttemptingSend() async {
        let tool = SendTool(db: Database(path: "/tmp/nonexistent.sqlite"), resolver: ContactResolver())

        do {
            _ = try await tool.execute(args: [
                "to": .string("+16317087185"),
                "text": .string("Hello"),
                "reply_to": .string("msg_1"),
            ])
            XCTFail("Expected reply_to validation error")
        } catch let error as ToolError {
            let payload = decodeToolErrorText(error)
            XCTAssertTrue(payload.contains("reply_to is not yet implemented"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

final class SendResolverTests: XCTestCase {
    func testResolveChatIdReturnsExactChatTarget() async throws {
        let dbPath = try makeResolverTestDatabase()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let resolver = SendResolver(db: Database(path: dbPath), resolver: ContactResolver())
        let result = await resolver.resolve(chatId: "chat10", to: nil)

        switch result {
        case .failure(let message):
            XCTFail("Unexpected failure: \(message)")
        case .ambiguous:
            XCTFail("Unexpected ambiguity")
        case .success(let resolved):
            guard case .chat(let guid, let chatId) = resolved.target else {
                return XCTFail("Expected exact chat target")
            }
            XCTAssertEqual(guid, "any;+;chat-test-guid")
            XCTAssertEqual(chatId, 10)
            XCTAssertEqual(Set(resolved.deliveredTo), Set(["+1 (631) 708-7185", "+1 (510) 461-5406"]))
        }
    }

    func testResolvePhoneNumberReturnsParticipantTarget() async throws {
        let dbPath = try makeResolverTestDatabase()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let resolver = SendResolver(db: Database(path: dbPath), resolver: ContactResolver())
        let result = await resolver.resolve(chatId: nil, to: "+16317087185")

        switch result {
        case .failure(let message):
            XCTFail("Unexpected failure: \(message)")
        case .ambiguous:
            XCTFail("Unexpected ambiguity")
        case .success(let resolved):
            guard case .participant(let handle, let chatId) = resolved.target else {
                return XCTFail("Expected participant target")
            }
            XCTAssertEqual(handle, "+16317087185")
            XCTAssertEqual(chatId, 11)
            XCTAssertEqual(resolved.deliveredTo, ["+1 (631) 708-7185"])
        }
    }

}

private func makeResolverTestDatabase() throws -> String {
    let dbURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("imessage-max-send-resolver-\(UUID().uuidString).sqlite")

    var db: OpaquePointer?
    guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
        XCTFail("Failed to open temp sqlite database")
        return dbURL.path
    }
    defer { sqlite3_close(db) }

    let statements = [
        "CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, display_name TEXT);",
        "CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);",
        "CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);",
        "CREATE TABLE message (ROWID INTEGER PRIMARY KEY, handle_id INTEGER, date INTEGER);",
        "INSERT INTO handle (ROWID, id) VALUES (1, '+16317087185');",
        "INSERT INTO handle (ROWID, id) VALUES (2, '+15104615406');",
        "INSERT INTO chat (ROWID, guid, display_name) VALUES (10, 'any;+;chat-test-guid', NULL);",
        "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (10, 1);",
        "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (10, 2);",
        "INSERT INTO chat (ROWID, guid, display_name) VALUES (11, 'any;-;+16317087185', NULL);",
        "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (11, 1);",
        "INSERT INTO message (ROWID, handle_id, date) VALUES (1, 1, 1000);"
    ]

    for statement in statements {
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            XCTFail("SQLite setup failed: \(message)")
            break
        }
    }

    return dbURL.path
}

private func makeAttachmentTestDatabase(
    rows: [(id: Int, filename: String, mimeType: String?, uti: String?, totalBytes: Int64, transferName: String?)]
) throws -> String {
    let dbURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("imessage-max-attachment-\(UUID().uuidString).sqlite")

    var db: OpaquePointer?
    guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
        XCTFail("Failed to open attachment sqlite database")
        return dbURL.path
    }
    defer { sqlite3_close(db) }

    let createStatement = """
        CREATE TABLE attachment (
            ROWID INTEGER PRIMARY KEY,
            filename TEXT,
            mime_type TEXT,
            uti TEXT,
            total_bytes INTEGER,
            transfer_name TEXT
        );
        """
    guard sqlite3_exec(db, createStatement, nil, nil, nil) == SQLITE_OK else {
        XCTFail("Failed to create attachment table")
        return dbURL.path
    }

    for row in rows {
        let transferNameSQL = row.transferName.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" } ?? "NULL"
        let mimeSQL = row.mimeType.map { "'\($0)'" } ?? "NULL"
        let utiSQL = row.uti.map { "'\($0)'" } ?? "NULL"
        let insert = """
            INSERT INTO attachment (ROWID, filename, mime_type, uti, total_bytes, transfer_name)
            VALUES (\(row.id), '\(row.filename.replacingOccurrences(of: "'", with: "''"))', \(mimeSQL), \(utiSQL), \(row.totalBytes), \(transferNameSQL));
            """
        guard sqlite3_exec(db, insert, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            XCTFail("Failed to insert attachment row: \(message)")
            break
        }
    }

    return dbURL.path
}

private func makeTestImage(width: Int, height: Int, filename: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        throw NSError(domain: "TestImage", code: 1)
    }

    context.setFillColor(CGColor(red: 0.95, green: 0.2, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw NSError(domain: "TestImage", code: 2)
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "TestImage", code: 3)
    }

    return url
}

private func decodeToolErrorText(_ error: ToolError) -> String {
    guard let first = error.content.first else { return "" }
    switch first {
    case .text(let text, _, _):
        return text
    default:
        return ""
    }
}
