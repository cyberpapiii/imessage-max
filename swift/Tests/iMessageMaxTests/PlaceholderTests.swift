import XCTest
import SQLite3
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
        let response = SendResponse.success(deliveredTo: ["Rob Dezendorf"], chatId: 123)

        XCTAssertEqual(response.status, "sent")
        XCTAssertTrue(response.success)
        XCTAssertNil(response.message)
        XCTAssertEqual(response.chatId, "chat123")
    }

    func testPendingResponseUsesPendingConfirmationStatus() {
        let response = SendResponse.pending(
            "Attachment accepted but still pending",
            deliveredTo: ["Rob Dezendorf"],
            chatId: 456
        )

        XCTAssertEqual(response.status, "pending_confirmation")
        XCTAssertFalse(response.success)
        XCTAssertEqual(response.message, "Attachment accepted but still pending")
        XCTAssertNil(response.error)
        XCTAssertEqual(response.chatId, "chat456")
    }

    func testErrorResponseUsesFailedStatus() {
        let response = SendResponse.error("Send failed")

        XCTAssertEqual(response.status, "failed")
        XCTAssertFalse(response.success)
        XCTAssertEqual(response.error, "Send failed")
        XCTAssertNil(response.message)
    }

    func testAmbiguousResponseUsesAmbiguousStatus() {
        let response = SendResponse.ambiguous(candidates: [
            RecipientCandidate(name: "Rob Dezendorf", handle: "+16317087185", lastContact: "today")
        ])

        XCTAssertEqual(response.status, "ambiguous")
        XCTAssertFalse(response.success)
        XCTAssertNil(response.error)
        XCTAssertNotNil(response.ambiguousRecipient)
    }
}

final class AppleScriptRunnerValidationTests: XCTestCase {
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
}
