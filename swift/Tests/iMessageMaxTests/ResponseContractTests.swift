import XCTest
import MCP
import IMessageMaxContract
@testable import iMessageMax

final class ResponseContractTests: XCTestCase {
    func testListChatsUsesLeanOverviewShape() async throws {
        let fixture = try makeOverviewFixture()
        let resolver = makeOverviewResolver()

        let result = try await ListChatsTool.execute(
            limit: 5,
            db: fixture.database(),
            resolver: resolver
        )

        let response = result

        guard let first = response.chats.first else {
            return XCTFail("Expected chat")
        }
        let chatJSON = try FormatUtils.encodeJSON(first)
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
        let encoded = try FormatUtils.encodeJSON(conversation)
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
        XCTAssertFalse(try FormatUtils.encodeJSON(summary).contains("\"people\""))

        let messagesAny = try await tool.execute(params: GetUnread.Parameters(format: .messages))
        guard let messages = messagesAny as? UnreadMessagesResponse else {
            return XCTFail("Expected messages unread response")
        }
        guard let firstMessage = messages.messages.first else {
            return XCTFail("Expected unread message")
        }
        XCTAssertFalse(try FormatUtils.encodeJSON(messages).contains("\"people\""))
        XCTAssertFalse((try decodeJSONDictionary(from: FormatUtils.encodeJSON(firstMessage)))["chat"] == nil)
    }

    func testListAttachmentsUsesNestedChatAndMessagePreview() async throws {
        let fixture = try makeOverviewFixture()
        let resolver = makeOverviewResolver()
        let tool = ListAttachments(db: fixture.database(), resolver: resolver)

        let result = try await tool.execute(type: "image", limit: 5)
        let response = result

        guard let first = response.messages.first else {
            return XCTFail("Expected shared message row")
        }
        let encoded = try FormatUtils.encodeJSON(first)
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
        let result = try await GetContext.execute(
            messageId: "msg_200",
            database: fixture.database(),
            resolver: makeSeededResolver()
        )

        let response = result

        let encoded = try decodeJSONDictionary(from: try FormatUtils.encodeJSON(response))
        XCTAssertNotNil(encoded["message"])
        XCTAssertNil(encoded["target"])
    }

    func testGetContextGeneratesHumanChatNameForUnnamedChats() async throws {
        let fixture = try makeGetMessagesFixture()
        let result = try await GetContext.execute(
            messageId: "msg_200",
            database: fixture.database(),
            resolver: makeSeededResolver()
        )

        let response = result

        XCTAssertEqual(response.chat.id, "chat20")
        let chatName = try XCTUnwrap(response.chat.name)
        XCTAssertEqual(
            Set(chatName.components(separatedBy: ", ").filter { !$0.isEmpty }),
            ["Alice Smith", "Bob Brown"]
        )
    }

    func testGetContextMirrorsReactionReplyAndEditFields() async throws {
        let fixture = try makeGetMessagesFixture()
        let result = try await GetContext.execute(
            messageId: "msg_202",
            before: 5,
            after: 5,
            database: fixture.database(),
            resolver: makeSeededResolver()
        )

        let response = result

        let encoded = try decodeJSONDictionary(from: try FormatUtils.encodeJSON(response))
        let message = try XCTUnwrap(encoded["message"] as? [String: Any])
        XCTAssertEqual(message["edited"] as? Bool, true)

        let before = try decodeJSONArray(try XCTUnwrap(encoded["before"]))
        let origin = try XCTUnwrap(before.first(where: { $0["id"] as? String == "msg_201" }))
        XCTAssertEqual(origin["reactions"] as? [String], ["❤️ alice", "🥕 bob", "🩵 sticker me"])
        XCTAssertEqual(origin["reply_count"] as? Int, 1)

        let after = try decodeJSONArray(try XCTUnwrap(encoded["after"]))
        let reply = try XCTUnwrap(after.first(where: { $0["id"] as? String == "msg_203" }))
        XCTAssertEqual(reply["reply_to"] as? String, "msg_201")
    }

    func testSearchFlatUsesExcerptAndNestedChat() async throws {
        let fixture = try makeSearchFixture()
        let resolver = makeSeededResolver()

        let response = try await decodeJSONDictionary(from:
            SearchTool.execute(
                query: "appointment",
                limit: 10,
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
}
