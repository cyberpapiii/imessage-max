import XCTest
import MCP
@testable import iMessageMax

final class ResponseContractTests: XCTestCase {
    func testListChatsUsesLeanOverviewShape() async throws {
        let fixture = try makeOverviewFixture()
        let resolver = makeOverviewResolver()

        let result = await ListChatsTool.execute(
            limit: 5,
            db: fixture.database(),
            resolver: resolver
        )

        guard case .success(let response) = result else {
            return XCTFail("Expected list_chats success")
        }

        guard let first = response.chats.first else {
            return XCTFail("Expected chat")
        }
        let chatJSON = try encodedJSONString(first)
        XCTAssertFalse(chatJSON.contains("\"identity\""))
        XCTAssertFalse(chatJSON.contains("\"participants\""))
        XCTAssertTrue(chatJSON.contains("\"last_message\""))
    }

    func testGetActiveConversationsUsesLeanOverviewShape() async throws {
        let fixture = try makeOverviewFixture()
        let resolver = makeOverviewResolver()

        let result = try await GetActiveConversations.execute(
            hours: 48,
            minExchanges: 1,
            limit: 5,
            database: fixture.database(),
            resolver: resolver
        )

        guard let conversation = result.conversations.first else {
            return XCTFail("Expected conversation")
        }
        let encoded = try encodedJSONString(conversation)
        XCTAssertFalse(encoded.contains("\"participants\""))
        XCTAssertTrue(encoded.contains("\"participants_preview\""))
        XCTAssertTrue(encoded.contains("\"last_message\""))
        XCTAssertTrue(encoded.contains("\"activity\""))
    }

    func testGetUnreadDefaultsToChatSummariesAndSupportsMessagesMode() async throws {
        let fixture = try makeOverviewFixture()
        let tool = GetUnread(database: fixture.database(), contactResolver: makeOverviewResolver())

        let summaryAny = try await tool.execute(params: GetUnread.Parameters())
        guard let summary = summaryAny as? UnreadSummaryResponse else {
            return XCTFail("Expected default unread response to be summary")
        }
        guard let firstChat = summary.chats.first else {
            return XCTFail("Expected unread chat")
        }
        XCTAssertNotNil(firstChat.lastMessage)
        XCTAssertFalse(try encodedJSONString(summary).contains("\"people\""))

        let messagesAny = try await tool.execute(params: GetUnread.Parameters(format: .messages))
        guard let messages = messagesAny as? UnreadMessagesResponse else {
            return XCTFail("Expected messages unread response")
        }
        guard let firstMessage = messages.messages.first else {
            return XCTFail("Expected unread message")
        }
        XCTAssertFalse(try encodedJSONString(messages).contains("\"people\""))
        XCTAssertFalse((try decodeJSONDictionary(from: encodedJSONString(firstMessage)))["chat"] == nil)
    }

    func testListAttachmentsUsesNestedChatAndMessagePreview() async throws {
        let fixture = try makeOverviewFixture()
        let resolver = makeOverviewResolver()
        let tool = ListAttachments(db: fixture.database(), resolver: resolver)

        let result = await tool.execute(type: "image", limit: 5)
        guard case .success(let response) = result else {
            return XCTFail("Expected list_attachments success")
        }

        guard let first = response.messages.first else {
            return XCTFail("Expected shared message row")
        }
        let encoded = try encodedJSONString(first)
        XCTAssertTrue(encoded.contains("\"chat\""))
        XCTAssertTrue(encoded.contains("\"shared_summary\""))
        XCTAssertTrue(encoded.contains("\"attachments\""))
        XCTAssertFalse(encoded.contains("\"chat_name\""))
        XCTAssertFalse(encoded.contains("\"mime\""))
    }

    func testFindChatKeepsDetailLayerFields() async throws {
        let fixture = try makeGetMessagesFixture()
        let response = try decodeJSONDictionary(from: try decodeJSONString(from: try await FindChatTool.execute(
            arguments: ["participants": .array([.string("Alice"), .string("Bob")])],
            database: fixture.database(),
            resolver: makeSeededResolver()
        )))

        let chats = try decodeJSONArray(response["chats"])
        guard let first = chats.first else {
            return XCTFail("Expected chat result")
        }
        XCTAssertNotNil(first["participants_preview"])
        XCTAssertNotNil(first["last_message"])
        XCTAssertNotNil(first["participants"])
        XCTAssertNotNil(first["identity"])
        let match = try XCTUnwrap(first["match"] as? [String: Any])
        XCTAssertEqual(match["type"] as? String, "participants")
    }

