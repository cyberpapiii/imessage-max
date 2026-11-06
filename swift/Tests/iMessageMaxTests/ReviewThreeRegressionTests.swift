import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import IMessageMaxContract
import MCP
import NIOCore
import XCTest
@testable import iMessageMax

/// Regressions for the third review: one chat per message, the hidden-chat
/// rule for a chat named by id, and what counts as a reply.
final class ReviewThreeRegressionTests: XCTestCase {
    /// An hour ago, inside every tool's default window.
    private let recent = Int64(Date().timeIntervalSinceReferenceDate) * 1_000_000_000 - 3_600_000_000_000

    private func ids(_ json: [String: Any], _ key: String = "messages") throws -> [String] {
        try decodeJSONArray(json[key]).compactMap { $0["id"] as? String }
    }

    private func chatIds(_ json: [String: Any], _ key: String = "messages") throws -> [String?] {
        try decodeJSONArray(json[key]).map { ($0["chat"] as? [String: Any])?["id"] as? String }
    }

    /// Every page of `tool`, following its cursor.
    private func allPages(
        _ tool: String, _ args: [String: Value], key: String = "messages", database: Database
    ) async throws -> [String] {
        var seen: [String] = []
        var cursor: String?
        for _ in 0..<10 {
            var pageArgs = args
            if let cursor { pageArgs["cursor"] = .string(cursor) }
            let json = try await callTool(tool, pageArgs, database: database)
            seen += try ids(json, key)
            cursor = json["cursor"] as? String
            if cursor == nil { break }
        }
        return seen
    }

    // MARK: - One row per message in get_unread and search

    /// Message 2 is in chats 1 and 2. Listed once, it neither repeats on a
    /// page nor loses its second copy to the (date, ROWID) cursor.
    private func messageInTwoChats() throws -> ToolTestDatabase {
        let f = try ToolTestDatabase(name: "two-chats-\(UUID().uuidString)")
        try f.insertHandle(rowId: 1, handle: "+15550000001")
        try f.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
        try f.insertChat(rowId: 2, guid: "SMS;-;+15550000001", serviceName: "SMS")
        for row in 1...3 {
            try f.insertMessage(rowId: row, guid: "g\(row)", text: "hello \(row)", date: recent + Int64(row), isFromMe: false, handleId: 1)
            try f.joinChatMessage(chatId: 1, messageId: row)
        }
        try f.joinChatMessage(chatId: 2, messageId: 2)
        return f
    }

    func testUnreadMessagesListAMessageInTwoChatsOnceAcrossPages() async throws {
        let f = try messageInTwoChats()
        for limit in 1...3 {
            let seen = try await allPages(
                "get_unread", ["format": "messages", "limit": .int(limit)], database: f.database()
            )
            XCTAssertEqual(seen, ["msg_1", "msg_2", "msg_3"], "limit \(limit)")
        }
        let one = try await callTool("get_unread", ["format": "messages"], database: f.database())
        XCTAssertEqual(try chatIds(one), ["chat1", "chat1", "chat1"])
    }

    func testSearchListsAMessageInTwoChatsOnceAcrossPages() async throws {
        let f = try messageInTwoChats()
        for limit in 1...3 {
            for sort in ["recent_first", "oldest_first"] {
                let seen = try await allPages(
                    "search", ["query": "hello", "limit": .int(limit), "sort": .string(sort)],
                    key: "results", database: f.database()
                )
                XCTAssertEqual(Set(seen), ["msg_1", "msg_2", "msg_3"], "limit \(limit) \(sort)")
                XCTAssertEqual(seen.count, 3, "limit \(limit) \(sort)")
            }
        }
        let inSecond = try await callTool("search", ["query": "hello", "in_chat": "chat2"], database: f.database())
        XCTAssertEqual(try ids(inSecond, "results"), ["msg_2"])
        XCTAssertEqual(try chatIds(inSecond, "results"), ["chat2"])
    }

    // MARK: - A chat named by id is shown even when hidden

