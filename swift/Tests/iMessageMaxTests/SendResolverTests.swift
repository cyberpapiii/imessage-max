import Contacts
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
        case .ambiguous(let candidates, let reason):
            XCTAssertEqual(reason, .multipleMatches)
            XCTAssertEqual(candidates.count, 2)
            XCTAssertEqual(candidates[0].handle, "+15555550123")
            XCTAssertEqual(candidates[1].handle, "+15555550124")
            XCTAssertEqual(candidates[1].lastContact, "never")
        }
    }

    func testNameMatchWithHandleMissingFromMessagesIsAmbiguous() async throws {
        let fixture = try makeResolverFixture()

        let contacts = ContactResolver(seedCache: ["+15555550199": "Zed Stranger"])
        let resolver = SendResolver(db: fixture.database(), resolver: contacts)

        guard case .ambiguous(let candidates, let reason) = await resolver.resolve(.recipient("Zed")) else {
            return XCTFail("a Contacts-only handle must not resolve to a send target")
        }
        XCTAssertEqual(reason, .notInMessages)
        XCTAssertEqual(candidates.map(\.handle), ["+15555550199"])
        XCTAssertEqual(candidates.map(\.name), ["Zed Stranger"])
        XCTAssertEqual(candidates.map(\.lastContact), ["never"])
    }

    /// Finding #7: an Indian contact saved as "98765 43210" used to become
    /// +19876543210. When that stranger's number was in chat.db, a send by
    /// name went straight to them.
    func testNonUSContactNeverResolvesToAPlusOneStranger() async throws {
        let fixture = try ToolTestDatabase(name: "send-region-stranger")
        try fixture.insertHandle(rowId: 1, handle: "+19876543210")
        try fixture.insertChat(rowId: 1, guid: "iMessage;-;+19876543210")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)

        let priya = CNMutableContact()
        priya.givenName = "Priya"
        priya.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "98765 43210"))]
        let names = ContactResolver.names(from: [priya], region: "IN")
        XCTAssertEqual(names, ["+919876543210": "Priya"])

        let resolver = SendResolver(
            db: fixture.database(),
            resolver: ContactResolver(seedCache: names, region: "IN")
        )
        guard case .ambiguous(let candidates, .notInMessages) = await resolver.resolve(.recipient("Priya")) else {
            return XCTFail("the contact's real number has no conversation, so the send must be refused")
        }
        XCTAssertEqual(candidates.map(\.handle), ["+919876543210"])
    }

    func testRegionalNumberAndNameResolveToTheMessagesHandle() async throws {
        let fixture = try ToolTestDatabase(name: "send-region-gb")
        try fixture.insertHandle(rowId: 1, handle: "+447911123456")
        try fixture.insertChat(rowId: 1, guid: "iMessage;-;+447911123456")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)

        let olivia = CNMutableContact()
        olivia.givenName = "Olivia"
        olivia.familyName = "Hart"
        olivia.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "07911 123456"))]
        let contacts = ContactResolver(seedCache: ContactResolver.names(from: [olivia], region: "GB"), region: "GB")
        let resolver = SendResolver(db: fixture.database(), resolver: contacts)

        for destination in ["Olivia", "07911 123456", "+44 (0)7911 123456"] {
            guard case .success(let resolved) = await resolver.resolve(.recipient(destination)) else {
                XCTFail("\(destination) should resolve")
                continue
            }
            XCTAssertEqual(resolved.target, .participant(handle: "+447911123456", chatId: 1), destination)
            XCTAssertEqual(resolved.deliveredTo, ["Olivia Hart"], destination)
        }
    }

    func testOrganizationOnlyContactResolves() async throws {
        let fixture = try makeResolverFixture()

        let acme = CNMutableContact()
        acme.contactType = .organization
        acme.organizationName = "Acme Plumbing"
        acme.phoneNumbers = [CNLabeledValue(label: CNLabelWork, value: CNPhoneNumber(stringValue: "(555) 555-0123"))]
        let contacts = ContactResolver(seedCache: ContactResolver.names(from: [acme], region: "US"))
        let resolver = SendResolver(db: fixture.database(), resolver: contacts)

        guard case .success(let resolved) = await resolver.resolve(.recipient("Acme")) else {
            return XCTFail("an organization-only contact should resolve by its company name")
        }
        XCTAssertEqual(resolved.target, .participant(handle: "+15555550123", chatId: 11))
        XCTAssertEqual(resolved.deliveredTo, ["Acme Plumbing"])
    }

    func testEmailNameMatchUsesTheMessagesHandleSpelling() async throws {
        let fixture = try ToolTestDatabase(name: "send-email-case")
        try fixture.insertHandle(rowId: 1, handle: "Nick@Example.com")
        try fixture.insertChat(rowId: 1, guid: "iMessage;-;Nick@Example.com")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)

        let contacts = ContactResolver(seedCache: ["nick@example.com": "Nick Mail"])
        let resolver = SendResolver(db: fixture.database(), resolver: contacts)
        guard case .success(let resolved) = await resolver.resolve(.recipient("Nick")) else {
            return XCTFail("an email handle in chat.db should resolve whatever its case")
        }
        XCTAssertEqual(resolved.target, .participant(handle: "Nick@Example.com", chatId: 1))
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
            "A short numeric destination should not fail as a phone number parse: \(message)"
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

        let denied = SendResolver(
            db: fixture.database(),
            resolver: ContactResolver(seedCache: [:], authorization: (false, "denied"))
        )
        guard case .failure(let deniedMessage) = await denied.resolve(.recipient("Zelda")) else {
            return XCTFail("Expected failure without Contacts access")
        }
        XCTAssertEqual(deniedMessage, "Cannot search by name without contacts access")
    }

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
                guard case .ambiguous(let found, _) = await resolver.resolve(.recipient("Jo")) else {
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

    func testShortCodeResolvesToItsHandle() async throws {
        let fixture = try ToolTestDatabase(name: "send-short-code")
        try fixture.insertHandle(rowId: 9, handle: "12345", service: "SMS")
        try fixture.insertChat(rowId: 9, guid: "SMS;-;12345")
        try fixture.joinChatHandle(chatId: 9, handleId: 9)

        let resolver = SendResolver(db: fixture.database(), resolver: ContactResolver(seedCache: [:]))
        guard case .success(let resolved) = await resolver.resolve(.recipient("12345")) else {
            return XCTFail("a short code with a conversation should resolve")
        }
        XCTAssertEqual(resolved.target, .participant(handle: "12345", chatId: 9))
    }

    func testChatNameMatchesAcrossEntryPoints() async throws {
        let fixture = try ToolTestDatabase(name: "send-chat-name")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)
        let resolver = SendResolver(db: fixture.database(), resolver: makeSeededResolver())

        guard case .success(let byRecipient) = await resolver.resolve(.recipient("+15550000001")),
              case .success(let byChatId) = await resolver.resolve(.chatId("chat1")) else {
            return XCTFail("both entry points should resolve")
        }
        for resolved in [byRecipient, byChatId] {
            XCTAssertEqual(resolved.chat?.id, "chat1")
            XCTAssertEqual(resolved.chat?.name, "Alice Smith")
        }
    }

    func testNamedChatKeepsItsNameViaRecipient() async throws {
        let fixture = try ToolTestDatabase(name: "send-named-chat")
        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertChat(rowId: 1, guid: "iMessage;-;named", displayName: "  Alice Work  ")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)
        let resolver = SendResolver(db: fixture.database(), resolver: makeSeededResolver())

        guard case .success(let resolved) = await resolver.resolve(.recipient("+15550000001")) else {
            return XCTFail("should resolve")
        }
        XCTAssertEqual(resolved.chat?.name, "Alice Work")
    }
}

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
