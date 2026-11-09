import Contacts
import IMessageMaxContract
import XCTest
@testable import iMessageMax

final class ContactResolverTests: XCTestCase {
    final class Box: @unchecked Sendable {
        var loads = 0
        var requested = false
        var authorized = true
        var status: PermissionStatus = "authorized"
        var names: [String: String] = [:]
        var failNext = false
        var clock: TimeInterval = 0
    }

    private func makeInjected(refreshInterval: TimeInterval = 30) -> (ContactResolver, Box) {
        let box = Box()
        let resolver = ContactResolver(
            source: ContactResolver.Source(
                authorization: { (box.authorized, box.status) },
                load: {
                    if box.failNext {
                        box.failNext = false
                        throw NSError(domain: "ContactResolverTests", code: 1)
                    }
                    box.loads += 1
                    return box.names
                },
                requestAccess: { box.requested = true; return true }
            ),
            refreshInterval: refreshInterval,
            now: { box.clock }
        )
        return (resolver, box)
    }

    private func seeded() -> ContactResolver {
        ContactResolver(seedCache: [
            "+15550000001": "John Smith",
            "+15550000002": "Mary Jo Baker",
            "+15550000003": "Major Tom",
        ])
    }

    func testDisplayNameFallsBackToNicknameThenOrganization() {
        func name(_ given: String, _ family: String, _ nickname: String, _ organization: String) -> String? {
            ContactResolver.displayName(givenName: given, familyName: family, nickname: nickname, organization: organization)
        }
        XCTAssertEqual(name("Ann", "Lee", "Annie", "Acme"), "Ann Lee")
        XCTAssertEqual(name("", "Lee", "Annie", "Acme"), "Lee")
        XCTAssertEqual(name("", "", "Annie", "Acme"), "Annie")
        XCTAssertEqual(name("", "", " ", "Acme Plumbing"), "Acme Plumbing")
        XCTAssertNil(name(" ", "", "", ""))
    }

