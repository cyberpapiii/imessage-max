import MCP
import XCTest
@testable import iMessageMax

final class SearchToolTests: XCTestCase {
    func testAnyWordVsMatchAll() async throws {
        let fixture = try makeSearchFixture()
        let resolver = makeSeededResolver()

        let anyWord = try await decodeJSONDictionary(from:
            SearchTool.execute(
                query: "costa trip",
                limit: 10,
                db: fixture.database(),
                resolver: resolver
            )
        )
        let anyResults = try decodeJSONArray(try XCTUnwrap(anyWord["results"]))
        XCTAssertEqual(Set(anyResults.compactMap { $0["id"] as? String }), Set(["msg_200", "msg_250", "msg_300"]))

        let allWords = try await decodeJSONDictionary(from:
            SearchTool.execute(
                query: "costa trip",
                limit: 10,
                matchAll: true,
                db: fixture.database(),
                resolver: resolver
            )
        )
        let allResults = try decodeJSONArray(try XCTUnwrap(allWords["results"]))
        XCTAssertEqual(allResults.count, 1)
        XCTAssertEqual(allResults.first?["id"] as? String, "msg_200")
    }

    func testFilteredChatsAreHiddenByDefault() async throws {
        let fixture = try filteredChatsFixture()

        let hidden = try await decodeJSONDictionary(from:
            SearchTool.execute(
                query: "zebra",
                limit: 10,
                db: fixture.database(),
                resolver: ContactResolver(seedCache: [:])
            )
        )
        let hiddenResults = try decodeJSONArray(try XCTUnwrap(hidden["results"]))
        XCTAssertEqual(hiddenResults.compactMap { $0["id"] as? String }, ["msg_1"])
        XCTAssertEqual(hidden["filtered_hidden"] as? Int, 2)

        let shown = try await decodeJSONDictionary(from:
            SearchTool.execute(
                query: "zebra",
                limit: 10,
                includeFiltered: true,
                db: fixture.database(),
                resolver: ContactResolver(seedCache: [:])
            )
        )
        let shownResults = try decodeJSONArray(try XCTUnwrap(shown["results"]))
        XCTAssertEqual(Set(shownResults.compactMap { $0["id"] as? String }), Set(["msg_1", "msg_2", "msg_3"]))
        XCTAssertNil(shown["filtered_hidden"])
    }

    /// The hidden-chat count runs on every unfiltered search. Driven from
    /// `message` it is a second scan of the whole table (150-316 ms of a
    /// 300-380 ms search on a real chat.db); driven from the few filtered chats
    /// it only visits their messages.
    func testFilteredHiddenCountIsDrivenFromFilteredChats() throws {
        let fixture = try ToolTestDatabase(name: "search-filtered-plan")
        try fixture.execute("""
            CREATE UNIQUE INDEX cmj_pk ON chat_message_join(chat_id, message_id);
            CREATE INDEX cmj_message ON chat_message_join(message_id);
            CREATE INDEX message_date ON message(date);
            """)
        let (sql, params) = SearchTool.filteredHiddenQuery(
            query: "zebra",
            fromPerson: nil,
            inChat: nil,
            isGroup: nil,
            has: nil,
            since: nil,
            before: nil,
            unanswered: false,
            terms: ["zebra"],
            matchAll: false,
            fuzzy: false
        )
        let plan = try fixture.database().query("EXPLAIN QUERY PLAN " + sql, params: params) { row in
            row.string(3) ?? ""
        }
        let loops = plan.filter { $0.hasPrefix("SCAN") || $0.hasPrefix("SEARCH") }
        XCTAssertTrue(loops.first?.hasPrefix("SCAN c") ?? false, "plan: \(plan)")
        XCTAssertTrue(
            loops.contains { $0.hasPrefix("SEARCH m USING INTEGER PRIMARY KEY") },
            "plan: \(plan)"
        )
    }