    private func hiddenChat() throws -> ToolTestDatabase {
        let f = try ToolTestDatabase(name: "named-hidden-\(UUID().uuidString)")
        try f.insertHandle(rowId: 1, handle: "+15550000001")
        try f.insertHandle(rowId: 2, handle: "spam@example.com")
        try f.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
        try f.insertChat(rowId: 5, guid: "iMessage;-;spam@example.com", isFiltered: 1)
        try f.insertMessage(rowId: 1, guid: "g1", text: "hello friend", date: recent, isFromMe: false, handleId: 1)
        try f.joinChatMessage(chatId: 1, messageId: 1)
        try f.insertMessage(rowId: 2, guid: "g2", text: "hello prize", date: recent + 1, isFromMe: false, handleId: 2)
        try f.joinChatMessage(chatId: 5, messageId: 2)
        return f
    }

    func testEveryToolShowsAHiddenChatNamedById() async throws {
        let f = try hiddenChat()
        let db = f.database()

        let search = try await callTool("search", ["query": "hello", "in_chat": "chat5"], database: db)
        XCTAssertEqual(try ids(search, "results"), ["msg_2"])
        XCTAssertEqual(search["filtered_hidden"] as? Int, 0)

        let unread = try await callTool("get_unread", ["format": "messages", "chat_id": "chat5"], database: db)
        XCTAssertEqual(try ids(unread), ["msg_2"])
        XCTAssertEqual(unread["total_unread"] as? Int, 1)
        XCTAssertEqual(unread["filtered_hidden"] as? Int, 0)

        let summary = try await callTool("get_unread", ["chat_id": "chat5"], database: db)
        XCTAssertEqual(try decodeJSONArray(summary["chats"]).count, 1)
        XCTAssertEqual(summary["filtered_hidden"] as? Int, 0)

        let since = try await callTool("get_messages_since", ["since_rowid": 0, "chat_id": "chat5"], database: db)
        XCTAssertEqual(try ids(since), ["msg_2"])
        XCTAssertEqual(since["filtered_hidden"] as? Int, 0)

        let messages = try await callTool("get_messages", ["chat_id": "chat5"], database: db)
        XCTAssertEqual(try ids(messages), ["msg_2"])

        // Unnamed, the hidden chat stays out and is counted.
        let all = try await callTool("search", ["query": "hello"], database: db)
        XCTAssertEqual(try ids(all, "results"), ["msg_1"])
        XCTAssertEqual(all["filtered_hidden"] as? Int, 1)
        let allSince = try await callTool("get_messages_since", ["since_rowid": 0], database: db)
        XCTAssertEqual(try ids(allSince), ["msg_1"])
        XCTAssertEqual(allSince["filtered_hidden"] as? Int, 1)
    }

    func testUnreadCountsHiddenChatsOnTheFirstPageOnly() async throws {
        let f = try hiddenChat()
        try f.insertMessage(rowId: 3, guid: "g3", text: "again", date: recent + 2, isFromMe: false, handleId: 1)
        try f.joinChatMessage(chatId: 1, messageId: 3)

        let first = try await callTool("get_unread", ["format": "messages", "limit": 1], database: f.database())
        XCTAssertEqual(first["filtered_hidden"] as? Int, 1)
        let cursor = try XCTUnwrap(first["cursor"] as? String)
        let second = try await callTool(
            "get_unread", ["format": "messages", "limit": 1, "cursor": .string(cursor)], database: f.database()
        )
        XCTAssertEqual(try ids(second), ["msg_3"])
        XCTAssertNil(second["filtered_hidden"])
    }

    // MARK: - A message whose lowest chat is hidden

    /// Message 1 is in hidden chat 1 and shown chat 2.
    private func homeChatHidden() throws -> ToolTestDatabase {
        let f = try ToolTestDatabase(name: "home-hidden-\(UUID().uuidString)")
        try f.insertHandle(rowId: 1, handle: "+15550000001")
        try f.insertChat(rowId: 1, guid: "SMS;-;+15550000001", serviceName: "SMS", isFiltered: 1)
        try f.insertChat(rowId: 2, guid: "iMessage;-;+15550000001")
        try f.insertMessage(rowId: 1, guid: "g1", text: "hello \u{FFFC}", date: recent, isFromMe: false, handleId: 1)
        try f.joinChatMessage(chatId: 1, messageId: 1)
        try f.joinChatMessage(chatId: 2, messageId: 1)
        try f.insertAttachment(rowId: 1, filename: "/nonexistent/a.pdf", mimeType: "application/pdf", uti: "com.adobe.pdf")
        try f.joinMessageAttachment(messageId: 1, attachmentId: 1)
        return f
    }

