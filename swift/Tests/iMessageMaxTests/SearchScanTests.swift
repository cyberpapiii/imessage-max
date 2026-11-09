import MCP
import XCTest
@testable import iMessageMax

/// 088 #37 and #38: how far one search call reads, how it says where it
/// stopped, and the case-insensitive attributedBody prefilter.
final class SearchScanTests: XCTestCase {
    /// One match, the oldest message, behind `fillers` newer rows that pass
    /// no Swift check. Text lives only in attributedBody, as on recent macOS.
    private func buriedMatchFixture(match: String, fillers: Int = 1_200) throws -> ToolTestDatabase {
        let fixture = try directChatFixture(name: "search-scan")
        try fixture.execute("BEGIN")
        try fixture.insertMessage(
            rowId: 1, guid: "M1", date: fixtureDay(0), isFromMe: false, handleId: 1,
            attributedBody: typedstreamBlob(payload: Array(match.utf8)))
        try fixture.joinChatMessage(chatId: 1, messageId: 1)
        for row in 2...(fillers + 1) {
            try fixture.insertMessage(
                rowId: row, guid: "M\(row)", date: fixtureDay(0) + Int64(row) * appleMinute, isFromMe: false, handleId: 1,
                attributedBody: typedstreamBlob(payload: Array("filler number \(row)".utf8)))
            try fixture.joinChatMessage(chatId: 1, messageId: row)
        }
        try fixture.execute("COMMIT")
        return fixture
    }

    private func search(_ fixture: ToolTestDatabase, _ arguments: [String: Value]) async throws -> [String: Any] {
        try await callTool("search", arguments, database: fixture.database())
    }

    func testFuzzySearchReadsPastTheFirstFetchInOneCall() async throws {
        let fixture = try buriedMatchFixture(match: "the volcano erupted")
        let page = try await search(fixture, ["query": "volcno", "fuzzy": true, "limit": 1])
        XCTAssertEqual(try itemIds(page, "results"), ["msg_1"])
        XCTAssertEqual(page["total"] as? Int, 1)
        XCTAssertNil(page["partial"])
        XCTAssertNil(page["searched_to"])
    }

    func testAnyWordSearchPastThePrefilterCapReadsPastTheFirstFetch() async throws {
        let fixture = try buriedMatchFixture(match: "the volcano erupted")
        let page = try await search(fixture, ["query": "aa bb cc dd ee ff gg hh volcano"])
        XCTAssertEqual(try itemIds(page, "results"), ["msg_1"])
        XCTAssertNil(page["partial"])
    }

    func testAScanWithNoMatchEndsWithoutACursor() async throws {
        let fixture = try buriedMatchFixture(match: "the volcano erupted")
        let page = try await search(fixture, ["query": "glacr", "fuzzy": true])
        XCTAssertEqual(try itemIds(page, "results"), [])
        XCTAssertEqual(page["more"] as? Bool, false)
        XCTAssertNil(page["cursor"])
        XCTAssertNil(page["partial"], "every message was checked")
    }

    /// Out of time, the answer says it is partial and where it stopped, and
    /// the cursor carries on from there until the match turns up.
    func testASearchOutOfTimeSaysWhereItStoppedAndResumes() async throws {
        let fixture = try buriedMatchFixture(match: "the volcano erupted")
        var cursor: String?
        var calls = 0
        var found: [String] = []
        repeat {
            let page = try await decodeJSONDictionary(from: SearchTool.execute(
                query: "volcno", cursor: cursor, limit: 1, fuzzy: true, scanBudget: .zero,
                db: fixture.database(), resolver: makeSeededResolver()))
            calls += 1
            found = try itemIds(page, "results")
            cursor = page["cursor"] as? String
            if found.isEmpty {
                XCTAssertEqual(page["partial"] as? Bool, true)
                XCTAssertEqual(page["more"] as? Bool, true)
                XCTAssertNotNil(cursor)
                XCTAssertEqual(page["total"] as? Int, 0)
                let searchedTo = try XCTUnwrap(page["searched_to"] as? String)
                if calls == 1 {
                    // 1,201 rows, 500 per fetch: the first stops at row 702.
                    XCTAssertEqual(searchedTo, TimeUtils.formatISO(AppleTime.toDate(fixtureDay(0) + 702 * appleMinute)))
                }
            }
        } while found.isEmpty && cursor != nil && calls < 10
        XCTAssertEqual(found, ["msg_1"])
        XCTAssertEqual(calls, 3)
    }

