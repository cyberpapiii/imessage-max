import XCTest
@testable import iMessageMax

final class IconMetadataTests: XCTestCase {
    func testInjectServerIconsAddsIconForLatestProtocolInitializeResponse() throws {
        let response = Data("""
        {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","serverInfo":{"name":"imessage-max","title":"iMessage Max"},"capabilities":{}}}
        """.utf8)

        let injected = IconMetadata.injectServerIcons(into: response)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: injected) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        let icons = try XCTUnwrap(serverInfo["icons"] as? [[String: Any]])
        let icon = try XCTUnwrap(icons.first)

        XCTAssertEqual(icon["mimeType"] as? String, "image/png")
        XCTAssertEqual(icon["sizes"] as? [String], ["64x64"])
        XCTAssertTrue((icon["src"] as? String)?.hasPrefix("data:image/png;base64,") == true)
    }

    func testInjectServerIconsSkipsLegacyProtocolInitializeResponse() {
        let response = Data("""
        {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","serverInfo":{"name":"imessage-max","title":"iMessage Max"},"capabilities":{}}}
        """.utf8)

        let injected = IconMetadata.injectServerIcons(into: response)

        XCTAssertEqual(injected, response)
    }

    func testInjectServerIconsSkipsNonInitializeResponses() {
        let response = Data("""
        {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"send"}]}}
        """.utf8)

        let injected = IconMetadata.injectServerIcons(into: response)

        XCTAssertEqual(injected, response)
    }
}