    func testGetContextUsesMessageFieldNotTarget() async throws {
        let fixture = try makeGetMessagesFixture()
        let result = await GetContext.execute(
            messageId: "msg_200",
            database: fixture.database(),
            resolver: makeSeededResolver()
        )

        guard case .success(let response) = result else {
            return XCTFail("Expected get_context success")
        }

        let encoded = try decodeJSONDictionary(from: try encodedJSONString(response))
        XCTAssertNotNil(encoded["message"])
        XCTAssertNil(encoded["target"])
    }

    func testGetContextGeneratesHumanChatNameForUnnamedChats() async throws {
        let fixture = try makeGetMessagesFixture()
        let result = await GetContext.execute(
            messageId: "msg_200",
            database: fixture.database(),
            resolver: makeSeededResolver()
        )

        guard case .success(let response) = result else {
            return XCTFail("Expected get_context success")
        }

        XCTAssertEqual(response.chat.id, "chat20")
        let chatName = try XCTUnwrap(response.chat.name)
        XCTAssertEqual(
            Set(chatName.components(separatedBy: ", ").filter { !$0.isEmpty }),
            ["Alice Smith", "Bob Brown"]
        )
    }

    func testSearchFlatUsesExcerptAndNestedChat() async throws {
        let fixture = try makeSearchFixture()
        let resolver = makeSeededResolver()

        let response = try await decodeSearchResponse(
            SearchTool.execute(
                query: "appointment",
                limit: 10,
                format: "flat",
                db: fixture.database(),
                resolver: resolver
            )
        )

        let results = try decodeJSONArray(try XCTUnwrap(response["results"]))
        guard let first = results.first else {
            return XCTFail("Expected search result")
        }
        XCTAssertNotNil(first["excerpt"])
        XCTAssertNotNil(first["chat"])
        XCTAssertNil(first["text"])
        XCTAssertNil(response["people"])
    }

    func testSendResponseUsesNestedChat() throws {
        let response = SendResponse.success(
            deliveredTo: ["Contact A"],
            chat: ChatReference(id: "chat42", name: "Project Group")
        )

        let encoded = try decodeJSONDictionary(from: try encodedJSONString(response))
        XCTAssertNotNil(encoded["chat"])
        XCTAssertNil(encoded["success"])
        XCTAssertNil(encoded["message_id"])
    }

    func testDiagnoseResultEncodesGroupedSections() throws {
        let sample = DiagnoseResult(
            version: "1.2.1",
            processId: 123,
            status: "ready",
            database: .init(accessible: true, status: "ok", path: "/tmp/chat.db", fix: nil),
            contacts: .init(authorized: true, status: "authorized", loaded: 10, fix: nil),
            capabilities: [
                "send_text_dm":    Capability(state: "supported"),
                "send_text_group": Capability(state: "supported"),
                "send_file_dm":    Capability(state: "supported"),
                "send_file_group": Capability(state: "risky-private"),
                "verified_send":   Capability(state: "supported", detail: "db_reread"),
                "attachments_read": Capability(state: "supported"),
                "attachments_offloaded": Capability(state: "supported"),
                "reply_threading": Capability(state: "unsupported"),
                "tapbacks":        Capability(state: "unsupported"),
                "edit_unsend":     Capability(state: "unsupported"),
                "live_inbox":      Capability(state: "unavailable"),
                "perm_full_disk":  Capability(state: "supported"),
                "perm_contacts":   Capability(state: "supported"),
                "perm_automation": Capability(state: "supported"),
                "rich_backend":    Capability(state: "unavailable"),
            ]
        )

        let encoded = try decodeJSONDictionary(from: try encodedJSONString(sample))
        XCTAssertNotNil(encoded["database"])
        XCTAssertNotNil(encoded["contacts"])
        XCTAssertNotNil(encoded["capabilities"])
        XCTAssertNil(encoded["database_accessible"])
        XCTAssertNil(encoded["contacts_authorized"])

        // Verify new state-based shape: capabilities is a dict of objects with "state" keys
        let caps = try XCTUnwrap(encoded["capabilities"] as? [String: Any])
        let sendDM = try XCTUnwrap(caps["send_text_dm"] as? [String: Any])
        XCTAssertEqual(sendDM["state"] as? String, "supported")
        XCTAssertEqual(caps.count, 15)
    }
}

private func encodedJSONString<T: Encodable>(_ value: T) throws -> String {
    try FormatUtils.encodeJSON(value)
}
