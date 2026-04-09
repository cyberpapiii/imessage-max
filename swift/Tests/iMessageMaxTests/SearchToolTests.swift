import XCTest
@testable import iMessageMax

final class SearchToolTests: XCTestCase {
    func testAnyWordVsMatchAll() async throws {
        let fixture = try makeSearchFixture()
        let resolver = makeSeededResolver()

        let anyWord = try await decodeSearchResponse(
            SearchTool.execute(
                query: "costa trip",
                cursor: nil,
                limit: 10,
                sort: "recent_first",
                format: "flat",
                includeContext: false,
                unanswered: false,
                unansweredHours: 24,
                matchAll: false,
                fuzzy: false,
                db: fixture.database(),
                resolver: resolver
            )
        )
        let anyResults = try decodeJSONArray(try XCTUnwrap(anyWord["results"]))
        XCTAssertEqual(Set(anyResults.compactMap { $0["id"] as? String }), Set(["msg_200", "msg_250", "msg_300"]))

        let allWords = try await decodeSearchResponse(
            SearchTool.execute(
                query: "costa trip",
                cursor: nil,
                limit: 10,
                sort: "recent_first",
                format: "flat",
                includeContext: false,
                unanswered: false,
                unansweredHours: 24,
                matchAll: true,
                fuzzy: false,
                db: fixture.database(),
                resolver: resolver
            )
        )
        let allResults = try decodeJSONArray(try XCTUnwrap(allWords["results"]))
        XCTAssertEqual(allResults.count, 1)
        XCTAssertEqual(allResults.first?["id"] as? String, "msg_200")
    }

    func testFuzzySearchMatchesTyposAndIncludesContext() async throws {
        let fixture = try makeSearchFixture()
        let resolver = makeSeededResolver()

        let response = try await decodeSearchResponse(
            SearchTool.execute(
                query: "volcno",
                cursor: nil,
                limit: 10,
                sort: "recent_first",
                format: "flat",
                includeContext: true,
                unanswered: false,
                unansweredHours: 24,
                matchAll: false,
                fuzzy: true,
                db: fixture.database(),
                resolver: resolver
            )
        )

        let results = try decodeJSONArray(try XCTUnwrap(response["results"]))
        XCTAssertEqual(Set(results.compactMap { $0["id"] as? String }), Set(["msg_200", "msg_201"]))
        guard let olderResult = results.first(where: { $0["id"] as? String == "msg_200" }) else {
            return XCTFail("Expected fuzzy match for older volcano message")
        }

        let after = try decodeJSONArray(olderResult["context_after"])
        guard let firstAfter = after.first else {
            return XCTFail("Expected context after")
        }
        XCTAssertEqual(firstAfter["id"] as? String, "msg_201")
    }

    func testChatAndHasLinkFilters() async throws {
        let fixture = try makeSearchFixture()
        let resolver = makeSeededResolver()

        let response = try await decodeSearchResponse(
            SearchTool.execute(
                inChat: "chat20",
                has: "link",
                cursor: nil,
                limit: 10,
                sort: "recent_first",
                format: "flat",
                includeContext: false,
                unanswered: false,
                unansweredHours: 24,
                matchAll: false,
                fuzzy: false,
                db: fixture.database(),
                resolver: resolver
            )
        )

        let results = try decodeJSONArray(try XCTUnwrap(response["results"]))
        XCTAssertEqual(results.count, 1)
        guard let firstResult = results.first else {
            return XCTFail("Expected first result")
        }
        XCTAssertEqual(firstResult["id"] as? String, "msg_201")
    }

    func testFromPersonGroupedResponseUsesStablePeopleKeysAndGeneratedChatNames() async throws {
        let fixture = try makeSearchFixture()
        let resolver = makeSeededResolver()

        let response = try await decodeSearchResponse(
            SearchTool.execute(
                fromPerson: "Bob",
                cursor: nil,
                limit: 10,
                sort: "recent_first",
                format: "grouped_by_chat",
                includeContext: false,
                unanswered: false,
                unansweredHours: 24,
                matchAll: false,
                fuzzy: false,
                db: fixture.database(),
                resolver: resolver
            )
        )

        let chats = try decodeJSONArray(try XCTUnwrap(response["chats"]))
        XCTAssertEqual(chats.count, 2)
        XCTAssertTrue(chats.allSatisfy { (($0["name"] as? String) ?? "").isEmpty == false })

        let people = try XCTUnwrap(response["people"] as? [String: Any])
        let bobEntries = people.compactMap { key, value -> String? in
            guard let dict = value as? [String: Any], dict["name"] as? String == "Bob Brown" else { return nil }
            return key
        }
        XCTAssertEqual(bobEntries.count, 1)

        guard let firstChat = chats.first else {
            return XCTFail("Expected grouped chats")
        }
        let sampleMessages = try decodeJSONArray(firstChat["sample_messages"])
        let firstSample = try XCTUnwrap(sampleMessages.first)
        XCTAssertEqual(firstSample["from"] as? String, bobEntries.first)
    }

