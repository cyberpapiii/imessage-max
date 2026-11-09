import XCTest
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

    func testBuildAcceptsTextAtTheLengthLimit() {
        guard case .success = SendPayload.build(text: String(repeating: "a", count: 20_000), filePaths: nil) else {
            return XCTFail("20,000 characters is within the limit")
        }
    }

    func testBuildRejectsOverlongText() {
        guard case .failure(let message) = SendPayload.build(text: String(repeating: "a", count: 20_001), filePaths: nil) else {
            return XCTFail("Expected validation failure")
        }
        XCTAssertEqual(message, "Message too long (max 20,000 chars)")
    }

    func testBuildRejectsOverlongTextAfterFiles() {
        guard case .failure(let message) = SendPayload.build(
            text: String(repeating: "a", count: 20_001),
            filePaths: ["/tmp/a.png"]
        ) else {
            return XCTFail("Expected validation failure")
        }
        XCTAssertEqual(message, "Message too long (max 20,000 chars)")
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

    /// Process.run aborts the helper on an argument holding NUL (088 #2).
    func testBuildRejectsNULInTextOrAFilePath() {
        for (text, paths) in [("a\u{0}b", nil), ("hi", ["/tmp/a\u{0}.png"]), (nil, ["/tmp/a.png", "\u{0}"])] as [(String?, [String]?)] {
            guard case .failure(let message) = SendPayload.build(text: text, filePaths: paths) else {
                return XCTFail("Expected NUL to be rejected in \(String(describing: text)) \(String(describing: paths))")
            }
            XCTAssertEqual(message, Osascript.nulRejection)
        }
    }

    func testRecipientOrChatWithNULIsInvalid() {
        XCTAssertNotNil(SendTarget.participant(handle: "a\u{0}@x.com", chatId: nil).validationError)
        XCTAssertNotNil(SendTarget.chat(guid: "iMessage;-;\u{0}", chatId: 1).validationError)
        XCTAssertNil(SendTarget.participant(handle: "a@x.com", chatId: nil).validationError)
    }

    /// The backstop refuses before it starts osascript, so no process runs.
    func testOsascriptRefusesNULArguments() {
        guard case .failure(.invalidParams(let message)) = Osascript.run("return 1", arguments: ["a\u{0}b"]) else {
            return XCTFail("Expected osascript to refuse a NUL argument")
        }
        XCTAssertEqual(message, Osascript.nulRejection)
        guard case .failure(.invalidParams) = Osascript.run("return \"\u{0}\"", arguments: []) else {
            return XCTFail("Expected osascript to refuse a NUL script")
        }
    }
}
