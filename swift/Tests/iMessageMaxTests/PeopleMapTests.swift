import XCTest
@testable import iMessageMax

final class PeopleMapTests: XCTestCase {
    func testParticipantRulesSuffixCollisionsWithPositionAndNumberUnnamed() {
        var people = PeopleMap(rules: .participants)
        people.addMe()
        XCTAssertEqual(people.add(handle: "+1", name: "Alice Smith", position: 0), "alice")
        XCTAssertEqual(people.add(handle: "+2", name: nil, position: 1), "unknown1")
        XCTAssertEqual(people.add(handle: "+3", name: "Alice Jones", position: 2), "alice2")
        XCTAssertEqual(people.add(handle: "+4", name: "Me Too", position: 3), "me3")
        XCTAssertEqual(people.add(handle: "+1", name: "Alice Smith", position: 4), "alice")
        XCTAssertEqual(people.people.map(\.key), ["me", "alice", "unknown1", "alice2", "me3"])
    }

    func testSeenRulesCountCollisionsFromTwoAndNumberUnnamedWithP() {
        var people = PeopleMap(rules: .seen)
        XCTAssertEqual(people.add(handle: "+1", name: "Alice Smith"), "alice")
        XCTAssertEqual(people.add(handle: "+2", name: nil), "p1")
        XCTAssertEqual(people.add(handle: "+3", name: "Alice Jones"), "alice2")
        XCTAssertEqual(people.add(handle: "+4", name: "Alice Brown"), "alice3")
        XCTAssertEqual(people.add(handle: "+5", name: nil), "p2")
        people.addMe()
        XCTAssertEqual(people.people.last?.key, "me")
        XCTAssertTrue(people.people.last?.isMe ?? false)
    }

    func testLabelsUseKeysForSendersAndUnknownForStrangeReactors() {
        var people = PeopleMap(rules: .participants)
        people.addMe()
        people.add(handle: "+1", name: "Alice Smith")
        let labels = people.labels(noHandle: "unknown")
        XCTAssertEqual(labels.reactor(nil), "me")
        XCTAssertEqual(labels.reactor("+1"), "alice")
        XCTAssertEqual(labels.reactor("+9"), "unknown")
    }
}
