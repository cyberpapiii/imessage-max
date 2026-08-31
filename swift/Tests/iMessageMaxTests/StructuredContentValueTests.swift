import MCP
import XCTest
@testable import iMessageMax

/// The legacy lane builds structuredContent from the tool's own JSON text.
/// It stopped using `JSONDecoder` for that, so these pin the replacement to
/// what the decoder returns, case for case.
final class StructuredContentValueTests: XCTestCase {

    private func assertMatchesDecoder(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(Value.self, from: data)
        let object = try JSONSerialization.jsonObject(with: data)
        let built = try XCTUnwrap(Server.structuredValue(from: object), file: file, line: line)
        XCTAssertEqual(built, decoded, "Mismatch for \(json)", file: file, line: line)
    }

    func testScalarsMatchTheDecoder() throws {
        for json in [
            "{\"v\":null}",
            "{\"v\":true}",
            "{\"v\":false}",
            "{\"v\":0}",
            "{\"v\":-17}",
            "{\"v\":9007199254740993}",
            "{\"v\":1.5}",
            "{\"v\":-0.25}",
            "{\"v\":\"text\"}",
            "{\"v\":\"\"}",
            "{\"v\":\"quote \\\" and backslash \\\\ and newline \\n\"}",
            "{\"v\":\"emoji 🎉 and accents éü\"}",
        ] {
            try assertMatchesDecoder(json)
        }
    }

    func testDataURLStringsStillBecomeData() throws {
        try assertMatchesDecoder("{\"v\":\"data:text/plain;base64,aGVsbG8=\"}")
    }

    func testNestedShapesMatchTheDecoder() throws {
        try assertMatchesDecoder("[]")
        try assertMatchesDecoder("{}")
        try assertMatchesDecoder("""
            {"chats":[{"id":"chat1","name":"A","group":true,"participant_count":3,
             "participants_preview":["x","y"],"last_message":{"from":"Me","text":"hi","ago":"2m",
             "ts":"2026-08-31T00:00:00Z"},"awaiting_reply":false}],
             "total_chats":1,"more":false,"cursor":null}
            """)
    }

    func testRealToolPayloadMatchesTheDecoder() async throws {
        let fixture = try ToolTestDatabase(name: "structured-content")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 10, guid: "chat-10-guid", displayName: "Team")
        try fixture.joinChatHandle(chatId: 10, handleId: 1)
        try fixture.insertMessage(
            rowId: 1, guid: "msg-1", text: "hello \"there\"\nnext line",
            date: 700_000_000_000_000_000, isFromMe: false, handleId: 1
        )
        try fixture.joinChatMessage(chatId: 10, messageId: 1)

        let result = await ListChatsTool.execute(
            db: fixture.database(),
            resolver: ContactResolver(seedCache: [:])
        )
        guard case .success(let response) = result else { return XCTFail("execute failed") }
        try assertMatchesDecoder(try FormatUtils.encodeJSON(response))
    }
}
