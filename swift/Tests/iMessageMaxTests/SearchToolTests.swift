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

    func testFilteredChatsAreHiddenByDefault() async throws {
        let fixture = try ToolTestDatabase(name: "search-filtered")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        let now = Int64(Date().timeIntervalSinceReferenceDate * 1_000_000_000)
        let filters = [0, 1, 36]
        for (index, isFiltered) in filters.enumerated() {
            let chatId = index + 1
            try fixture.insertChat(
                rowId: chatId,
                guid: "search-filtered-\(chatId)",
                displayName: "Search Filtered \(chatId)",
                isFiltered: isFiltered
            )
            try fixture.joinChatHandle(chatId: chatId, handleId: 1)
            try fixture.insertMessage(
                rowId: chatId,
                guid: "zebra-\(chatId)",
                text: "zebra \(chatId)",
                date: now + Int64(chatId) * 1_000_000_000,
                isFromMe: false,
                handleId: 1
            )
            try fixture.joinChatMessage(chatId: chatId, messageId: chatId)
        }

        let hidden = try await decodeSearchResponse(
            SearchTool.execute(
                query: "zebra",
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
                resolver: ContactResolver(seedCache: [:])
            )
        )
        let hiddenResults = try decodeJSONArray(try XCTUnwrap(hidden["results"]))
        XCTAssertEqual(hiddenResults.compactMap { $0["id"] as? String }, ["msg_1"])
        XCTAssertEqual(hidden["filtered_hidden"] as? Int, 2)

        let shown = try await decodeSearchResponse(
            SearchTool.execute(
                query: "zebra",
                cursor: nil,
                limit: 10,
                sort: "recent_first",
                format: "flat",
                includeContext: false,
                unanswered: false,
                unansweredHours: 24,
                matchAll: false,
                fuzzy: false,
                includeFiltered: true,
                db: fixture.database(),
                resolver: ContactResolver(seedCache: [:])
            )
        )
        let shownResults = try decodeJSONArray(try XCTUnwrap(shown["results"]))
        XCTAssertEqual(Set(shownResults.compactMap { $0["id"] as? String }), Set(["msg_1", "msg_2", "msg_3"]))
        XCTAssertNil(shown["filtered_hidden"])
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

    func testHasLinkDoesNotMatchLiteralPercentOrUnderscore() async throws {
        let fixture = try ToolTestDatabase(name: "search-link-escape")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 1, guid: "chat-link-guid", displayName: "Links")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)
        try fixture.insertMessage(
            rowId: 1,
            guid: "g-percent",
            text: "sale 50%_off today",
            date: 1_000,
            isFromMe: false,
            handleId: 1
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 1)
        try fixture.insertMessage(
            rowId: 2,
            guid: "g-http",
            text: "see http://example.com",
            date: 2_000,
            isFromMe: false,
            handleId: 1
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 2)

        let response = try await decodeSearchResponse(
            SearchTool.execute(
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
                resolver: makeSeededResolver()
            )
        )
        let results = try decodeJSONArray(try XCTUnwrap(response["results"]))
        XCTAssertEqual(results.compactMap { $0["id"] as? String }, ["msg_2"])

        let (sql, params) = SearchTool.buildQuery(
            query: nil,
            fromPerson: nil,
            inChat: nil,
            isGroup: nil,
            has: "link",
            since: nil,
            before: nil,
            cursor: nil,
            limit: 10,
            sort: .recentFirst,
            unanswered: false
        )
        XCTAssertTrue(sql.contains("m.text LIKE ? ESCAPE '\\'"), "link LIKE missing ESCAPE: \(sql)")
        XCTAssertEqual(params.last as? String, "%http%")
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

        guard let firstChat = chats.first else {
            return XCTFail("Expected grouped chats")
        }
        let sampleMessages = try decodeJSONArray(firstChat["results"])
        let firstSample = try XCTUnwrap(sampleMessages.first)
        XCTAssertEqual(firstSample["from"] as? String, "Bob Brown")
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

    func testFlatSearchAddsExcerptForLongMessages() async throws {
        let fixture = try makeSearchFixture()
        let resolver = makeSeededResolver()

        let response = try await decodeSearchResponse(
            SearchTool.execute(
                query: "appointment",
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
        let longResult = try XCTUnwrap(results.first(where: { $0["id"] as? String == "msg_350" }))
        let excerpt = try XCTUnwrap(longResult["excerpt"] as? String)
        XCTAssertTrue(excerpt.contains("appointment"))
        XCTAssertTrue(excerpt.count <= 166)
        let chat = try XCTUnwrap(longResult["chat"] as? [String: Any])
        XCTAssertEqual(chat["id"] as? String, "chat40")
    }

    func testIncludeContextQueryCountIsPerChatNotPerRow() async throws {
        let fixture = try ToolTestDatabase(name: "search-ctx-batch")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 1, guid: "chat-one-guid", displayName: "Chat One")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)
        try fixture.insertChat(rowId: 2, guid: "chat-two-guid", displayName: "Chat Two")
        try fixture.joinChatHandle(chatId: 2, handleId: 1)

        for index in 1...10 {
            try fixture.insertMessage(
                rowId: index,
                guid: "g\(index)",
                text: "batchctx \(index)",
                date: Int64(index) * 1_000,
                isFromMe: false,
                handleId: 1
            )
            try fixture.joinChatMessage(chatId: 1, messageId: index)
        }
        for index in 11...20 {
            try fixture.insertMessage(
                rowId: index,
                guid: "g\(index)",
                text: "batchctx \(index)",
                date: Int64(index) * 1_000,
                isFromMe: false,
                handleId: 1
            )
            try fixture.joinChatMessage(chatId: 2, messageId: index)
        }

        Database.queryCountForTesting = 0
        defer { Database.queryCountForTesting = nil }

        let response = try await decodeSearchResponse(
            SearchTool.execute(
                query: "batchctx",
                cursor: nil,
                limit: 20,
                sort: "recent_first",
                format: "flat",
                includeContext: true,
                unanswered: false,
                unansweredHours: 24,
                matchAll: false,
                fuzzy: false,
                db: fixture.database(),
                resolver: makeSeededResolver()
            )
        )
        let results = try decodeJSONArray(try XCTUnwrap(response["results"]))
        XCTAssertEqual(results.count, 20)
        let queryCount = try XCTUnwrap(Database.queryCountForTesting)
        XCTAssertLessThanOrEqual(queryCount, 5, "include_context ran \(queryCount) queries")
    }

    func testIncludeContextWindowsArePerAnchorAndExact() async throws {
        let fixture = try ToolTestDatabase(name: "search-ctx-windows")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 1, guid: "chat-window-guid", displayName: "Windows")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)

        let base: Int64 = 1_000_000_000_000
        let minute: Int64 = 60_000_000_000
        let anchorIndexes = Set([5, 15, 25])

        for index in 0..<30 {
            let text = anchorIndexes.contains(index) ? "anchorword \(index)" : "filler \(index)"
            try fixture.insertMessage(
                rowId: index + 1,
                guid: "g\(index)",
                text: text,
                date: base + Int64(index) * minute,
                isFromMe: false,
                handleId: 1
            )
            try fixture.joinChatMessage(chatId: 1, messageId: index + 1)
        }

        try fixture.insertMessage(
            rowId: 31,
            guid: "g-reaction",
            text: "loved",
            date: base + 6 * minute,
            isFromMe: false,
            handleId: 1,
            associatedMessageType: 2000
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 31)

        try fixture.insertMessage(
            rowId: 32,
            guid: "g-twin",
            text: "twin 15",
            date: base + 15 * minute,
            isFromMe: false,
            handleId: 1
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 32)

        let response = try await decodeSearchResponse(
            SearchTool.execute(
                query: "anchorword",
                cursor: nil,
                limit: 20,
                sort: "recent_first",
                format: "flat",
                includeContext: true,
                unanswered: false,
                unansweredHours: 24,
                matchAll: false,
                fuzzy: false,
                db: fixture.database(),
                resolver: makeSeededResolver()
            )
        )
        let results = try decodeJSONArray(try XCTUnwrap(response["results"]))
        XCTAssertEqual(results.count, 3)

        for index in [5, 15, 25] {
            let result = try XCTUnwrap(
                results.first(where: { ($0["excerpt"] as? String) == "anchorword \(index)" })
            )
            let before = try decodeJSONArray(result["context_before"]).compactMap { $0["text"] as? String }
            let after = try decodeJSONArray(result["context_after"]).compactMap { $0["text"] as? String }
            XCTAssertEqual(before, ["filler \(index - 2)", "filler \(index - 1)"])
            XCTAssertEqual(after, ["filler \(index + 1)", "filler \(index + 2)"])
            XCTAssertFalse(before.contains("loved") || after.contains("loved"))
            XCTAssertFalse(before.contains("twin 15") || after.contains("twin 15"))
        }
    }

    func testUnansweredSkipsReplyWindowQueriesForNonQuestions() async throws {
        let fixture = try ToolTestDatabase(name: "search-unanswered-count")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 1, guid: "chat-status-guid", displayName: "Status")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)
        for index in 1...50 {
            try fixture.insertMessage(
                rowId: index,
                guid: "g\(index)",
                text: "status update \(index)",
                date: Int64(index) * 1_000,
                isFromMe: true,
                handleId: 1
            )
            try fixture.joinChatMessage(chatId: 1, messageId: index)
        }

        Database.queryCountForTesting = 0
        let baseline = try await decodeSearchResponse(
            SearchTool.execute(
                query: "status",
                cursor: nil,
                limit: 50,
                sort: "recent_first",
                format: "flat",
                includeContext: false,
                unanswered: false,
                unansweredHours: 24,
                matchAll: false,
                fuzzy: false,
                db: fixture.database(),
                resolver: makeSeededResolver()
            )
        )
        let baseCount = try XCTUnwrap(Database.queryCountForTesting)
        XCTAssertEqual(try decodeJSONArray(try XCTUnwrap(baseline["results"])).count, 50)

        Database.queryCountForTesting = 0
        defer { Database.queryCountForTesting = nil }

        let unanswered = try await decodeSearchResponse(
            SearchTool.execute(
                cursor: nil,
                limit: 50,
                sort: "recent_first",
                format: "flat",
                includeContext: false,
                unanswered: true,
                unansweredHours: 24,
                matchAll: false,
                fuzzy: false,
                db: fixture.database(),
                resolver: makeSeededResolver()
            )
        )
        XCTAssertEqual(try decodeJSONArray(try XCTUnwrap(unanswered["results"])).count, 0)
        let unansweredCount = try XCTUnwrap(Database.queryCountForTesting)
        XCTAssertLessThanOrEqual(
            unansweredCount,
            baseCount,
            "unanswered over 50 non-questions ran \(unansweredCount) queries vs base \(baseCount)"
        )
    }

    func testGroupedSearchUsesConstantQueriesAcrossUnnamedChats() async throws {
        let fixture = try ToolTestDatabase(name: "search-grouped-batchname")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertHandle(rowId: 2, handle: "+15550000002")
        for chatId in 1...8 {
            try fixture.insertChat(rowId: chatId, guid: "chat-\(chatId)-guid", displayName: nil)
            try fixture.joinChatHandle(chatId: chatId, handleId: 1)
            try fixture.joinChatHandle(chatId: chatId, handleId: 2)
            try fixture.insertMessage(
                rowId: chatId,
                guid: "msg-\(chatId)",
                text: "batchname \(chatId)",
                date: Int64(chatId) * 1_000_000_000,
                isFromMe: false,
                handleId: 1
            )
            try fixture.joinChatMessage(chatId: chatId, messageId: chatId)
        }

        Database.queryCountForTesting = 0
        defer { Database.queryCountForTesting = nil }

        let response = try await decodeSearchResponse(
            SearchTool.execute(
                query: "batchname",
                cursor: nil,
                limit: 20,
                sort: "recent_first",
                format: "grouped_by_chat",
                includeContext: false,
                unanswered: false,
                unansweredHours: 24,
                matchAll: false,
                fuzzy: false,
                db: fixture.database(),
                resolver: makeSeededResolver()
            )
        )
        let chats = try decodeJSONArray(try XCTUnwrap(response["chats"]))
        XCTAssertEqual(chats.count, 8)
        for chat in chats {
            let name = try XCTUnwrap(chat["name"] as? String)
            XCTAssertFalse(name.isEmpty)
            XCTAssertNotEqual(name, "Unknown Chat")
        }
        let queryCount = try XCTUnwrap(Database.queryCountForTesting)
        // 3 queries: search rows, participantsByChat, plus 074's
        // filtered_hidden count. recentSendersByChat is skipped because
        // every chat is unnamed.
        XCTAssertLessThanOrEqual(queryCount, 3, "grouped search ran \(queryCount) queries")
    }

    /// Unnamed 6-handle chat. Recency is handles 6, 5, 4; prioritized is
    /// Alice, Bob, Chris. Generated names must not become explicitName.
    func testGroupedSearchUnnamedChatIsNotNamed() async throws {
        let fixture = try ToolTestDatabase(name: "search-grouped-unnamed-large")
        for rowId in 1...6 {
            try fixture.insertHandle(rowId: rowId, handle: "+1555000000\(rowId)")
        }
        try fixture.insertChat(rowId: 10, guid: "chat-10-guid", displayName: nil)
        for rowId in 1...6 {
            try fixture.joinChatHandle(chatId: 10, handleId: rowId)
        }

        let base: Int64 = 700_000_000_000_000_000
        let sec: Int64 = 1_000_000_000
        let recency: [(Int, Int, Int64)] = [
            (201, 6, base + (3 * sec)),
            (202, 5, base + (2 * sec)),
            (203, 4, base + sec),
        ]
        for (rowId, handleId, date) in recency {
            try fixture.insertMessage(
                rowId: rowId,
                guid: "msg-\(rowId)",
                text: "unnamedpreview \(rowId)",
                date: date,
                isFromMe: false,
                handleId: handleId
            )
            try fixture.joinChatMessage(chatId: 10, messageId: rowId)
        }

        let response = try await decodeSearchResponse(
            SearchTool.execute(
                query: "unnamedpreview",
                cursor: nil,
                limit: 20,
                sort: "recent_first",
                format: "grouped_by_chat",
                includeContext: false,
                unanswered: false,
                unansweredHours: 24,
                matchAll: false,
                fuzzy: false,
                db: fixture.database(),
                resolver: makeSeededResolver()
            )
        )
        let chats = try decodeJSONArray(try XCTUnwrap(response["chats"]))
        XCTAssertEqual(chats.count, 1)
        let preview = try XCTUnwrap(chats.first?["participants_preview"] as? [String])
        XCTAssertEqual(
            preview,
            ["Alice Smith", "Bob Brown", "Chris Green", "+3 more"]
        )
    }

    func testIsGroupFilterMatchesCountSemantics() async throws {
        let fixture = try ToolTestDatabase(name: "search-is-group")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertHandle(rowId: 2, handle: "+15550000002")

        try fixture.insertChat(rowId: 1, guid: "chat-zero-guid", displayName: "Zero")
        try fixture.insertMessage(
            rowId: 1,
            guid: "g-zero",
            text: "grpword zero",
            date: 1_000,
            isFromMe: false,
            handleId: 1
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 1)

        try fixture.insertChat(rowId: 2, guid: "chat-one-guid", displayName: "One")
        try fixture.joinChatHandle(chatId: 2, handleId: 1)
        try fixture.insertMessage(
            rowId: 2,
            guid: "g-one",
            text: "grpword one",
            date: 2_000,
            isFromMe: false,
            handleId: 1
        )
        try fixture.joinChatMessage(chatId: 2, messageId: 2)

        try fixture.insertChat(rowId: 3, guid: "chat-two-guid", displayName: "Two")
        try fixture.joinChatHandle(chatId: 3, handleId: 1)
        try fixture.joinChatHandle(chatId: 3, handleId: 2)
        try fixture.insertMessage(
            rowId: 3,
            guid: "g-two",
            text: "grpword two",
            date: 3_000,
            isFromMe: false,
            handleId: 1
        )
        try fixture.joinChatMessage(chatId: 3, messageId: 3)

        func ids(_ isGroup: Bool?) async throws -> Set<String> {
            let response = try await decodeSearchResponse(
                SearchTool.execute(
                    query: "grpword",
                    isGroup: isGroup,
                    cursor: nil,
                    limit: 20,
                    sort: "recent_first",
                    format: "flat",
                    includeContext: false,
                    unanswered: false,
                    unansweredHours: 24,
                    matchAll: false,
                    fuzzy: false,
                    db: fixture.database(),
                    resolver: makeSeededResolver()
                )
            )
            return Set(try decodeJSONArray(try XCTUnwrap(response["results"])).compactMap { $0["id"] as? String })
        }

        let groups = try await ids(true)
        let directs = try await ids(false)
        let all = try await ids(nil)
        XCTAssertEqual(groups, Set(["msg_3"]))
        XCTAssertEqual(directs, Set(["msg_2"]))
        XCTAssertEqual(all, Set(["msg_1", "msg_2", "msg_3"]))
    }

    func testSearchResultsCarryReactionReplyAndEditFields() async throws {
        let fixture = try makeSearchFixture()
        let resolver = makeSeededResolver()

        let response = try await decodeSearchResponse(
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
        let results = try decodeJSONArray(try XCTUnwrap(response["results"]))
        let byId = Dictionary(uniqueKeysWithValues: results.compactMap { row -> (String, [String: Any])? in
            guard let id = row["id"] as? String else { return nil }
            return (id, row)
        })

        let reacted = try XCTUnwrap(byId["msg_200"])
        XCTAssertEqual(reacted["reactions"] as? [String], ["🥕 Alice Smith"])
        XCTAssertEqual(reacted["reply_count"] as? Int, 1)
        XCTAssertFalse(reacted.keys.contains("reply_to"))
        XCTAssertFalse(reacted.keys.contains("edited"))

        let reply = try XCTUnwrap(byId["msg_250"])
        XCTAssertEqual(reply["reply_to"] as? String, "msg_200")
        XCTAssertFalse(reply.keys.contains("reactions"))
        XCTAssertFalse(reply.keys.contains("reply_count"))
        XCTAssertFalse(reply.keys.contains("edited"))

        let edited = try XCTUnwrap(byId["msg_300"])
        XCTAssertEqual(edited["edited"] as? Bool, true)
        XCTAssertFalse(edited.keys.contains("reactions"))
        XCTAssertFalse(edited.keys.contains("reply_to"))
        XCTAssertFalse(edited.keys.contains("reply_count"))
    }

    func testMissingReplyAndEditColumnsDegradeSearch() async throws {
        let fixture = try makeSearchFixture()
        try fixture.execute("ALTER TABLE message DROP COLUMN thread_originator_guid")
        try fixture.execute("ALTER TABLE message DROP COLUMN date_edited")
        try fixture.execute("ALTER TABLE message DROP COLUMN associated_message_emoji")
        let result = await SearchTool.execute(
            query: "costa trip",
            cursor: nil,
            limit: 10,
            sort: "recent_first",
            format: "flat",
            includeContext: true,
            unanswered: false,
            unansweredHours: 24,
            matchAll: false,
            fuzzy: false,
            db: fixture.database(),
            resolver: makeSeededResolver()
        )
        let json: String
        switch result {
        case .success(let text):
            json = text
        case .failure(let error):
            XCTFail("Unexpected search error: \(error)")
            return
        }
        let decoded = try decodeJSONDictionary(from: json)
        let results = try decodeJSONArray(decoded["results"])
        XCTAssertEqual(Set(results.compactMap { $0["id"] as? String }), Set(["msg_200", "msg_250", "msg_300"]))
        XCTAssertFalse(json.contains("\"reply_to\""))
        XCTAssertFalse(json.contains("\"edited\""))
    }
}

