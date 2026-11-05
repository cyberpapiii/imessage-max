import XCTest
import MCP
@testable import iMessageMax

final class GetContextToolTests: XCTestCase {
    func testMessageIdReturnsBeforeAndAfterInDateOrder() async throws {
        let fixture = try makeGetMessagesFixture()
        let result = await capture { try await GetContext.execute(
            messageId: "msg_202",
            before: 5,
            after: 5,
            database: fixture.database(),
            resolver: makeSeededResolver()
        ) }

        let response = try unwrapSuccess(result)
        XCTAssertEqual(response.message.id, "msg_202")
        XCTAssertEqual(response.before.map(\.id), ["msg_200", "msg_201"])
        XCTAssertEqual(response.after.map(\.id), ["msg_203"])
    }

    func testMessagesSharingTheAnchorTimestampStayInTheWindow() async throws {
        let fixture = try ToolTestDatabase(name: "context-same-timestamp")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 1, guid: "twin-chat", displayName: "Twins")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)
        let rows: [(id: Int, date: Int64)] = [(1, 100), (2, 200), (3, 200), (4, 200), (5, 300)]
        for row in rows {
            try fixture.insertMessage(rowId: row.id, guid: "g\(row.id)", text: "m\(row.id)", date: row.date, isFromMe: false, handleId: 1)
            try fixture.joinChatMessage(chatId: 1, messageId: row.id)
        }

        let response = try unwrapSuccess(await capture { try await GetContext.execute(
            messageId: "msg_3",
            database: fixture.database(),
            resolver: makeSeededResolver()
        ) })
        XCTAssertEqual(response.before.map(\.id), ["msg_1", "msg_2"])
        XCTAssertEqual(response.after.map(\.id), ["msg_4", "msg_5"])
    }

    func testPeopleLeaveOutSendersOfUnmappedAssociatedTypes() async throws {
        let fixture = try ToolTestDatabase(name: "context-type-4000")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertHandle(rowId: 2, handle: "+15550000002")
        try fixture.insertChat(rowId: 1, guid: "type-4000-chat", displayName: "Polls")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)
        try fixture.joinChatHandle(chatId: 1, handleId: 2)
        try fixture.insertMessage(rowId: 1, guid: "g1", text: "anchor", date: 100, isFromMe: false, handleId: 1)
        try fixture.joinChatMessage(chatId: 1, messageId: 1)
        try fixture.insertMessage(
            rowId: 2, guid: "g2", text: nil, date: 200, isFromMe: false, handleId: 2,
            associatedMessageType: 4000, associatedMessageGuid: "p:0/g1"
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 2)

        let response = try unwrapSuccess(await capture { try await GetContext.execute(
            messageId: "msg_1",
            database: fixture.database(),
            resolver: makeSeededResolver()
        ) })
        XCTAssertEqual(Set(response.people.keys), ["alice"])
        XCTAssertNil(response.message.reactions)
    }

    func testBeforeAndAfterDefaultsAreFiveAndTen() async throws {
        let fixture = try makeLongChatFixture(messageCount: 40)
        let result = await capture { try await GetContext.execute(
            messageId: "msg_1020",
            database: fixture.database(),
            resolver: makeSeededResolver()
        ) }

        let response = try unwrapSuccess(result)
        XCTAssertEqual(response.before.count, 5)
        XCTAssertEqual(response.after.count, 10)
        XCTAssertEqual(response.before.first?.id, "msg_1015")
        XCTAssertEqual(response.after.last?.id, "msg_1030")
    }

    func testBeforeAndAfterClampToFifty() async throws {
        let fixture = try makeLongChatFixture(messageCount: 150)
        let clamped = await capture { try await GetContext.execute(
            messageId: "msg_1075",
            before: 500,
            after: 500,
            database: fixture.database(),
            resolver: makeSeededResolver()
        ) }
        let clampedResponse = try unwrapSuccess(clamped)
        XCTAssertEqual(clampedResponse.before.count, 50)
        XCTAssertEqual(clampedResponse.after.count, 50)

        let negative = await capture { try await GetContext.execute(
            messageId: "msg_1075",
            before: -3,
            after: -3,
            database: fixture.database(),
            resolver: makeSeededResolver()
        ) }
        let negativeResponse = try unwrapSuccess(negative)
        XCTAssertTrue(negativeResponse.before.isEmpty)
        XCTAssertTrue(negativeResponse.after.isEmpty)
    }

    func testMissingArgumentsIsInvalidParams() async throws {
        let missingBoth = await capture { try await GetContext.execute(database: Database(), resolver: ContactResolver(seedCache: [:])) }
        try assertFailure(
            missingBoth,
            error: "invalid_params",
            message: "Either message_id OR (chat_id + contains) is required"
        )

        // First guard fires when contains is set and chat_id is not:
        // chatId == nil makes (chatId == nil || contains == nil) true.
        let containsOnly = await capture { try await GetContext.execute(contains: "x", database: Database(), resolver: ContactResolver(seedCache: [:])) }
        try assertFailure(
            containsOnly,
            error: "invalid_params",
            message: "Either message_id OR (chat_id + contains) is required"
        )

        // Second string is reachable only when message_id is also present.
        let containsWithMessageId = await capture { try await GetContext.execute(messageId: "msg_1", contains: "x", database: Database(), resolver: ContactResolver(seedCache: [:])) }
        try assertFailure(
            containsWithMessageId,
            error: "invalid_params",
            message: "chat_id is required when using contains"
        )
    }

    func testInvalidMessageIdIsInvalidId() async throws {
        let result = await capture { try await GetContext.execute(messageId: "nope", database: Database(), resolver: ContactResolver(seedCache: [:])) }
        try assertFailure(result, error: "invalid_id")
    }

    func testUnknownMessageIdIsNotFound() async throws {
        let fixture = try makeGetMessagesFixture()
        let result = await capture { try await GetContext.execute(
            messageId: "msg_999999",
            database: fixture.database(),
            resolver: makeSeededResolver()
        ) }
        try assertFailure(
            result,
            error: "not_found",
            message: "Target message not found. Call search or get_messages for a current message_id."
        )
    }

    func testUnresolvableChatIdWithContainsIsChatNotFound() async throws {
        let fixture = try makeGetMessagesFixture()
        let result = await capture { try await GetContext.execute(chatId: "chat_abc", contains: "x", database: fixture.database(), resolver: ContactResolver(seedCache: [:])) }
        try assertFailure(result, error: "chat_not_found")
    }

    func testContainsFindsNewestMatchWithinWindow() async throws {
        let fixture = try makeGetMessagesFixture()
        let result = await capture { try await GetContext.execute(
            chatId: "chat20",
            contains: "VOLCANO",
            database: fixture.database(),
            resolver: makeSeededResolver()
        ) }

        let response = try unwrapSuccess(result)
        XCTAssertEqual(response.message.id, "msg_201")
        XCTAssertTrue(response.before.contains(where: { $0.id == "msg_200" }))
        XCTAssertTrue(response.after.contains(where: { $0.id == "msg_202" }))
    }

    func testContainsMatchesAttributedBodyOnlyRows() async throws {
        let fixture = try makeLongChatFixture(messageCount: 3)
        let payload = Array("hidden phrase".utf8)
        let blob = typedstreamBlob(lengthField: [UInt8(payload.count)], payload: payload)
        try fixture.insertMessage(
            rowId: 2000,
            guid: "hidden-attr",
            text: nil,
            date: 2_000_000_000_000,
            isFromMe: false,
            handleId: 1,
            attributedBody: blob
        )
        try fixture.joinChatMessage(chatId: 50, messageId: 2000)

        let result = await capture { try await GetContext.execute(
            chatId: "chat50",
            contains: "hidden",
            database: fixture.database(),
            resolver: makeSeededResolver()
        ) }
        let response = try unwrapSuccess(result)
        XCTAssertEqual(response.message.id, "msg_2000")
    }

    func testContainsFindsMatchBeyondNewestFiveHundred() async throws {
        let fixture = try makeLongChatFixture(messageCount: 600)
        try fixture.execute("UPDATE message SET text = 'needle in the old part' WHERE ROWID = 1010")

        let result = await capture { try await GetContext.execute(
            chatId: "chat50",
            contains: "needle",
            database: fixture.database(),
            resolver: makeSeededResolver()
        ) }
        guard case .success(let response) = result else {
            return XCTFail("Expected get_context success")
        }
        XCTAssertEqual(response.message.id, "msg_1010")
    }

    func testContainsMissReturnsNotFoundWithinCap() async throws {
        let fixture = try makeLongChatFixture(messageCount: 50)
        let result = await capture { try await GetContext.execute(
            chatId: "chat50",
            contains: "zzz-never",
            database: fixture.database(),
            resolver: makeSeededResolver()
        ) }
        try assertFailure(result, error: "not_found")
    }

    func testContainsTreatsPercentAndUnderscoreLiterally() async throws {
        let fixture = try makeLongChatFixture(messageCount: 20)
        try fixture.execute("UPDATE message SET text = '100% done' WHERE ROWID = 1005")
        try fixture.execute("UPDATE message SET text = 'a_b' WHERE ROWID = 1008")

        let percent = await capture { try await GetContext.execute(
            chatId: "chat50",
            contains: "%",
            database: fixture.database(),
            resolver: makeSeededResolver()
        ) }
        XCTAssertEqual(try unwrapSuccess(percent).message.id, "msg_1005")

        let underscore = await capture { try await GetContext.execute(
            chatId: "chat50",
            contains: "_",
            database: fixture.database(),
            resolver: makeSeededResolver()
        ) }
        XCTAssertEqual(try unwrapSuccess(underscore).message.id, "msg_1008")

        let noWildcard = await capture { try await GetContext.execute(
            chatId: "chat50",
            contains: "x_y",
            database: fixture.database(),
            resolver: makeSeededResolver()
        ) }
        try assertFailure(noWildcard, error: "not_found")
    }

    func testContainsMissBeyondCapIsNotFoundInWindow() async throws {
        let fixture = try makeLongChatFixture(messageCount: 5100)
        // Cap counts post-prefilter candidates: blobs holding the term's
        // bytes pass the SQL prefilter but decode to no text.
        try fixture.execute("UPDATE message SET text = NULL, attributedBody = CAST('zzz-never' AS BLOB)")
        let result = await capture { try await GetContext.execute(
            chatId: "chat50",
            contains: "zzz-never",
            database: fixture.database(),
            resolver: makeSeededResolver()
        ) }
        try assertFailure(result, error: "not_found_in_window", messageContains: "5000")
    }

    func testMissingReplyAndEditColumnsDegradeContext() async throws {
        let fixture = try makeGetMessagesFixture()
        try fixture.execute("ALTER TABLE message DROP COLUMN thread_originator_guid")
        try fixture.execute("ALTER TABLE message DROP COLUMN date_edited")
        try fixture.execute("ALTER TABLE message DROP COLUMN associated_message_emoji")
        let result = await capture { try await GetContext.execute(
            messageId: "msg_202",
            before: 5,
            after: 5,
            database: fixture.database(),
            resolver: makeSeededResolver()
        ) }
        let response = try unwrapSuccess(result)
        XCTAssertEqual(response.message.id, "msg_202")
        XCTAssertEqual(response.before.map(\.id), ["msg_200", "msg_201"])
        XCTAssertEqual(response.after.map(\.id), ["msg_203"])
    }
}

