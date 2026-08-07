import XCTest
@testable import iMessageMax

final class SendResponseTests: XCTestCase {
    func testSuccessResponseUsesSentStatus() {
        let response = SendResponse.success(
            deliveredTo: ["Rob Dezendorf"],
            chat: ChatReference(id: "chat123", name: "Rob Dezendorf")
        )

        XCTAssertEqual(response.status, "sent")
        XCTAssertNil(response.message)
        XCTAssertEqual(response.chat?.id, "chat123")
        XCTAssertEqual(response.chat?.name, "Rob Dezendorf")
        XCTAssertEqual(response.chatId, "chat123")
    }

    func testPendingResponseUsesPendingConfirmationStatus() {
        let response = SendResponse.pending(
            "Attachment accepted but still pending",
            deliveredTo: ["Rob Dezendorf"],
            chat: ChatReference(id: "chat456", name: "Project Group")
        )

        XCTAssertEqual(response.status, "pending_confirmation")
        XCTAssertEqual(response.message, "Attachment accepted but still pending")
        XCTAssertNil(response.error)
        XCTAssertEqual(response.chat?.name, "Project Group")
        XCTAssertEqual(response.chatId, "chat456")
    }

    // testCancelledResponseUsesCancelledStatus removed with plan 017:
    // SendResponse.cancelled existed solely for the deleted confirmation gate.

    func testErrorResponseUsesFailedStatus() {
        let response = SendResponse.error("Send failed")

        XCTAssertEqual(response.status, "failed")
        XCTAssertEqual(response.error, "Send failed")
        XCTAssertNil(response.message)
    }

    func testAmbiguousResponseUsesAmbiguousStatus() {
        let response = SendResponse.ambiguous(candidates: [
            RecipientCandidate(name: "Rob Dezendorf", handle: "+16317087185", lastContact: "today")
        ])

        XCTAssertEqual(response.status, "ambiguous")
        XCTAssertNil(response.error)
        XCTAssertEqual(response.message, "Multiple contacts match. Please specify using a phone number, email, or chat_id.")
        XCTAssertEqual(response.candidates?.count, 1)
    }
}
