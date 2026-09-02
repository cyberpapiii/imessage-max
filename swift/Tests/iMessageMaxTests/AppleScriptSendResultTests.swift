import XCTest
@testable import iMessageMax

final class AppleScriptSendResultTests: XCTestCase {
    private let missing = SendError.chatNotFound("iMessage;-;x")

    private func interpret(_ stdout: String, stderr: String = "", status: Int32 = 0) -> Result<Void, SendFailure> {
        AppleScriptRunner.interpretSendResult(
            stdout: stdout, stderr: stderr, terminationStatus: status, missingTargetError: missing
        )
    }

    func testOkCompletedIsSuccess() {
        guard case .success = interpret("IMESSAGE_MAX_RESULT\tok\tcompleted\t0\t\n") else {
            return XCTFail("expected success")
        }
    }

    func testPreDispatchFailureIsNotStartedAndKeepsTypedError() {
        let result = interpret("IMESSAGE_MAX_RESULT\tfailure\tnot_started\t-1728\tCan’t get chat id \"iMessage;-;x\".\n")
        guard case .failure(let failure) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(failure.disposition, .notStarted)
        XCTAssertTrue(failure.disposition.retrySafe)
        XCTAssertEqual(failure.error.localizedDescription, missing.localizedDescription)
    }

    func testPostDispatchFailureIsMayHaveCompleted() {
        let result = interpret("IMESSAGE_MAX_RESULT\tfailure\tmay_have_completed\t-1712\tMessages got an error: AppleEvent timed out.\n")
        guard case .failure(let failure) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(failure.disposition, .mayHaveCompleted)
        XCTAssertFalse(failure.disposition.retrySafe)
        XCTAssertTrue(failure.error.localizedDescription.contains("AppleEvent timed out"))
    }

    func testAutomationDeniedBeforeDispatchIsNotStarted() {
        let result = interpret("IMESSAGE_MAX_RESULT\tfailure\tnot_started\t-1743\tNot authorized to send Apple events to Messages.\n")
        guard case .failure(let failure) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(failure.disposition, .notStarted)
        XCTAssertEqual(failure.error.localizedDescription, SendError.automationPermissionRequired.localizedDescription)
    }

    func testErrorMessageContainingTabsIsPreserved() {
        let result = interpret("IMESSAGE_MAX_RESULT\tfailure\tnot_started\t-2700\tline one\twith tab\n")
        guard case .failure(let failure) = result else { return XCTFail("expected failure") }
        XCTAssertTrue(failure.error.localizedDescription.contains("with tab"), "message after the 4th tab must survive the split")
    }

    func testMarkerIsFoundOnLastLineAfterNoise() {
        let result = interpret("some warning\nIMESSAGE_MAX_RESULT\tok\tcompleted\t0\t\n")
        guard case .success = result else { return XCTFail("expected success") }
    }

    func testNonzeroExitWithoutMarkerIsMayHaveCompletedAndClassifiesStderr() {
        let result = interpret("", stderr: "execution error: Messages got an error: Connection is invalid. (-609)", status: 1)
        guard case .failure(let failure) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(failure.disposition, .mayHaveCompleted)
        XCTAssertEqual(failure.error.localizedDescription, SendError.messagesAppUnavailable.localizedDescription)
    }

    func testZeroExitWithoutMarkerIsMayHaveCompleted() {
        let result = interpret("", stderr: "", status: 0)
        guard case .failure(let failure) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(failure.disposition, .mayHaveCompleted)
        XCTAssertEqual(failure.error.localizedDescription, "Send failed: Messages returned no structured send result")
    }

    func testUnknownPhaseIsMayHaveCompleted() {
        let result = interpret("IMESSAGE_MAX_RESULT\tfailure\tsomething_else\t0\tx\n")
        guard case .failure(let failure) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(failure.disposition, .mayHaveCompleted)
    }
}
