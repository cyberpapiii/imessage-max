import XCTest
@testable import iMessageMax

final class SendResolverTests: XCTestCase {
    func testResolveChatIdReturnsExactChatTarget() async throws {
        let fixture = try makeResolverFixture()

        let resolver = SendResolver(db: fixture.database(), resolver: ContactResolver(seedCache: [:]))
        let result = await resolver.resolve(.chatId("chat10"))

        switch result {
        case .failure(let message):
            XCTFail("Unexpected failure: \(message)")
        case .ambiguous:
            XCTFail("Unexpected ambiguity")
        case .success(let resolved):
            guard case .chat(let guid, let chatId) = resolved.target else {
                return XCTFail("Expected exact chat target")
            }
            XCTAssertEqual(guid, "any;+;chat-test-guid")
            XCTAssertEqual(chatId, 10)
            XCTAssertEqual(Set(resolved.deliveredTo), Set(["+1 (555) 555-0123", "+1 (555) 555-0124"]))
        }
    }

    func testResolvePhoneNumberReturnsParticipantTarget() async throws {
        let fixture = try makeResolverFixture()

        let resolver = SendResolver(db: fixture.database(), resolver: ContactResolver(seedCache: [:]))
        let result = await resolver.resolve(.recipient("+15555550123"))

        switch result {
        case .failure(let message):
            XCTFail("Unexpected failure: \(message)")
        case .ambiguous:
            XCTFail("Unexpected ambiguity")
        case .success(let resolved):
            guard case .participant(let handle, let chatId) = resolved.target else {
                return XCTFail("Expected participant target")
            }
            XCTAssertEqual(handle, "+15555550123")
            XCTAssertEqual(chatId, 11)
            XCTAssertEqual(resolved.deliveredTo, ["+1 (555) 555-0123"])
        }
    }

    func testResolveNameSingleMatchReturnsParticipant() async throws {
        let fixture = try makeResolverFixture()

        let contacts = ContactResolver(seedCache: ["+15555550123": "Nick Jones"])
        let resolver = SendResolver(db: fixture.database(), resolver: contacts)
        let result = await resolver.resolve(.recipient("Nick"))

        switch result {
        case .failure(let message):
            XCTFail("Unexpected failure: \(message)")
        case .ambiguous:
            XCTFail("Unexpected ambiguity")
        case .success(let resolved):
            guard case .participant(let handle, let chatId) = resolved.target else {
                return XCTFail("Expected participant target")
            }
            XCTAssertEqual(handle, "+15555550123")
            XCTAssertEqual(chatId, 11)
            XCTAssertEqual(resolved.deliveredTo, ["Nick Jones"])
        }
    }

    func testResolveNameMultiMatchReturnsAmbiguousSortedByRecency() async throws {
        let fixture = try makeResolverFixture()

        let contacts = ContactResolver(seedCache: [
            "+15555550123": "Nick Jones",
            "+15555550124": "Andrew Jones",
        ])
        let resolver = SendResolver(db: fixture.database(), resolver: contacts)
        let result = await resolver.resolve(.recipient("Jones"))

        switch result {
        case .failure(let message):
            XCTFail("Unexpected failure: \(message)")
        case .success:
            XCTFail("Unexpected success")
        case .ambiguous(let candidates):
            XCTAssertEqual(candidates.count, 2)
            // Handle 1 has a message row (date 1000); handle 2 has none.
            // nil-lastContact sorts last per SendResolution.swift's comparator.
            XCTAssertEqual(candidates[0].handle, "+15555550123")
            XCTAssertEqual(candidates[1].handle, "+15555550124")
            XCTAssertEqual(candidates[1].lastContact, "never")
            // Deliberately not asserting candidates[0].lastContact's exact
            // string. It's a relative-time format that drifts with the clock.
        }
    }

    func testResolveShortNumericDestinationFallsThroughToContactLookup() async throws {
        let fixture = try makeResolverFixture()

        let contacts = ContactResolver(seedCache: ["+15555550123": "Nick Jones"])
        let resolver = SendResolver(db: fixture.database(), resolver: contacts)
        let result = await resolver.resolve(.recipient("55555"))

        guard case .failure(let message) = result else {
            return XCTFail("Expected failure for unmatched short code")
        }
        XCTAssertFalse(
            message.contains("Invalid phone number format"),
            "Short numeric destination should not die as a phone parse: \(message)"
        )
        XCTAssertEqual(message, "No contact found matching '55555'")
    }