private func makeLongChatFixture(messageCount: Int) throws -> ToolTestDatabase {
    let fixture = try ToolTestDatabase(name: "get-context-long")
    try fixture.insertHandle(rowId: 1, handle: "+15550000001")
    try fixture.insertHandle(rowId: 2, handle: "+15550000002")
    try fixture.insertChat(rowId: 50, guid: "chat-long-guid", displayName: "Long Chat")
    try fixture.joinChatHandle(chatId: 50, handleId: 1)
    try fixture.joinChatHandle(chatId: 50, handleId: 2)

    let base: Int64 = 1_000_000_000_000
    let minute: Int64 = 60 * 1_000_000_000

    try fixture.execute("BEGIN")
    for i in 0..<messageCount {
        try fixture.insertMessage(
            rowId: 1000 + i,
            guid: "long-\(i)",
            text: "filler \(i)",
            date: base + Int64(i) * minute,
            isFromMe: i % 2 == 0,
            handleId: (i % 2 == 0) ? 1 : nil
        )
        try fixture.joinChatMessage(chatId: 50, messageId: 1000 + i)
    }
    try fixture.execute("COMMIT")
    return fixture
}

/// Builds: <prefix junk> + marker + 5 filler bytes + length field + payload.
/// Copied from MessageTextExtractorTests / SearchRecallTests.

