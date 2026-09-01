import XCTest
@testable import iMessageMax

final class ContactResolverTests: XCTestCase {
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
}
