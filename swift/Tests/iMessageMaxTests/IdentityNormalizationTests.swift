import XCTest
@testable import iMessageMax

final class IdentityNormalizationTests: XCTestCase {
    func testBusinessRBMHandleGetsCleanBrandLabel() {
        let participant = ChatIdentity.makeParticipant(
            handle: "verizon_prod_ldnh3omh_agent@rbm.goog",
            contactName: nil
        )

        XCTAssertEqual(participant.displayName, "Verizon")
    }

    func testDuplicateParticipantNamesAreDisambiguatedConservatively() {
        let participants = [
            ChatIdentity.makeParticipant(handle: "+15550001111", contactName: "Alex Smith"),
            ChatIdentity.makeParticipant(handle: "+15550002222", contactName: "Alex Smith"),
            ChatIdentity.makeParticipant(handle: "+15550003333", contactName: "Taylor Jones"),
        ]

        let formatted = IdentityDisplayFormatter.participants(participants)

        XCTAssertEqual(formatted.map(\.name), [
            "Alex Smith (1111)",
            "Alex Smith (2222)",
            "Taylor Jones",
        ])
        XCTAssertEqual(formatted.map(\.handle), [
            "+15550001111",
            "+15550002222",
            "+15550003333",
        ])
    }
}