func decodeSearchResponse(_ result: Result<String, SearchError>) throws -> [String: Any] {
    switch result {
    case .success(let json):
        return try decodeJSONDictionary(from: json)
    case .failure(let error):
        XCTFail("Unexpected search error: \(error)")
        return [:]
    }
}

func makeSearchFixture() throws -> ToolTestDatabase {
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

    try fixture.insertChat(rowId: 40, guid: "chat-chris-guid", displayName: "Appointments")
    try fixture.joinChatHandle(chatId: 40, handleId: 3)

    try fixture.insertMessage(rowId: 100, guid: "g100", text: "project alpha kickoff", date: 1_000_000_000, isFromMe: false, handleId: 1)
    try fixture.joinChatMessage(chatId: 10, messageId: 100)

    try fixture.insertMessage(rowId: 101, guid: "g101", text: "can you review the alpha plan?", date: 2_000_000_000, isFromMe: true)
    try fixture.joinChatMessage(chatId: 10, messageId: 101)

    try fixture.insertMessage(rowId: 102, guid: "g102", text: "yes I will review it", date: 3_000_000_000, isFromMe: false, handleId: 1)
    try fixture.joinChatMessage(chatId: 10, messageId: 102)

    try fixture.insertMessage(rowId: 200, guid: "g200", text: "trip to costa rica volcano", date: 4_000_000_000, isFromMe: false, handleId: 2)
    try fixture.joinChatMessage(chatId: 20, messageId: 200)
    try fixture.insertMessage(
        rowId: 401,
        guid: "search-reaction-carrot",
        text: nil,
        date: 4_000_000_001,
        isFromMe: false,
        handleId: 1,
        associatedMessageType: 2006,
        associatedMessageGuid: "p:0/g200",
        associatedMessageEmoji: "🥕"
    )
    try fixture.joinChatMessage(chatId: 20, messageId: 401)

    try fixture.insertMessage(rowId: 201, guid: "g201", text: "see the volcano photos http://example.com", date: 5_000_000_000, isFromMe: true)
    try fixture.joinChatMessage(chatId: 20, messageId: 201)

    try fixture.insertMessage(rowId: 202, guid: "g202", text: "packing list", date: 6_000_000_000, isFromMe: false, handleId: 1)
    try fixture.joinChatMessage(chatId: 20, messageId: 202)

    try fixture.insertMessage(rowId: 250, guid: "g250", text: "trip planning notes", date: 6_500_000_000, isFromMe: false, handleId: 2, threadOriginatorGuid: "g200")
    try fixture.joinChatMessage(chatId: 30, messageId: 250)

    try fixture.insertMessage(rowId: 300, guid: "g300", text: "let me know about the trip?", date: 7_000_000_000, isFromMe: true, dateEdited: 7_000_000_001)
    try fixture.joinChatMessage(chatId: 30, messageId: 300)

    try fixture.insertMessage(
        rowId: 350,
        guid: "g350",
        text: "This appointment reminder includes a lot of extra context about logistics, parking, timing, follow-up details, preparation steps, and confirmation notes so that the message is deliberately long enough to require an excerpt in flat search results.",
        date: 8_000_000_000,
        isFromMe: false,
        handleId: 3
    )
    try fixture.joinChatMessage(chatId: 40, messageId: 350)

    return fixture
}