    func testNicknameAndOrganizationOnlyContactsAreLoaded() {
        let acme = CNMutableContact()
        acme.contactType = .organization
        acme.organizationName = "Acme Plumbing"
        acme.phoneNumbers = [CNLabeledValue(label: CNLabelWork, value: CNPhoneNumber(stringValue: "020 7946 0958"))]
        let gran = CNMutableContact()
        gran.nickname = "Gran"
        gran.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: "Gran@Example.com" as NSString)]
        let unnamed = CNMutableContact()
        unnamed.phoneNumbers = [CNLabeledValue(label: CNLabelHome, value: CNPhoneNumber(stringValue: "07911 123456"))]

        XCTAssertEqual(
            ContactResolver.names(from: [acme, gran, unnamed], region: "GB"),
            ["+442079460958": "Acme Plumbing", "gran@example.com": "Gran"]
        )
    }

    func testContactNumbersAreReadInTheRegion() {
        let ana = CNMutableContact()
        ana.givenName = "Ana"
        ana.phoneNumbers = [
            CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "07911 123456")),
            CNLabeledValue(label: CNLabelHome, value: CNPhoneNumber(stringValue: "555 123 4567")),
        ]
        XCTAssertEqual(ContactResolver.names(from: [ana], region: "GB"), ["+447911123456": "Ana"])
        XCTAssertEqual(ContactResolver.names(from: [ana], region: "US"), ["+15551234567": "Ana"])
    }

    func testResolveReadsHandlesInTheResolverRegion() async {
        let resolver = ContactResolver(seedCache: ["+447911123456": "Ana"], region: "GB")
        let byNational = await resolver.resolve("07911 123456")
        XCTAssertEqual(byNational, "Ana")
        let us = ContactResolver(seedCache: ["+447911123456": "Ana"], region: "US")
        let usNational = await us.resolve("07911 123456")
        XCTAssertNil(usNational)
    }

    func testEmptyQueryMatchesNothing() async {
        let resolver = seeded()
        let empty = await resolver.searchByName("")
        XCTAssertTrue(empty.isEmpty)
        let whitespace = await resolver.searchByName("   ")
        XCTAssertTrue(whitespace.isEmpty)
    }

    func testMatchesComeBackSortedByNameThenHandle() async {
        let resolver = ContactResolver(seedCache: [
            "+15550000009": "Sam Lee",
            "sam@example.com": "Sam Lee",
            "+15550000001": "Sam Adams",
        ])
        let matches = await resolver.searchByName("sam")
        XCTAssertEqual(matches.map(\.handle), ["+15550000001", "+15550000009", "sam@example.com"])
    }

    func testSingleCharacterMatchesNothing() async {
        let resolver = seeded()
        let matches = await resolver.searchByName("j")
        XCTAssertTrue(matches.isEmpty)
    }

    func testPrefixMatchesWordStart() async {
        let resolver = seeded()
        let matches = await resolver.searchByName("jo")
        XCTAssertEqual(Set(matches.map(\.name)), ["John Smith", "Mary Jo Baker"])
    }

    func testMultiWordQueryRequiresAllWords() async {
        let resolver = seeded()
        let matches = await resolver.searchByName("jo sm")
        XCTAssertEqual(matches.map(\.name), ["John Smith"])
    }

    func testHeadlessPolicySkipsRequestWhenNotDetermined() async {
        let (resolver, box) = makeInjected()
        box.authorized = false
        box.status = "not_determined"
        await resolver.requestAccessIfAllowed(policy: .skipIfNotDetermined)
        XCTAssertFalse(box.requested)
        let stats = await resolver.status()
        XCTAssertTrue(stats.accessRequestSkippedHeadless)
    }

    func testInteractivePolicyRequestsWhenNotDetermined() async {
        let (resolver, box) = makeInjected()
        box.authorized = false
        box.status = "not_determined"
        await resolver.requestAccessIfAllowed(policy: .requestIfNeeded)
        XCTAssertTrue(box.requested)
        let stats = await resolver.status()
        XCTAssertFalse(stats.accessRequestSkippedHeadless)
    }

    func testNoRequestWhenAlreadyDetermined() async {
        let (resolver, box) = makeInjected()
        box.authorized = false
        box.status = "denied"
        await resolver.requestAccessIfAllowed(policy: .requestIfNeeded)
        XCTAssertFalse(box.requested)
        let stats = await resolver.status()
        XCTAssertFalse(stats.accessRequestSkippedHeadless)
    }

    func testCacheRefreshesAfterTTL() async {
        let (resolver, box) = makeInjected()
        box.names = ["+15550000001": "Old"]
        let first = await resolver.resolve("+15550000001")
        XCTAssertEqual(first, "Old")
        box.names["+15550000001"] = "New"
        let stillOld = await resolver.resolve("+15550000001")
        XCTAssertEqual(stillOld, "Old")
        XCTAssertEqual(box.loads, 1)
        box.clock += 31
        let refreshed = await resolver.resolve("+15550000001")
        XCTAssertEqual(refreshed, "New")
        XCTAssertEqual(box.loads, 2)
    }

    func testChangeNotificationInvalidatesCache() async {
        let (resolver, box) = makeInjected()
        box.names = ["+15550000001": "Old"]
        _ = await resolver.resolve("+15550000001")
        box.names["+15550000001"] = "New"
        await resolver.invalidate()
        let name = await resolver.resolve("+15550000001")
        XCTAssertEqual(name, "New")
    }

    func testRevokeClearsCachedNames() async {
        let (resolver, box) = makeInjected()
        box.names = ["+15550000001": "Old"]
        _ = await resolver.resolve("+15550000001")
        box.authorized = false
        box.status = "denied"
        box.clock += 31
        let name = await resolver.resolve("+15550000001")
        let stats = await resolver.status()
        let search = await resolver.searchByName("ol")
        XCTAssertNil(name)
        XCTAssertEqual(stats.handleCount, 0)
        XCTAssertTrue(search.isEmpty)
    }

    func testLoadFailureKeepsLastGoodCache() async {
        let (resolver, box) = makeInjected()
        box.names = ["+15550000001": "Old"]
        _ = await resolver.resolve("+15550000001")
        box.failNext = true
        box.clock += 31
        let name = await resolver.resolve("+15550000001")
        XCTAssertEqual(name, "Old")
        let kept = await resolver.status()
        XCTAssertFalse(kept.loadFailed, "a failure after a good load keeps the names")

        let (fresh, failBox) = makeInjected()
        failBox.failNext = true
        let status = await fresh.status()
        XCTAssertTrue(status.loadFailed, "a first load failure is reported")
    }
}
