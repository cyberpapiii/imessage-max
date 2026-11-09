import XCTest
import MCP
@testable import iMessageMax

final class ToolRegistryTests: XCTestCase {
    func testRegisterAllDoesNotExposeLegacyUpdateTool() async {
        let catalog = makeTestCatalog()

        let tools = catalog.tools
        let names = Set(tools.map(\.name))

        XCTAssertFalse(names.contains("update"))
        XCTAssertEqual(names, [
            "diagnose",
            "find_chat",
            "get_active_conversations",
            "get_attachment",
            "get_chat_details",
            "get_context",
            "get_messages",
            "get_messages_since",
            "get_unread",
            "list_attachments",
            "list_chats",
            "search",
            "send",
        ])
    }

    func testSendSchemaDoesNotAdvertiseReplyTo() throws {
        let send = try XCTUnwrap(makeTestCatalog().tools.first { $0.name == "send" })
        guard case .object(let schema) = send.inputSchema,
              case .object(let properties) = schema["properties"] else {
            return XCTFail("Expected send inputSchema.properties to be an object")
        }
        XCTAssertNil(properties["reply_to"], "send schema must not advertise reply_to")
    }
}
