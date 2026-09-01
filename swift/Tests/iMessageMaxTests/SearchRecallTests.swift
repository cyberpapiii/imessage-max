import XCTest
@testable import iMessageMax

final class SearchRecallTests: XCTestCase {
    func testSearchFindsTextMatchOlderThanFetchWindow() async throws {
        let fixture = try makeRecallFixture()
        let resolver = makeSeededResolver()

        let response = try await decodeSearchResponse(
            SearchTool.execute(
                query: "zebra",
                db: fixture.database(),
                resolver: resolver
            )
        )
        let results = try decodeJSONArray(try XCTUnwrap(response["results"]))
        XCTAssertEqual(results.count, 1)
        let excerpt = try XCTUnwrap(results.first?["excerpt"] as? String)
        XCTAssertTrue(excerpt.contains("zebra"))
    }

    func testAttributedBodyOnlyRowIsStillFound() async throws {
        let fixture = try makeAttributedBodyRecallFixture()
        let resolver = makeSeededResolver()

        let response = try await decodeSearchResponse(
            SearchTool.execute(
                query: "zebra",
                db: fixture.database(),
                resolver: resolver
            )
        )
        let results = try decodeJSONArray(try XCTUnwrap(response["results"]))
        XCTAssertEqual(results.count, 1)
        let excerpt = try XCTUnwrap(results.first?["excerpt"] as? String)
        XCTAssertTrue(excerpt.contains("zebra"))
    }
}

private func makeRecallFixture() throws -> ToolTestDatabase {
    let fixture = try ToolTestDatabase(name: "search-recall")
    try fixture.insertHandle(rowId: 1, handle: "+15550000001")
    try fixture.insertChat(rowId: 1, guid: "recall-chat", displayName: "Recall")
    try fixture.joinChatHandle(chatId: 1, handleId: 1)

    try fixture.insertMessage(
        rowId: 1,
        guid: "zebra-1",
        text: "the zebra escaped",
        date: 1,
        isFromMe: false,
        handleId: 1
    )
    try fixture.joinChatMessage(chatId: 1, messageId: 1)

    for n in 2...601 {
        try fixture.insertMessage(
            rowId: n,
            guid: "filler-\(n)",
            text: "filler \(n)",
            date: Int64(n),
            isFromMe: false,
            handleId: 1
        )
        try fixture.joinChatMessage(chatId: 1, messageId: n)
    }
    return fixture
}

/// Builds: <prefix junk> + marker + 5 filler bytes + length field + payload.
/// Copied from SendVerifierTests (private there).
private func typedstreamBlob(marker: String = "NSString", lengthField: [UInt8], payload: [UInt8]) -> Data {
    var bytes: [UInt8] = [0x04, 0x0B]
    bytes += Array(marker.utf8)
    bytes += [0x01, 0x94, 0x84, 0x01, 0x2B]
    bytes += lengthField
    bytes += payload
    return Data(bytes)
}

private func makeAttributedBodyRecallFixture() throws -> ToolTestDatabase {
    let fixture = try ToolTestDatabase(name: "search-recall-attr")
    try fixture.insertHandle(rowId: 1, handle: "+15550000001")
    try fixture.insertChat(rowId: 1, guid: "recall-attr-chat", displayName: "Recall Attr")
    try fixture.joinChatHandle(chatId: 1, handleId: 1)

    let payload = Array("zebra".utf8)
    let blob = typedstreamBlob(lengthField: [UInt8(payload.count)], payload: payload)
    try fixture.insertMessage(
        rowId: 1,
        guid: "zebra-attr-1",
        text: nil,
        date: 1,
        isFromMe: false,
        handleId: 1,
        attributedBody: blob
    )
    try fixture.joinChatMessage(chatId: 1, messageId: 1)

    for n in 2...601 {
        try fixture.insertMessage(
            rowId: n,
            guid: "filler-attr-\(n)",
            text: "filler \(n)",
            date: Int64(n),
            isFromMe: false,
            handleId: 1
        )
        try fixture.joinChatMessage(chatId: 1, messageId: n)
    }
    return fixture
}
