import XCTest
@testable import iMessageMax

final class SearchReactionSubqueryHangTests: XCTestCase {
    func testSearchAndContextFinishOnThousandsOfAttributedBodyRowsWithReactions() async throws {
        let fixture = try makeHangFixture(fillerCount: 2500)
        let db = fixture.database()
        let resolver = makeSeededResolver()

        let searchStart = ContinuousClock.now
        let search = try await decodeJSONDictionary(from:
            SearchTool.execute(
                query: "lisbon",
                db: db,
                resolver: resolver
            )
        )
        let searchElapsed = ContinuousClock.now - searchStart
        XCTAssertLessThan(searchElapsed, .seconds(2), "search took \(searchElapsed)")
        let results = try decodeJSONArray(try XCTUnwrap(search["results"]))
        XCTAssertEqual(results.compactMap { $0["id"] as? String }, ["msg_1"])
        XCTAssertEqual(results.first?["reactions"] as? [String], ["❤️ Alice Smith"])

        let contextStart = ContinuousClock.now
        let context = try await GetContext.execute(
            messageId: "msg_1",
            before: 5,
            after: 5,
            database: db,
            resolver: resolver
        )
        let contextElapsed = ContinuousClock.now - contextStart
        XCTAssertLessThan(contextElapsed, .seconds(2), "get_context took \(contextElapsed)")
        let response = context
        XCTAssertEqual(response.message.id, "msg_1")
    }

    /// One old attributedBody match plus `fillerCount` newer attributedBody-only
    /// rows that do not contain the term. Half the fillers also have a reaction
    /// so the old correlated subquery would full-scan on every candidate.
    private func makeHangFixture(fillerCount: Int) throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "search-hang-\(fillerCount)")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 1, guid: "hang-chat", displayName: "Hang")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)

        let hit = Array("Lisbon".utf8)
        try fixture.insertMessage(
            rowId: 1,
            guid: "hit-1",
            text: nil,
            date: 1,
            isFromMe: false,
            handleId: 1,
            attributedBody: typedstreamBlob(lengthField: [UInt8(hit.count)], payload: hit)
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 1)
        try fixture.insertMessage(
            rowId: 2,
            guid: "rxn-hit",
            text: nil,
            date: 2,
            isFromMe: false,
            handleId: 1,
            associatedMessageType: 2000,
            associatedMessageGuid: "p:0/hit-1"
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 2)

        let filler = Array("nothing".utf8)
        let fillerBlob = typedstreamBlob(lengthField: [UInt8(filler.count)], payload: filler)
        var batch = "BEGIN;"
        for n in 0..<fillerCount {
            let rowId = 10 + n
            let guid = "filler-\(rowId)"
            let hex = fillerBlob.map { String(format: "%02X", $0) }.joined()
            batch += """
                INSERT INTO message (ROWID, guid, text, attributedBody, date, is_from_me, handle_id, associated_message_type)
                VALUES (\(rowId), '\(guid)', NULL, X'\(hex)', \(rowId), 0, 1, 0);
                INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, \(rowId));
                """
            if n % 2 == 0 {
                let rxnId = 10_000 + n
                batch += """
                    INSERT INTO message (ROWID, guid, text, date, is_from_me, handle_id, associated_message_type, associated_message_guid)
                    VALUES (\(rxnId), 'rxn-\(rowId)', NULL, \(rowId), 0, 1, 2000, 'p:0/\(guid)');
                    INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, \(rxnId));
                    """
            }
        }
        batch += "COMMIT;"
        try fixture.execute(batch)
        return fixture
    }
}

