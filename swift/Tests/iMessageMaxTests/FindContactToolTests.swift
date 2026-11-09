import XCTest
import MCP
@testable import iMessageMax

final class FindContactToolTests: XCTestCase {
    func testNameListsEveryHandleWithItsDirectChatMostRecentFirst() async throws {
        let fixture = try makeContactFixture()

        let json = try await callTool("find_contact", ["query": "sam"], database: fixture.database(), resolver: contactsResolver())

        XCTAssertEqual(json["more"] as? Bool, false)
        let contacts = try decodeJSONArray(json["contacts"])
        XCTAssertEqual(contacts.compactMap { $0["name"] as? String }, ["Sam Lee", "Samira Khan"])

        let sam = try decodeJSONArray(contacts[0]["handles"])
        XCTAssertEqual(sam.compactMap { $0["handle"] as? String }, ["+15550000001", "sam@example.com"])
        XCTAssertEqual(sam[0]["chat_id"] as? String, "chat1")
        XCTAssertNotNil(sam[0]["last_contact"])
        XCTAssertNil(sam[1]["chat_id"], "a handle seen only in a group has no 1:1 chat")
        XCTAssertNotNil(sam[1]["last_contact"])

        let samira = try decodeJSONArray(contacts[1]["handles"])
        XCTAssertEqual(samira.count, 1)
        XCTAssertEqual(Set(samira[0].keys), ["handle"], "a never-messaged handle carries only the handle")
        XCTAssertEqual(samira[0]["handle"] as? String, "+15550000009")
    }

    func testNumberOrEmailFindsTheContactThatOwnsIt() async throws {
        let fixture = try makeContactFixture()

        for query in ["(555) 000-0001", "SAM@example.com"] {
            let json = try await callTool("find_contact", ["query": .string(query)], database: fixture.database(), resolver: contactsResolver())
            let contacts = try decodeJSONArray(json["contacts"])
            XCTAssertEqual(contacts.compactMap { $0["name"] as? String }, ["Sam Lee"], query)
            XCTAssertEqual(try decodeJSONArray(contacts[0]["handles"]).count, 2, query)
        }
    }

    func testNoMatchReturnsNoContacts() async throws {
        let fixture = try makeContactFixture()

        for query in ["Zelda", "+15559999999"] {
            let json = try await callTool("find_contact", ["query": .string(query)], database: fixture.database(), resolver: contactsResolver())
            XCTAssertEqual(try decodeJSONArray(json["contacts"]).count, 0, query)
            XCTAssertEqual(json["more"] as? Bool, false, query)
        }
    }

    func testLimitReportsMore() async throws {
        let fixture = try makeContactFixture()

        let json = try await callTool("find_contact", ["query": "sam", "limit": 1], database: fixture.database(), resolver: contactsResolver())

        XCTAssertEqual(try decodeJSONArray(json["contacts"]).compactMap { $0["name"] as? String }, ["Sam Lee"])
        XCTAssertEqual(json["more"] as? Bool, true)
    }

    func testMissingQueryAndMissingContactsAccessFail() async throws {
        let fixture = try makeContactFixture()

        let missing = try await callTool("find_contact", [:], database: fixture.database(), resolver: contactsResolver())
        XCTAssertEqual(missing["error"] as? String, "validation_error")

        let denied = ContactResolver(seedCache: [:], authorization: (false, "denied"))
        let json = try await callTool("find_contact", ["query": "sam"], database: fixture.database(), resolver: denied)
        XCTAssertEqual(json["error"] as? String, "contacts_unavailable")
    }

    /// A short query on a large address book reads chat.db once to rank the
    /// matches, then once per page handle that Messages knows, however many
    /// contacts match.
    func testLargeAddressBookStaysBounded() async throws {
        let fixture = try makeContactFixture()
        var names: [String: String] = [:]
        for index in 0..<20_000 {
            names[String(format: "+1666%07d", index)] = "Sa\(index) Person\(index)"
        }
        let resolver = ContactResolver(seedCache: names)

        let start = Date()
        let queries = try await countQueries {
            let json = try await callTool("find_contact", ["query": "sa"], database: fixture.database(), resolver: resolver)
            XCTAssertEqual(try decodeJSONArray(json["contacts"]).count, FindContactTool.limit.defaultValue)
            XCTAssertEqual(json["more"] as? Bool, true)
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(queries, 1, "none of the page handles is in chat.db")
        XCTAssertLessThan(elapsed, 2, "20k contacts took \(elapsed) s")
    }
}

private func contactsResolver() -> ContactResolver {
    ContactResolver(seedCache: [
        "+15550000001": "Sam Lee",
        "sam@example.com": "Sam Lee",
        "+15550000009": "Samira Khan",
        "+15550000003": "Chris Green",
    ])
}

/// Sam Lee has a DM over his number and wrote in a group from his email,
/// which chat.db spells in mixed case. Samira Khan has never been messaged.
private func makeContactFixture() throws -> ToolTestDatabase {
    let fixture = try ToolTestDatabase(name: "find-contact")
    try fixture.insertHandle(rowId: 1, handle: "+15550000001")
    try fixture.insertHandle(rowId: 2, handle: "Sam@Example.com")
    try fixture.insertHandle(rowId: 3, handle: "+15550000003")

    try fixture.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
    try fixture.joinChatHandle(chatId: 1, handleId: 1)
    try fixture.insertMessage(rowId: 1, guid: "m1", text: "hi", date: AppleTime.fromDate(Date().addingTimeInterval(-3_600)), isFromMe: false, handleId: 1)
    try fixture.joinChatMessage(chatId: 1, messageId: 1)

    try fixture.insertChat(rowId: 2, guid: "iMessage;+;group", displayName: "Crew")
    try fixture.joinChatHandle(chatId: 2, handleId: 2)
    try fixture.joinChatHandle(chatId: 2, handleId: 3)
    try fixture.insertMessage(rowId: 2, guid: "m2", text: "yo", date: AppleTime.fromDate(Date().addingTimeInterval(-86_400)), isFromMe: false, handleId: 2)
    try fixture.joinChatMessage(chatId: 2, messageId: 2)
    return fixture
}
