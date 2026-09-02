import XCTest
@testable import iMessageMax

final class ContactsAccessPolicyTests: XCTestCase {
    func testAutoFollowsStdin() {
        XCTAssertEqual(ContactsAccessPolicy.forStdin(isTTY: true), .requestIfNeeded)
        XCTAssertEqual(ContactsAccessPolicy.forStdin(isTTY: false), .skipIfNotDetermined)
    }

    func testFlagOverridesStdin() {
        XCTAssertEqual(ContactsAccessPolicy.resolve(flag: .request, environment: [:], isTTY: false), .requestIfNeeded)
        XCTAssertEqual(ContactsAccessPolicy.resolve(flag: .skip, environment: [:], isTTY: true), .skipIfNotDetermined)
    }

    func testEnvironmentOverridesStdinWhenFlagIsAuto() {
        let env = ["IMESSAGE_MAX_CONTACTS_POLICY": "request"]
        XCTAssertEqual(ContactsAccessPolicy.resolve(flag: .auto, environment: env, isTTY: false), .requestIfNeeded)
        let skip = ["IMESSAGE_MAX_CONTACTS_POLICY": "skip"]
        XCTAssertEqual(ContactsAccessPolicy.resolve(flag: .auto, environment: skip, isTTY: true), .skipIfNotDetermined)
    }

    func testFlagBeatsEnvironment() {
        let env = ["IMESSAGE_MAX_CONTACTS_POLICY": "skip"]
        XCTAssertEqual(ContactsAccessPolicy.resolve(flag: .request, environment: env, isTTY: false), .requestIfNeeded)
    }

    func testUnknownEnvironmentValueFallsBackToStdin() {
        let env = ["IMESSAGE_MAX_CONTACTS_POLICY": "yes please"]
        XCTAssertEqual(ContactsAccessPolicy.resolve(flag: .auto, environment: env, isTTY: true), .requestIfNeeded)
        XCTAssertEqual(ContactsAccessPolicy.resolve(flag: .auto, environment: env, isTTY: false), .skipIfNotDetermined)
    }
}