    func testAMessageAlsoInAShownChatIsListedThere() async throws {
        let f = try homeChatHidden()
        let db = f.database()

        let since = try await callTool("get_messages_since", ["since_rowid": 0], database: db)
        XCTAssertEqual(try chatIds(since), ["chat2"])
        XCTAssertEqual(since["filtered_hidden"] as? Int, 0)

        for sort in ["recent_first", "largest_first"] {
            let listed = try await callTool("list_attachments", ["sort": .string(sort)], database: db)
            XCTAssertEqual(try chatIds(listed), ["chat2"], sort)
        }

        let unread = try await callTool("get_unread", ["format": "messages"], database: db)
        XCTAssertEqual(try chatIds(unread), ["chat2"])

        let search = try await callTool("search", ["query": "hello"], database: db)
        XCTAssertEqual(try chatIds(search, "results"), ["chat2"])

        // With hidden chats read too, the lowest chat is home again.
        let included = try await callTool("get_messages_since", ["since_rowid": 0, "include_filtered": true], database: db)
        XCTAssertEqual(try chatIds(included), ["chat1"])
    }

    // MARK: - find_chat keeps every path's hidden count

    func testFindChatKeepsTheHiddenCountOfAPathThatFoundOnlyHiddenChats() async throws {
        let f = try ToolTestDatabase(name: "find-hidden-handover")
        try f.insertHandle(rowId: 1, handle: "+15550000001")
        try f.insertHandle(rowId: 2, handle: "+15550000002")
        try f.insertChat(rowId: 1, guid: "iMessage;+;chat-trip", displayName: "Trip")
        try f.joinChatHandle(chatId: 1, handleId: 1)
        try f.insertChat(rowId: 5, guid: "iMessage;-;+15550000002", isFiltered: 1)
        try f.joinChatHandle(chatId: 5, handleId: 2)
        // Bob's only chat is hidden, so the name path answers.
        let json = try await callTool("find_chat", ["participants": ["Bob"], "name": "Trip"], database: f.database())
        XCTAssertEqual(try decodeJSONArray(json["chats"]).count, 1)
        XCTAssertEqual(json["filtered_hidden"] as? Int, 1)

        // A hidden chat both paths match counts once.
        try f.execute("UPDATE chat SET display_name = 'Trip spam' WHERE ROWID = 5")
        let both = try await callTool("find_chat", ["participants": ["Bob"], "name": "Trip"], database: f.database())
        XCTAssertEqual(both["filtered_hidden"] as? Int, 1)
    }

    // MARK: - Only a conversational message answers a question

    func testAGroupEventDoesNotAnswerAQuestion() async throws {
        let f = try ToolTestDatabase(name: "unanswered-event")
        for row in 1...2 { try f.insertHandle(rowId: row, handle: "+1555000000\(row)") }
        try f.insertChat(rowId: 1, guid: "iMessage;+;chat-group", displayName: "Group")
        try f.joinChatHandle(chatId: 1, handleId: 1)
        try f.joinChatHandle(chatId: 1, handleId: 2)
        // A DM where the question did get a reply.
        try f.insertChat(rowId: 2, guid: "iMessage;-;+15550000002")
        try f.joinChatHandle(chatId: 2, handleId: 2)
        let minute: Int64 = 60_000_000_000
        try f.insertMessage(rowId: 1, guid: "q1", text: "dinner at 7?", date: recent, isFromMe: true)
        try f.insertMessage(rowId: 2, guid: "e1", text: nil, date: recent + minute, isFromMe: false, handleId: 1,
                            itemType: 2, groupTitle: "Dinner Club")
        for row in 1...2 { try f.joinChatMessage(chatId: 1, messageId: row) }
        try f.insertMessage(rowId: 3, guid: "q2", text: "who is driving?", date: recent, isFromMe: true)
        try f.insertMessage(rowId: 4, guid: "r2", text: "me", date: recent + minute, isFromMe: false, handleId: 2)
        for row in 3...4 { try f.joinChatMessage(chatId: 2, messageId: row) }

        let search = try await callTool("search", ["unanswered": true], database: f.database())
        XCTAssertEqual(try ids(search, "results"), ["msg_1"])

        let messages = try await callTool("get_messages", ["chat_id": "chat1", "unanswered": true], database: f.database())
        XCTAssertEqual(try ids(messages), ["msg_1"])
        let answered = try await callTool("get_messages", ["chat_id": "chat2", "unanswered": true], database: f.database())
        XCTAssertEqual(try ids(answered), [])
    }

