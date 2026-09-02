import XCTest
@testable import iMessageMax

final class ContactResolverTests: XCTestCase {
    final class Box: @unchecked Sendable {
        var loads = 0
        var requested = false
        var authorized = true
        var status = "authorized"
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

    private func withoutCI(_ body: () async throws -> Void) async rethrows {
        let previous = ProcessInfo.processInfo.environment["CI"]
        unsetenv("CI")
        defer {
            if let previous { setenv("CI", previous, 1) } else { unsetenv("CI") }
        }
        try await body()
    }

    private func seeded() -> ContactResolver {
        ContactResolver(seedCache: [
            "+15550000001": "John Smith",
            "+15550000002": "Mary Jo Baker",
            "+15550000003": "Major Tom",
        ])
    }

    func testEmptyQueryMatchesNothing() async {
        let resolver = seeded()
        let empty = await resolver.searchByName("")
        XCTAssertTrue(empty.isEmpty)
        let whitespace = await resolver.searchByName("   ")
        XCTAssertTrue(whitespace.isEmpty)
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

    func testHeadlessPolicySkipsRequestWhenNotDetermined() async throws {
        try await withoutCI {
            let (resolver, box) = makeInjected()
            box.authorized = false
            box.status = "not_determined"
            await resolver.requestAccessIfAllowed(policy: .skipIfNotDetermined)
            XCTAssertFalse(box.requested)
            let stats = await resolver.getStats()
            XCTAssertTrue(stats.accessRequestSkippedHeadless)
        }
    }

    func testInteractivePolicyRequestsWhenNotDetermined() async throws {
        try await withoutCI {
            let (resolver, box) = makeInjected()
            box.authorized = false
            box.status = "not_determined"
            await resolver.requestAccessIfAllowed(policy: .requestIfNeeded)
            XCTAssertTrue(box.requested)
            let stats = await resolver.getStats()
            XCTAssertFalse(stats.accessRequestSkippedHeadless)
        }
    }

    func testNoRequestWhenAlreadyDetermined() async throws {
        try await withoutCI {
            let (resolver, box) = makeInjected()
            box.authorized = false
            box.status = "denied"
            await resolver.requestAccessIfAllowed(policy: .requestIfNeeded)
            XCTAssertFalse(box.requested)
            let stats = await resolver.getStats()
            XCTAssertFalse(stats.accessRequestSkippedHeadless)
        }
    }

    func testCacheRefreshesAfterTTL() async throws {
        try await withoutCI {
            let (resolver, box) = makeInjected()
            box.names = ["+15550000001": "Old"]
            try await resolver.initialize()
            let first = await resolver.resolve("+15550000001")
            XCTAssertEqual(first, "Old")
            box.names["+15550000001"] = "New"
            try await resolver.initialize()
            let stillOld = await resolver.resolve("+15550000001")
            XCTAssertEqual(stillOld, "Old")
            XCTAssertEqual(box.loads, 1)
            box.clock += 31
            try await resolver.initialize()
            let refreshed = await resolver.resolve("+15550000001")
            XCTAssertEqual(refreshed, "New")
            XCTAssertEqual(box.loads, 2)
        }
    }

    func testChangeNotificationInvalidatesCache() async throws {
        try await withoutCI {
            let (resolver, box) = makeInjected()
            box.names = ["+15550000001": "Old"]
            try await resolver.initialize()
            box.names["+15550000001"] = "New"
            await resolver.invalidate()
            try await resolver.initialize()
            let name = await resolver.resolve("+15550000001")
            XCTAssertEqual(name, "New")
        }
    }

    func testRevokeClearsCachedNames() async throws {
        try await withoutCI {
            let (resolver, box) = makeInjected()
            box.names = ["+15550000001": "Old"]
            try await resolver.initialize()
            box.authorized = false
            box.status = "denied"
            box.clock += 31
            try await resolver.initialize()
            let name = await resolver.resolve("+15550000001")
            let stats = await resolver.getStats()
            let search = await resolver.searchByName("ol")
            XCTAssertNil(name)
            XCTAssertEqual(stats.handleCount, 0)
            XCTAssertTrue(search.isEmpty)
        }
    }

    func testLoadFailureKeepsLastGoodCache() async throws {
        try await withoutCI {
            let (resolver, box) = makeInjected()
            box.names = ["+15550000001": "Old"]
            try await resolver.initialize()
            box.failNext = true
            box.clock += 31
            try await resolver.initialize()
            let name = await resolver.resolve("+15550000001")
            XCTAssertEqual(name, "Old")

            let (fresh, failBox) = makeInjected()
            failBox.failNext = true
            do {
                try await fresh.initialize()
                XCTFail("first load failure must throw")
            } catch {
                // expected
            }
        }
    }
}
