import XCTest
import MCP
@testable import iMessageMax

final class ToolRegistryTests: XCTestCase {
    func testRegisterAllDoesNotExposeLegacyUpdateTool() async {
        ToolHandlerRegistry.shared.resetForTesting()

        let server = Server(name: "test", version: "0")
        await ToolRegistry.registerAll(on: server, db: Database(), resolver: ContactResolver(seedCache: [:]))

        let tools = ToolHandlerRegistry.shared.getTools()
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
            "get_unread",
            "list_attachments",
            "list_chats",
            "search",
            "send",
        ])
    }

    func testCatchUpToolDescriptionsBiasTowardBroadOverviewThenNarrowing() async throws {
        ToolHandlerRegistry.shared.resetForTesting()

        let server = Server(name: "test", version: "0")
        await ToolRegistry.registerAll(on: server, db: Database(), resolver: ContactResolver(seedCache: [:]))

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
        await ToolRegistry.registerAll(on: server, db: Database(), resolver: ContactResolver(seedCache: [:]))

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