    func testFuzzySearchMatchesTyposAndIncludesContext() async throws {
        let fixture = try makeSearchFixture()
        let resolver = makeSeededResolver()

        let response = try await decodeJSONDictionary(from:
            SearchTool.execute(
                query: "volcno",
                limit: 10,
                includeContext: true,
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

        let response = try await decodeJSONDictionary(from:
            SearchTool.execute(
                inChat: "chat20",
                has: "link",
                limit: 10,
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

        let response = try await decodeJSONDictionary(from:
            SearchTool.execute(
                has: "link",
                limit: 10,
                db: fixture.database(),
                resolver: makeSeededResolver()
            )
        )
        let results = try decodeJSONArray(try XCTUnwrap(response["results"]))
        XCTAssertEqual(results.compactMap { $0["id"] as? String }, ["msg_2"])
    }

    func testHasLinkNeedsAURLNotTheWordHttp() async throws {
        let fixture = try ToolTestDatabase(name: "search-link-word")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 1, guid: "chat-link-word", displayName: "Links")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)
        try fixture.insertMessage(rowId: 1, guid: "g1", text: "the http spec", date: 1_000, isFromMe: false, handleId: 1)
        try fixture.joinChatMessage(chatId: 1, messageId: 1)
        try fixture.insertMessage(rowId: 2, guid: "g2", text: "https://example.com", date: 2_000, isFromMe: false, handleId: 1)
        try fixture.joinChatMessage(chatId: 1, messageId: 2)

        let response = try await decodeJSONDictionary(from:
            SearchTool.execute(has: "link", db: fixture.database(), resolver: makeSeededResolver())
        )
        let results = try decodeJSONArray(try XCTUnwrap(response["results"]))
        XCTAssertEqual(results.compactMap { $0["id"] as? String }, ["msg_2"])
    }

    func testFromPersonGroupedResponseUsesStablePeopleKeysAndGeneratedChatNames() async throws {
        let fixture = try makeSearchFixture()
        let resolver = makeSeededResolver()

        let response = try await decodeJSONDictionary(from:
            SearchTool.execute(
                fromPerson: "Bob",
                limit: 10,
                format: "grouped_by_chat",
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

    func testGroupedChatsWithEqualMatchCountsListTheMostRecentFirst() async throws {
        let fixture = try ToolTestDatabase(name: "search-grouped-ties")
        let base = AppleTime.fromDate(Date().addingTimeInterval(-3600))
        for chat in 1...3 {
            try fixture.insertHandle(rowId: chat, handle: "+1555000000\(chat)")
            try fixture.insertChat(rowId: chat, guid: "iMessage;-;\(chat)")
            try fixture.joinChatHandle(chatId: chat, handleId: chat)
            try fixture.insertMessage(rowId: chat, guid: "m\(chat)", text: "hello \(chat)",
                                      date: base + Int64([2, 3, 1][chat - 1]) * 60_000_000_000,
                                      isFromMe: false, handleId: chat)
            try fixture.joinChatMessage(chatId: chat, messageId: chat)
        }

        let response = try await decodeJSONDictionary(from:
            SearchTool.execute(
                query: "hello",
                limit: 10,
                format: "grouped_by_chat",
                db: fixture.database(),
                resolver: makeSeededResolver()
            )
        )

        let ids = try decodeJSONArray(response["chats"]).compactMap { $0["id"] as? String }
        XCTAssertEqual(ids, ["chat2", "chat1", "chat3"])
    }

    func testUnansweredSearchReturnsOnlyMessagesWithoutReplies() async throws {
        let fixture = try makeSearchFixture()
        let resolver = makeSeededResolver()

        let response = try await decodeJSONDictionary(from:
            SearchTool.execute(
                limit: 10,
                unanswered: true,
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

        let pageOne = try await decodeJSONDictionary(from:
            SearchTool.execute(
                fromPerson: "Bob",
                limit: 1,
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

        let pageTwo = try await decodeJSONDictionary(from:
            SearchTool.execute(
                fromPerson: "Bob",
                cursor: cursor,
                limit: 1,
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

        let response = try await decodeJSONDictionary(from:
            SearchTool.execute(
                query: "appointment",
                limit: 10,
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

    /// Context windows are fetched once per chat, not once per hit.
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

        func queries(limit: Int) async throws -> Int {
            try await countQueries {
                let response = try await decodeJSONDictionary(from:
                    SearchTool.execute(
                        query: "batchctx",
                        limit: limit,
                        includeContext: true,
                        db: fixture.database(),
                        resolver: makeSeededResolver()
                    )
                )
                let results = try decodeJSONArray(try XCTUnwrap(response["results"]))
                XCTAssertEqual(results.count, limit)
            }
        }
        // Both pages span both chats: 12 newest hits reach back into chat 1.
        let twelve = try await queries(limit: 12)
        let twenty = try await queries(limit: 20)
        XCTAssertGreaterThan(twelve, 0)
        XCTAssertEqual(twenty, twelve, "20 hits ran \(twenty) queries, 12 ran \(twelve)")
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

        let response = try await decodeJSONDictionary(from:
            SearchTool.execute(
                query: "anchorword",
                includeContext: true,
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
            // The twin shares anchor 15's timestamp with a higher ROWID, so it comes right after it.
            let expectedAfter = index == 15 ? ["twin 15", "filler 16"] : ["filler \(index + 1)", "filler \(index + 2)"]
            XCTAssertEqual(after, expectedAfter)
            XCTAssertFalse(before.contains("loved") || after.contains("loved"))
        }
    }

    func testIncludeContextGivesHitsSharingATimestampTheirOwnWindows() async throws {
        let fixture = try ToolTestDatabase(name: "search-ctx-same-timestamp")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 1, guid: "chat-twin-guid", displayName: "Twins")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)
        let rows: [(id: Int, date: Int64, text: String)] = [
            (1, 100, "filler 1"), (2, 200, "hit a"), (3, 200, "hit b"), (4, 300, "filler 4"),
        ]
        for row in rows {
            try fixture.insertMessage(rowId: row.id, guid: "g\(row.id)", text: row.text, date: row.date, isFromMe: false, handleId: 1)
            try fixture.joinChatMessage(chatId: 1, messageId: row.id)
        }

        let response = try await decodeJSONDictionary(from:
            SearchTool.execute(query: "hit", includeContext: true, db: fixture.database(), resolver: makeSeededResolver())
        )
        let results = try decodeJSONArray(try XCTUnwrap(response["results"]))
        func window(_ id: String, _ side: String) throws -> [String] {
            let result = try XCTUnwrap(results.first { $0["id"] as? String == id })
            return try decodeJSONArray(result[side]).compactMap { $0["id"] as? String }
        }
        XCTAssertEqual(try window("msg_2", "context_before"), ["msg_1"])
        XCTAssertEqual(try window("msg_2", "context_after"), ["msg_3", "msg_4"])
        XCTAssertEqual(try window("msg_3", "context_before"), ["msg_1", "msg_2"])
        XCTAssertEqual(try window("msg_3", "context_after"), ["msg_4"])
    }

    /// Unnamed chats get generated names in grouped results, from batched
    /// queries rather than one lookup per chat.
    func testGroupedSearchNamesUnnamedChatsWithoutPerChatQueries() async throws {
        func run(chatCount: Int) async throws -> (queries: Int, chats: [[String: Any]]) {
            let fixture = try ToolTestDatabase(name: "search-grouped-batchname")
            try fixture.insertHandle(rowId: 1, handle: "+15550000001")
            try fixture.insertHandle(rowId: 2, handle: "+15550000002")
            for chatId in 1...chatCount {
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
            var chats: [[String: Any]] = []
            let queries = try await countQueries {
                let response = try await decodeJSONDictionary(from:
                    SearchTool.execute(
                        query: "batchname",
                        format: "grouped_by_chat",
                        db: fixture.database(),
                        resolver: makeSeededResolver()
                    )
                )
                chats = try decodeJSONArray(try XCTUnwrap(response["chats"]))
            }
            return (queries, chats)
        }

        let two = try await run(chatCount: 2)
        let eight = try await run(chatCount: 8)
        XCTAssertEqual(eight.chats.count, 8)
        for chat in eight.chats {
            XCTAssertEqual(chat["name"] as? String, "Alice Smith, Bob Brown")
        }
        XCTAssertGreaterThan(two.queries, 0)
        XCTAssertEqual(eight.queries, two.queries, "8 chats ran \(eight.queries) queries, 2 ran \(two.queries)")
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

        let response = try await decodeJSONDictionary(from:
            SearchTool.execute(
                query: "unnamedpreview",
                format: "grouped_by_chat",
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
            let response = try await decodeJSONDictionary(from:
                SearchTool.execute(
                    query: "grpword",
                    isGroup: isGroup,
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
        // A chat with no handles left is a DM, as in every other tool.
        XCTAssertEqual(directs, Set(["msg_1", "msg_2"]))
        XCTAssertEqual(all, Set(["msg_1", "msg_2", "msg_3"]))
    }

    func testSearchResultsCarryReactionReplyAndEditFields() async throws {
        let fixture = try makeSearchFixture()
        let resolver = makeSeededResolver()

        let response = try await decodeJSONDictionary(from:
            SearchTool.execute(
                query: "costa trip",
                limit: 10,
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
        let result = try await SearchTool.execute(
            query: "costa trip",
            limit: 10,
            includeContext: true,
            db: fixture.database(),
            resolver: makeSeededResolver()
        )
        let json = result
        let decoded = try decodeJSONDictionary(from: json)
        let results = try decodeJSONArray(decoded["results"])
        XCTAssertEqual(Set(results.compactMap { $0["id"] as? String }), Set(["msg_200", "msg_250", "msg_300"]))
        XCTAssertFalse(json.contains("\"reply_to\""))
        XCTAssertFalse(json.contains("\"edited\""))
    }

    // MARK: - Paging, hidden chats and short queries

    /// The blob holds the class name "NSString", so every attributedBody
    /// row passes the SQL prefilter for "string" and is then dropped in
    /// Swift. Paging still reaches the one real match, fuzzy or not.
    func testReachesAMatchBehindAFullFetchOfPrefilterFalsePositives() async throws {
        let fixture = try directChatFixture(name: "search-paging")
        let base = AppleTime.fromDate(Date()) - 1_000 * appleMinute
        try fixture.insertMessage(rowId: 1, guid: "M1", text: "tie the string here", date: base, isFromMe: false, handleId: 1)
        try fixture.joinChatMessage(chatId: 1, messageId: 1)
        try fixture.execute("BEGIN")
        for row in 2...601 {
            try fixture.insertMessage(
                rowId: row, guid: "M\(row)", date: base + Int64(row) * appleMinute, isFromMe: false, handleId: 1,
                attributedBody: typedstreamBlob(payload: Array("filler \(row)".utf8))
            )
            try fixture.joinChatMessage(chatId: 1, messageId: row)
        }
        try fixture.execute("COMMIT")

        for args: [String: Value] in [["query": "string", "limit": 1], ["query": "strng", "fuzzy": true, "limit": 1]] {
            let found = try await collectPages("search", args, resultsKey: "results", database: fixture.database())
            XCTAssertEqual(found.ids, ["msg_1"], "\(args)")
            XCTAssertGreaterThan(found.pages, 1)
        }
    }

    /// filtered_hidden counts hidden chats with a real match, under every
    /// search mode, not hidden chats in general.
    func testFilteredHiddenCountsOnlyHiddenChatsWithARealMatch() async throws {
        let fixture = try hiddenMatchesFixture()
        for args: [String: Value] in [
            ["query": "volcano"],
            ["query": "volcno", "fuzzy": true],
            ["query": "volcano", "format": "grouped_by_chat"],
            ["unanswered": true],
        ] {
            let page = try await callTool("search", args, database: fixture.database())
            XCTAssertEqual(page["filtered_hidden"] as? Int, 1, "\(args)")
        }
    }

    func testFilteredHiddenIsCountedOnTheFirstPageOnly() async throws {
        let fixture = try directChatFixture(name: "search-hidden-pages")
        try fixture.insertChat(rowId: 2, guid: "SMS;-;spam", isFiltered: 1)
        let base: Int64 = 700_000_000_000_000_000
        for row in 1...3 {
            try fixture.insertMessage(rowId: row, guid: "g\(row)", text: "hello \(row)", date: base + Int64(row), isFromMe: false, handleId: 1)
            try fixture.joinChatMessage(chatId: 1, messageId: row)
        }
        try fixture.insertMessage(rowId: 4, guid: "g4", text: "hello spam", date: base, isFromMe: false, handleId: 1)
        try fixture.joinChatMessage(chatId: 2, messageId: 4)

        let first = try await callTool("search", ["query": "hello", "limit": 1], database: fixture.database())
        XCTAssertEqual(first["filtered_hidden"] as? Int, 1)
        let cursor = try XCTUnwrap(first["cursor"] as? String)
        let second = try await callTool("search", ["query": "hello", "limit": 1, "cursor": .string(cursor)], database: fixture.database())
        XCTAssertEqual(try itemIds(second, "results"), ["msg_2"])
        XCTAssertNil(second["filtered_hidden"])
    }

    func testQueryOfOnlySingleCharactersMatchesAsASubstring() async throws {
        let fixture = try directChatFixture(name: "short-query")
        for (index, text) in ["我的猫很可爱", "a dog", "nothing here", "b c d"].enumerated() {
            try fixture.insertMessage(rowId: index + 1, guid: "g\(index)", text: text, date: 700_000_000_000_000_000 + Int64(index), isFromMe: false, handleId: 1)
            try fixture.joinChatMessage(chatId: 1, messageId: index + 1)
        }
        for (query, expected) in [("猫", "msg_1"), (" A ", "msg_2"), ("c d", "msg_4")] {
            let found = try await callTool("search", ["query": .string(query)], database: fixture.database())
            XCTAssertEqual(try itemIds(found, "results"), [expected], query)
        }
    }

    /// `has` takes either tool's spelling ("image" or "images"), in search
    /// and in get_messages.
    func testHasAcceptsSingularAndPluralInSearchAndGetMessages() async throws {
        let fixture = try directChatFixture(name: "has-alias")
        let now = AppleTime.fromDate(Date())
        try fixture.insertMessage(rowId: 1, guid: "IMG", text: "\u{FFFC}", date: now - 2 * appleMinute, isFromMe: false, handleId: 1)
        try fixture.joinChatMessage(chatId: 1, messageId: 1)
        try fixture.insertAttachment(rowId: 1, filename: "~/x.jpeg", mimeType: "image/jpeg", uti: "public.jpeg", totalBytes: 1, transferName: "x.jpeg")
        try fixture.joinMessageAttachment(messageId: 1, attachmentId: 1)
        try fixture.insertMessage(rowId: 2, guid: "TXT", text: "plain", date: now - appleMinute, isFromMe: false, handleId: 1)
        try fixture.joinChatMessage(chatId: 1, messageId: 2)

        for has in ["image", "images"] {
            let search = try await callTool("search", ["has": .string(has)], database: fixture.database())
            XCTAssertEqual(try itemIds(search, "results"), ["msg_1"], has)
            let messages = try await callTool("get_messages", ["chat_id": "chat1", "has": .string(has)], database: fixture.database())
            XCTAssertEqual(try itemIds(messages, "messages"), ["msg_1"], has)
        }
    }

    // MARK: - Excerpts

    func testExcerptSurvivesTextWhoseLowercaseIsLonger() {
        let text = String(repeating: "İ", count: 300) + " needle " + String(repeating: "x", count: 300)
        let excerpt = SearchTool.makeExcerpt(text: text, query: "needle")
        XCTAssertTrue(excerpt.contains("needle"), excerpt)
    }

    func testExcerptCentresOnTheMatchPastEmoji() {
        let text = String(repeating: "👍", count: 200) + " needle " + String(repeating: "👍", count: 200)
        let excerpt = SearchTool.makeExcerpt(text: text, query: "NEEDLE")
        XCTAssertTrue(excerpt.contains("needle"), excerpt)
        XCTAssertTrue(excerpt.hasPrefix("..."))
        XCTAssertTrue(excerpt.hasSuffix("..."))
        XCTAssertFalse(excerpt.contains("\u{FFFD}"), "an emoji was split")
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
