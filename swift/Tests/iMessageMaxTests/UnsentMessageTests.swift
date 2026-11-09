import XCTest
import MCP
@testable import iMessageMax

/// Messages keeps an unsent message's row, clears its text and lists the
/// unsent parts under `rp` in `message_summary_info`. An edit also clears
/// `text`, keeps the new text in `attributedBody` and its history under `ec`.
final class UnsentMessageTests: XCTestCase {
    func testGetMessagesMarksUnsentAndKeepsEdits() async throws {
        let fixture = try makeUnsendFixture()

        let json = try await callTool("get_messages", ["chat_id": "chat1"], database: fixture.database())
        let byId = try messagesById(json["messages"])

        XCTAssertEqual(byId["msg_1"]?["text"] as? String, "see you at 6")
        XCTAssertNil(byId["msg_1"]?["edited"])
        XCTAssertNil(byId["msg_1"]?["unsent"])

        XCTAssertEqual(byId["msg_2"]?["text"] as? String, "see you at 7")
        XCTAssertEqual(byId["msg_2"]?["edited"] as? Bool, true)
        XCTAssertNil(byId["msg_2"]?["unsent"])

        let unsent = try XCTUnwrap(byId["msg_3"])
        XCTAssertEqual(unsent["unsent"] as? Bool, true)
        XCTAssertNil(unsent["text"])
        XCTAssertNil(unsent["edited"], "an unsent message is not also an edited one")

        XCTAssertEqual(byId["msg_4"]?["unsent"] as? Bool, true, "date_retracted marks an unsend too")
        XCTAssertNil(byId["msg_4"]?["text"])

        XCTAssertEqual(byId["msg_5"]?["text"] as? String, "here's the plan", "a partial unsend keeps the text that is left")
        XCTAssertEqual(byId["msg_5"]?["edited"] as? Bool, true)
        XCTAssertNil(byId["msg_5"]?["unsent"])
    }

    /// The columns missing, as on a Mac before Messages could unsend: the
    /// row reads the way every tool showed it before this change, an edited
    /// message with no text.
    func testWithoutTheUnsendColumnsAnUnsentRowIsABlankEdit() async throws {
        let fixture = try makeUnsendFixture()
        try fixture.execute("ALTER TABLE message DROP COLUMN message_summary_info")
        try fixture.execute("ALTER TABLE message DROP COLUMN date_retracted")

        let json = try await callTool("get_messages", ["chat_id": "chat1"], database: fixture.database())
        let unsent = try XCTUnwrap(try messagesById(json["messages"])["msg_3"])

        XCTAssertNil(unsent["unsent"])
        XCTAssertNil(unsent["text"])
        XCTAssertEqual(unsent["edited"] as? Bool, true)
    }

    func testGetMessagesSinceMarksUnsent() async throws {
        let fixture = try makeUnsendFixture()

        let json = try await callTool("get_messages_since", ["since_rowid": 0], database: fixture.database())
        let byId = try messagesById(json["messages"])

        XCTAssertEqual(byId["msg_3"]?["unsent"] as? Bool, true)
        XCTAssertNil(byId["msg_3"]?["text"])
        XCTAssertNil(byId["msg_3"]?["edited"])
        XCTAssertEqual(byId["msg_2"]?["edited"] as? Bool, true)
        XCTAssertNil(byId["msg_2"]?["unsent"])
    }

    func testGetContextMarksUnsentOnTheAnchorAndAroundIt() async throws {
        let fixture = try makeUnsendFixture()

        let json = try await callTool("get_context", ["message_id": "msg_3", "before": 2, "after": 1], database: fixture.database())

        let anchor = try XCTUnwrap(json["message"] as? [String: Any])
        XCTAssertEqual(anchor["unsent"] as? Bool, true)
        XCTAssertNil(anchor["text"])
        let before = try decodeJSONArray(json["before"])
        XCTAssertEqual(before.last?["edited"] as? Bool, true)
        XCTAssertNil(before.last?["unsent"])
        let after = try decodeJSONArray(json["after"])
        XCTAssertEqual(after.first?["unsent"] as? Bool, true)
    }

    func testSearchMarksUnsentInResultsAndContext() async throws {
        let fixture = try makeUnsendFixture()

        let bySender = try await callTool("search", ["from_person": "Alice"], database: fixture.database())
        let results = try decodeJSONArray(bySender["results"])
        let unsent = try XCTUnwrap(results.first { $0["id"] as? String == "msg_3" })
        XCTAssertEqual(unsent["unsent"] as? Bool, true)
        XCTAssertNil(unsent["edited"])
        XCTAssertNil(results.first { $0["id"] as? String == "msg_2" }?["unsent"])

        let byText = try await callTool("search", ["query": "plan", "include_context": true], database: fixture.database())
        let match = try XCTUnwrap(try decodeJSONArray(byText["results"]).first)
        XCTAssertEqual(match["id"] as? String, "msg_5")
        let contextBefore = try decodeJSONArray(match["context_before"])
        XCTAssertEqual(contextBefore.last?["unsent"] as? Bool, true)
    }