    // MARK: - HTTP id errors on the tools/call shortcut

    /// The legacy tools/call shortcut answers a bad id as the SDK route
    /// does: 400 with -32600, never a 200 echoing an object id.
    func testToolsCallShortcutRejectsANonScalarIdLikeTheSDKRoute() async throws {
        let app = await reviewThreeTransport(catalog: ToolCatalog([])).application()
        try await app.test(TestingSetup.router) { client in
            let session = try await reviewThreeOpenSession(client)
            for body in [
                #"{"jsonrpc":"2.0","id":{"a":1},"method":"tools/call","params":{"name":"anything","arguments":{}}}"#,
                #"{"jsonrpc":"2.0","id":{"a":1},"method":"tools/list","params":{}}"#,
            ] {
                let response = try await client.executeRequest(
                    uri: "/", method: .post, headers: reviewThreeHeaders(session), body: ByteBuffer(string: body)
                )
                XCTAssertEqual(response.head.status, .badRequest, body)
                let json = try reviewThreeObject(response.body)
                XCTAssertTrue(json["id"] is NSNull, body)
                XCTAssertEqual((json["error"] as? [String: Any])?["code"] as? Int, -32600, body)
            }
        }
    }

    /// A tools/call reusing the id of a call still in flight is a 400 with
    /// the id, and the first call still answers.
    func testToolsCallShortcutRejectsAnIdInFlight() async throws {
        let (started, startedSink) = AsyncStream<Void>.makeStream()
        let slow = ToolDefinition(name: "slow", description: "", inputSchema: InputSchema.object(properties: [:])) { _ in
            startedSink.yield()
            await AsyncTimeout.sleep(.milliseconds(300))
            return [.plainText(#"{"done":true}"#)]
        }
        let app = await reviewThreeTransport(catalog: ToolCatalog([slow])).application()
        try await app.test(TestingSetup.router) { client in
            let session = try await reviewThreeOpenSession(client)
            let call = #"{"jsonrpc":"2.0","id":"dup","method":"tools/call","params":{"name":"slow","arguments":{}}}"#
            async let first = client.executeRequest(
                uri: "/", method: .post, headers: reviewThreeHeaders(session), body: ByteBuffer(string: call)
            )
            var iterator = started.makeAsyncIterator()
            _ = await iterator.next()

            for body in [call, #"{"jsonrpc":"2.0","id":"dup","method":"tools/list","params":{}}"#] {
                let second = try await client.executeRequest(
                    uri: "/", method: .post, headers: reviewThreeHeaders(session), body: ByteBuffer(string: body)
                )
                XCTAssertEqual(second.head.status, .badRequest, body)
                let json = try reviewThreeObject(second.body)
                XCTAssertEqual(json["id"] as? String, "dup", body)
                XCTAssertEqual((json["error"] as? [String: Any])?["code"] as? Int, -32600, body)
            }
            let firstStatus = try await first.head.status
            XCTAssertEqual(firstStatus, .ok)
        }
    }
}

private func reviewThreeTransport(catalog: ToolCatalog) -> HTTPTransport {
    HTTPTransport(
        host: "127.0.0.1",
        port: 0,
        catalog: catalog,
        setupPermissions: SetupPermissionService(
            contactsRequest: { (false, .notDetermined) },
            automationRequest: { (false, .notDetermined) }
        ),
        configuration: .init(requestTimeout: .seconds(5), cleanupInterval: .milliseconds(20))
    )
}

private func reviewThreeOpenSession(_ client: some TestClientProtocol) async throws -> String {
    var fields = HTTPFields()
    fields[.contentType] = "application/json"
    fields[.accept] = "application/json, text/event-stream"
    let response = try await client.executeRequest(
        uri: "/", method: .post, headers: fields,
        body: ByteBuffer(
            string: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"tests","version":"1.0"}}}"#
        )
    )
    return try XCTUnwrap(response.head.headerFields[HTTPField.Name(MCPHeader.sessionID)!])
}

private func reviewThreeHeaders(_ sessionId: String) -> HTTPFields {
    var fields = HTTPFields()
    fields[.contentType] = "application/json"
    fields[.accept] = "application/json, text/event-stream"
    fields[HTTPField.Name(MCPHeader.sessionID)!] = sessionId
    return fields
}

private func reviewThreeObject(_ body: ByteBuffer) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any])
}