    func testUnansweredSearchReturnsOnlyMessagesWithoutReplies() async throws {
        let fixture = try makeSearchFixture()
        let resolver = makeSeededResolver()

        let response = try await decodeSearchResponse(
            SearchTool.execute(
                cursor: nil,
                limit: 10,
                sort: "recent_first",
                format: "flat",
                includeContext: false,
                unanswered: true,
                unansweredHours: 24,
                matchAll: false,
                fuzzy: false,
                db: fixture.database(),
                resolver: resolver
            )
        )

        let results = try decodeJSONArray(try XCTUnwrap(response["results"]))
        XCTAssertEqual(results.count, 1)
        let firstResult = try XCTUnwrap(results.first)
        XCTAssertEqual(firstResult["id"] as? String, "msg_300")
    }

    func testCursorPaginatesSearchResults() async throws {
        let fixture = try makeSearchFixture()
        let resolver = makeSeededResolver()

        let pageOne = try await decodeSearchResponse(
            SearchTool.execute(
                fromPerson: "Bob",
                cursor: nil,
                limit: 1,
                sort: "recent_first",
                format: "flat",
                includeContext: false,
                unanswered: false,
                unansweredHours: 24,
                matchAll: false,
                fuzzy: false,
                db: fixture.database(),
                resolver: resolver
            )
        )

        let pageOneResults = try decodeJSONArray(try XCTUnwrap(pageOne["results"]))
        XCTAssertEqual(pageOneResults.count, 1)
        let cursor = try XCTUnwrap(pageOne["cursor"] as? String)
        guard let firstPageResult = pageOneResults.first else {
            return XCTFail("Expected first page result")
        }
        XCTAssertEqual(firstPageResult["id"] as? String, "msg_250")

        let pageTwo = try await decodeSearchResponse(
            SearchTool.execute(
                fromPerson: "Bob",
                cursor: cursor,
                limit: 1,
                sort: "recent_first",
                format: "flat",
                includeContext: false,
                unanswered: false,
                unansweredHours: 24,
                matchAll: false,
                fuzzy: false,
                db: fixture.database(),
                resolver: resolver
            )
        )

        let pageTwoResults = try decodeJSONArray(try XCTUnwrap(pageTwo["results"]))
        XCTAssertEqual(pageTwoResults.count, 1)
        guard let firstResult = pageTwoResults.first else {
            return XCTFail("Expected second page result")
        }
        XCTAssertEqual(firstResult["id"] as? String, "msg_200")
    }
}

private func decodeSearchResponse(_ result: Result<String, SearchError>) throws -> [String: Any] {
    switch result {
    case .success(let json):
        return try decodeJSONDictionary(from: json)
    case .failure(let error):
        XCTFail("Unexpected search error: \(error)")
        return [:]
    }
}

private func makeSearchFixture() throws -> ToolTestDatabase {
    let fixture = try ToolTestDatabase(name: "search")

    try fixture.insertHandle(rowId: 1, handle: "+15550000001")
    try fixture.insertHandle(rowId: 2, handle: "+15550000002")
    try fixture.insertHandle(rowId: 3, handle: "+15550000003")

    try fixture.insertChat(rowId: 10, guid: "chat-alice-guid", displayName: "Alice DM")
    try fixture.joinChatHandle(chatId: 10, handleId: 1)

    try fixture.insertChat(rowId: 20, guid: "chat-group-guid", displayName: nil)
    try fixture.joinChatHandle(chatId: 20, handleId: 1)
    try fixture.joinChatHandle(chatId: 20, handleId: 2)

    try fixture.insertChat(rowId: 30, guid: "chat-bob-guid", displayName: nil)
    try fixture.joinChatHandle(chatId: 30, handleId: 2)

    try fixture.insertMessage(rowId: 100, guid: "g100", text: "project alpha kickoff", date: 1_000_000_000, isFromMe: false, handleId: 1)
    try fixture.joinChatMessage(chatId: 10, messageId: 100)

    try fixture.insertMessage(rowId: 101, guid: "g101", text: "can you review the alpha plan?", date: 2_000_000_000, isFromMe: true)
    try fixture.joinChatMessage(chatId: 10, messageId: 101)

    try fixture.insertMessage(rowId: 102, guid: "g102", text: "yes I will review it", date: 3_000_000_000, isFromMe: false, handleId: 1)
    try fixture.joinChatMessage(chatId: 10, messageId: 102)

    try fixture.insertMessage(rowId: 200, guid: "g200", text: "trip to costa rica volcano", date: 4_000_000_000, isFromMe: false, handleId: 2)
    try fixture.joinChatMessage(chatId: 20, messageId: 200)

    try fixture.insertMessage(rowId: 201, guid: "g201", text: "see the volcano photos http://example.com", date: 5_000_000_000, isFromMe: true)
    try fixture.joinChatMessage(chatId: 20, messageId: 201)

    try fixture.insertMessage(rowId: 202, guid: "g202", text: "packing list", date: 6_000_000_000, isFromMe: false, handleId: 1)
    try fixture.joinChatMessage(chatId: 20, messageId: 202)

    try fixture.insertMessage(rowId: 250, guid: "g250", text: "trip planning notes", date: 6_500_000_000, isFromMe: false, handleId: 2)
    try fixture.joinChatMessage(chatId: 30, messageId: 250)

    try fixture.insertMessage(rowId: 300, guid: "g300", text: "let me know about the trip?", date: 7_000_000_000, isFromMe: true)
    try fixture.joinChatMessage(chatId: 30, messageId: 300)

    return fixture
}