    func testGetUnreadMarksUnsent() async throws {
        let fixture = try makeUnsendFixture()

        let json = try await callTool("get_unread", ["format": "messages"], database: fixture.database())
        let byId = try messagesById(json["messages"])

        XCTAssertEqual(byId["msg_3"]?["unsent"] as? Bool, true)
        XCTAssertNil(byId["msg_3"]?["text"])
        XCTAssertNil(byId["msg_1"]?["unsent"])
    }

    func testUnsentNeedsBothTheMarkerAndNoText() {
        let unsentParts = summaryInfo(["otr": ["0": ["lo": 0, "le": 4]], "rp": [0]])
        XCTAssertEqual(MessageEdit(dateEdited: 1, dateRetracted: 0, summaryInfo: unsentParts, hasText: false), .unsent)
        XCTAssertEqual(MessageEdit(dateEdited: 1, dateRetracted: 0, summaryInfo: unsentParts, hasText: true), .edited)
        XCTAssertEqual(MessageEdit(dateEdited: 0, dateRetracted: 5, summaryInfo: nil, hasText: false), .unsent)
        XCTAssertEqual(MessageEdit(dateEdited: 1, dateRetracted: 0, summaryInfo: summaryInfo(["otr": [:], "rp": []]), hasText: false), .edited)
        XCTAssertEqual(MessageEdit(dateEdited: 1, dateRetracted: 0, summaryInfo: Data("not a plist".utf8), hasText: false), .edited)
        XCTAssertEqual(MessageEdit(dateEdited: 0, dateRetracted: 0, summaryInfo: nil, hasText: false), .none)
    }
}

private func messagesById(_ value: Any?, file: StaticString = #filePath, line: UInt = #line) throws -> [String: [String: Any]] {
    let messages = try decodeJSONArray(value, file: file, line: line)
    return Dictionary(uniqueKeysWithValues: messages.compactMap { message in
        (message["id"] as? String).map { ($0, message) }
    })
}

private func summaryInfo(_ plist: [String: Any]) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
}

/// Alice's DM, all unread and from her: a plain message, an edit, an unsent
/// message, one marked only by `date_retracted`, and a two-part message
/// whose second part (a photo) was unsent while its text stayed.
private func makeUnsendFixture() throws -> ToolTestDatabase {
    let fixture = try ToolTestDatabase(name: "unsend")
    try fixture.insertHandle(rowId: 1, handle: "+15550000001")
    try fixture.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
    try fixture.joinChatHandle(chatId: 1, handleId: 1)

    let base = AppleTime.fromDate(Date().addingTimeInterval(-3_600))
    let minute: Int64 = 60_000_000_000
    let edits = summaryInfo([
        "otr": ["0": ["lo": 0, "le": 12]],
        "ec": ["0": [
            ["d": 700_000_000, "t": typedstreamBlob(payload: Array("see you at 6:30".utf8))],
            ["d": 700_000_060, "t": typedstreamBlob(payload: Array("see you at 7".utf8))],
        ]],
    ])
    let rows: [(text: String?, body: String?, dateEdited: Int64, dateRetracted: Int64, info: Data?)] = [
        ("see you at 6", nil, 0, 0, nil),
        (nil, "see you at 7", base + 2 * minute, 0, edits),
        (nil, nil, base + 3 * minute, 0, summaryInfo(["otr": ["0": ["lo": 0, "le": 9]], "rp": [0]])),
        (nil, nil, 0, base + 4 * minute, nil),
        (nil, "here's the plan", base + 5 * minute, 0, summaryInfo(["otr": ["0": ["lo": 0, "le": 15], "1": ["lo": 15, "le": 1]], "rp": [1]])),
    ]
    for (index, row) in rows.enumerated() {
        let id = index + 1
        try fixture.insertMessage(
            rowId: id, guid: "unsend-\(id)", text: row.text, date: base + Int64(id) * minute,
            isFromMe: false, isRead: false, handleId: 1,
            attributedBody: row.body.map { typedstreamBlob(payload: Array($0.utf8)) },
            dateEdited: row.dateEdited, dateRetracted: row.dateRetracted, summaryInfo: row.info
        )
        try fixture.joinChatMessage(chatId: 1, messageId: id)
    }
    return fixture
}
