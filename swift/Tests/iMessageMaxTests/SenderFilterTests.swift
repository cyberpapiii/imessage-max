import XCTest
@testable import iMessageMax

final class SenderFilterTests: XCTestCase {
    private let resolver = ContactResolver(seedCache: [
        "+15550000001": "Alice Smith",
        "alice@example.com": "Alice Smith",
        "+15550000009": "Alice Jones",
        "+15550000002": "Bob Brown",
    ])

    func testResolvesMePhoneEmailNameAndFallback() async {
        let me = await SenderFilter.resolve("Me", resolver: resolver)
        XCTAssertEqual(me, .me)
        let phone = await SenderFilter.resolve("(555) 000-0002", resolver: resolver)
        XCTAssertEqual(phone, .handles(["+15550000002"]))
        let email = await SenderFilter.resolve("Bob@Example.com", resolver: resolver)
        XCTAssertEqual(email, .handles(["bob@example.com"]))
        let unknown = await SenderFilter.resolve("Zed", resolver: resolver)
        XCTAssertEqual(unknown, .handleContains("Zed"))
        let empty = await SenderFilter.resolve("", resolver: resolver)
        XCTAssertNil(empty)
    }

    /// Every handle of every matching contact, in a fixed order, rather
    /// than whichever match the contact cache yielded first.
    func testNameMatchesEveryMatchingHandle() async {
        let alice = await SenderFilter.resolve("Alice", resolver: resolver)
        XCTAssertEqual(alice, .handles(["+15550000001", "+15550000009", "alice@example.com"]))
        let aliceSmith = await SenderFilter.resolve("Alice Smith", resolver: resolver)
        XCTAssertEqual(aliceSmith, .handles(["+15550000001", "alice@example.com"]))
    }
}