    func testResolvePlusPrefixedShortCodeStaysOnPhonePath() async throws {
        let fixture = try makeResolverFixture()

        let resolver = SendResolver(db: fixture.database(), resolver: ContactResolver(seedCache: [:]))
        let result = await resolver.resolve(.recipient("+55555"))

        guard case .failure(let message) = result else {
            return XCTFail("Expected failure for + prefixed short code")
        }
        XCTAssertEqual(message, "No conversation found with +55555")
    }

    func testResolveDigitOnlyContactName() async throws {
        let fixture = try makeResolverFixture()

        let contacts = ContactResolver(seedCache: ["+15555550123": "55555"])
        let resolver = SendResolver(db: fixture.database(), resolver: contacts)
        let result = await resolver.resolve(.recipient("55555"))

        switch result {
        case .failure(let message):
            XCTFail("Unexpected failure: \(message)")
        case .ambiguous:
            XCTFail("Unexpected ambiguity")
        case .success(let resolved):
            guard case .participant(let handle, let chatId) = resolved.target else {
                return XCTFail("Expected participant target")
            }
            XCTAssertEqual(handle, "+15555550123")
            XCTAssertEqual(chatId, 11)
            XCTAssertEqual(resolved.deliveredTo, ["55555"])
        }
    }

    func testResolveNameNoMatchFails() async throws {
        let fixture = try makeResolverFixture()

        let contacts = ContactResolver(seedCache: ["+15555550123": "Nick Jones"])
        let resolver = SendResolver(db: fixture.database(), resolver: contacts)
        let result = await resolver.resolve(.recipient("Zelda"))

        guard case .failure(let message) = result else {
            return XCTFail("Expected failure for unmatched name")
        }
        XCTAssertEqual(message, "No contact found matching 'Zelda'")

        // Without Contacts access the miss says why, not "no such contact".
        let denied = SendResolver(
            db: fixture.database(),
            resolver: ContactResolver(seedCache: [:], authorization: (false, "denied"))
        )
        guard case .failure(let deniedMessage) = await denied.resolve(.recipient("Zelda")) else {
            return XCTFail("Expected failure without Contacts access")
        }
        XCTAssertEqual(deniedMessage, "Cannot search by name without contacts access")
    }

    /// Last-contact times for an ambiguous name come from one query, not one
    /// per candidate.
    func testNameResolutionQueryCountDoesNotGrowWithCandidates() async throws {
        func queries(candidates: Int) async throws -> Int {
            let fixture = try ToolTestDatabase(name: "send-jo")
            var seed: [String: String] = [:]
            for index in 0..<candidates {
                let handle = "+1555100000\(index)"
                seed[handle] = "Jo \(index)"
                try fixture.insertHandle(rowId: index + 1, handle: handle)
                try fixture.insertMessage(
                    rowId: index + 1,
                    guid: "jo-msg-\(index)",
                    text: "hi",
                    date: Int64(index + 1) * 1_000,
                    isFromMe: false,
                    handleId: index + 1
                )
            }
            let resolver = SendResolver(db: fixture.database(), resolver: ContactResolver(seedCache: seed))
            return try await countQueries {
                guard case .ambiguous(let found) = await resolver.resolve(.recipient("Jo")) else {
                    return XCTFail("Expected ambiguous name resolution")
                }
                XCTAssertEqual(found.count, candidates)
            }
        }
        let few = try await queries(candidates: 2)
        let many = try await queries(candidates: 8)
        XCTAssertGreaterThan(few, 0)
        XCTAssertEqual(many, few, "send-by-name ran \(many) queries for 8 candidates, \(few) for 2")
    }
}

/// A two-person group (chat 10) and a DM with the first person (chat 11),
/// who has one message at date 1000.
private func makeResolverFixture() throws -> ToolTestDatabase {
    let fixture = try ToolTestDatabase(name: "send-resolver")
    try fixture.insertHandle(rowId: 1, handle: "+15555550123")
    try fixture.insertHandle(rowId: 2, handle: "+15555550124")
    try fixture.insertChat(rowId: 10, guid: "any;+;chat-test-guid")
    try fixture.joinChatHandle(chatId: 10, handleId: 1)
    try fixture.joinChatHandle(chatId: 10, handleId: 2)
    try fixture.insertChat(rowId: 11, guid: "any;-;+15555550123")
    try fixture.joinChatHandle(chatId: 11, handleId: 1)
    try fixture.insertMessage(rowId: 1, guid: "resolver-msg-1", date: 1000, isFromMe: false, handleId: 1)
    return fixture
}
