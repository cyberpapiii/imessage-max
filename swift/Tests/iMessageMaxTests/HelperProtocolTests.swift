import XCTest
@testable import iMessageMax

final class HelperProtocolTests: XCTestCase {
    func testCreateChatRequestEncodesWithSnakeCaseAndTrailingNewline() throws {
        let req = HelperRequest.createChat(
            id: "abc", addresses: ["+15550000001", "+15550000002"], service: "iMessage")
        let data = try HelperWire.encode(req)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasSuffix("\n"))
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["v"] as? Int, 1)
        XCTAssertEqual(obj["cmd"] as? String, "create-chat")
        XCTAssertEqual(obj["addresses"] as? [String], ["+15550000001", "+15550000002"])
        XCTAssertEqual(obj["service"] as? String, "iMessage")
    }

    func testDecodeSuccessResponseMapsChatGuid() throws {
        let line = Data(#"{"v":1,"id":"abc","ok":true,"chat_guid":"iMessage;+;g"}"#.utf8)
        let resp = try HelperWire.decode(line)
        XCTAssertEqual(resp, HelperResponse(v: 1, id: "abc", ok: true,
                                            chatGuid: "iMessage;+;g", error: nil))
    }

    func testDecodeErrorResponse() throws {
        let line = Data(#"{"v":1,"id":"x","ok":false,"error":{"code":"handle_not_found","message":"no"}}"#.utf8)
        let resp = try HelperWire.decode(line)
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error, HelperWireError(code: "handle_not_found", message: "no"))
    }
}
