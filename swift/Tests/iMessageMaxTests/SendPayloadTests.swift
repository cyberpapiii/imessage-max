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