    func testGroupedResultsAlsoSayWhereTheyStopped() async throws {
        let fixture = try buriedMatchFixture(match: "the volcano erupted")
        let page = try await decodeJSONDictionary(from: SearchTool.execute(
            query: "volcno", format: "grouped_by_chat", fuzzy: true, scanBudget: .zero,
            db: fixture.database(), resolver: makeSeededResolver()))
        XCTAssertEqual(page["partial"] as? Bool, true)
        XCTAssertNotNil(page["searched_to"] as? String)
        XCTAssertNotNil(page["cursor"] as? String)
    }

    /// 088 #38: the blob prefilter tried only "iphone", "Iphone" and
    /// "IPHONE", so a row whose text lives in attributedBody as "iPhone"
    /// never reached the Swift check.
    func testMixedCaseWordsInAttributedBodyAreFound() async throws {
        let fixture = try directChatFixture(name: "search-case")
        for (row, text) in [(1, "my new iPhone is here"), (2, "lunch at McDonald's"), (3, "École starts monday")] {
            try fixture.insertMessage(
                rowId: row, guid: "C\(row)", date: fixtureDay(row), isFromMe: false, handleId: 1,
                attributedBody: typedstreamBlob(payload: Array(text.utf8)))
            try fixture.joinChatMessage(chatId: 1, messageId: row)
        }
        for (query, expected) in [
            ("iphone", "msg_1"), ("IPHONE", "msg_1"), ("Iphone", "msg_1"),
            ("mcdonald", "msg_2"), ("MCDONALD", "msg_2"),
            ("école", "msg_3"), ("ÉCOLE", "msg_3"),
        ] {
            let page = try await search(fixture, ["query": .string(query)])
            XCTAssertEqual(try itemIds(page, "results"), [expected], query)
        }
    }

    /// Each page past the first starts from a cursor. Paging within one call
    /// only helps if that page walks the date index from the cursor rather
    /// than sorting every older message.
    func testACursorPageWalksTheDateIndex() throws {
        let fixture = try buriedMatchFixture(match: "the volcano erupted", fillers: 2_000)
        try fixture.execute("""
            CREATE INDEX message_idx_date ON message(date);
            CREATE INDEX chat_message_join_idx_message_id_only ON chat_message_join(message_id);
            ANALYZE;
            """)
        let db = fixture.database()
        let (sql, params) = SearchTool.buildQuery(
            query: "volcno", fromPerson: nil, inChat: nil, isGroup: nil, has: nil, since: nil, before: nil,
            cursor: TimelineCursor(date: fixtureDay(0) + 1_500 * appleMinute, messageId: 1_500),
            limit: 500, sort: .recentFirst, unanswered: false, terms: ["volcno"], fuzzy: true,
            schema: try db.schema())
        let plan = try db.query("EXPLAIN QUERY PLAN " + sql, params: params) { $0.string(3) ?? "" }
        XCTAssertTrue(plan.contains { $0.contains("USING INDEX message_idx_date (date<?)") }, "\(plan)")
        XCTAssertFalse(plan.contains { $0.contains("MULTI-INDEX OR") }, "\(plan)")
        let rows = try db.query(sql, params: params, map: MessageInChat.init)
        XCTAssertEqual(rows.first?.message.id, 1_499)
        XCTAssertEqual(rows.count, 500)
    }

    func testPrefilterFormsFoldLikeSQLiteLower() {
        XCTAssertEqual(SQLFragments.textMayContain("iPhone").bindings.count, 2, "an ASCII term needs one blob form")
        XCTAssertEqual(SQLFragments.textMayContain("iPhone").bindings.last as? String, "iphone")
        XCTAssertEqual(
            SQLFragments.textMayContain("ÉCOLE").bindings.dropFirst().compactMap { $0 as? String },
            ["école", "École"])
        XCTAssertEqual(SQLFragments.asciiLowercased("ÉCOLE McD"), "École mcd")
    }
}