private func unwrapSuccess(
    _ result: Result<GetContextResponse, ToolFailure>,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> GetContextResponse {
    guard case .success(let response) = result else {
        XCTFail("Expected get_context success", file: file, line: line)
        throw NSError(domain: "GetContextToolTests", code: 1)
    }
    return response
}

private func assertFailure(
    _ result: Result<GetContextResponse, ToolFailure>,
    error: String,
    message: String? = nil,
    messageContains: String? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard case .failure(let failure) = result else {
        XCTFail("Expected failure \(error)", file: file, line: line)
        throw NSError(domain: "GetContextToolTests", code: 2)
    }
    let body = try decodeJSONDictionary(from: failure.content)
    let err = (error: body["error"] as? String ?? "", message: body["message"] as? String ?? "")
    XCTAssertEqual(err.error, error, file: file, line: line)
    if let message {
        XCTAssertEqual(err.message, message, file: file, line: line)
    }
    if let messageContains {
        XCTAssertTrue(
            err.message.contains(messageContains),
            "'\(err.message)' does not contain '\(messageContains)'",
            file: file,
            line: line
        )
    }
}

private func capture(_ call: () async throws -> GetContextResponse) async -> Result<GetContextResponse, ToolFailure> {
    do {
        return .success(try await call())
    } catch let failure as ToolFailure {
        return .failure(failure)
    } catch {
        return .failure(ToolFailure(error, tool: "get_context"))
    }
}
