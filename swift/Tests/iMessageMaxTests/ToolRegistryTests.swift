import XCTest
import MCP
@testable import iMessageMax

final class ToolRegistryTests: XCTestCase {
    func testRegisterAllDoesNotExposeLegacyUpdateTool() async {
        let catalog = ToolCatalog(database: Database(), resolver: ContactResolver(seedCache: [:]))

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
}
