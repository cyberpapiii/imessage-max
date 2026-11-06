import XCTest
@testable import iMessageMax

final class AppleScriptSendResultTests: XCTestCase {
    private let missing = SendError.chatNotFound("iMessage;-;x")

    private func interpret(_ stdout: String, stderr: String = "", status: Int32 = 0) -> Result<Void, SendFailure> {
        SendScript.interpretResult(
            stdout: stdout, stderr: stderr, terminationStatus: status, sentFileName: "", missingTargetError: missing
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

    func testParticipantTextScriptIsStable() {
        XCTAssertEqual(SendScript.source(.participant, .text), """
            on run argv
                set recipientId to item 1 of argv
                set messageText to item 2 of argv
                set dispatchPhase to "pre_dispatch"
                try
                    tell application "Messages"
                        set targetService to 1st account whose service type = iMessage
                        set targetBuddy to participant recipientId of targetService
                        set dispatchPhase to "dispatch_started"
                        send messageText to targetBuddy
                    end tell
                    return "IMESSAGE_MAX_RESULT" & tab & "ok" & tab & "completed" & tab & "0" & tab & ""
                on error errorMessage number errorNumber
                    if dispatchPhase is "pre_dispatch" then
                        return "IMESSAGE_MAX_RESULT" & tab & "failure" & tab & "not_started" & tab & errorNumber & tab & errorMessage
                    end if
                    return "IMESSAGE_MAX_RESULT" & tab & "failure" & tab & "may_have_completed" & tab & errorNumber & tab & errorMessage
                end try
            end run
            """)
    }

    func testChatFileScriptIsStable() {
        XCTAssertEqual(SendScript.source(.chat, .file), """
            on run argv
                set chatGuid to item 1 of argv
                set filePath to item 2 of argv
                set attachmentFile to POSIX file filePath
                set dispatchPhase to "pre_dispatch"
                try
                    tell application "Messages"
                        set targetChat to chat id chatGuid
                        set dispatchPhase to "dispatch_started"
                        send attachmentFile to targetChat
                    end tell
                    return "IMESSAGE_MAX_RESULT" & tab & "ok" & tab & "completed" & tab & "0" & tab & ""
                on error errorMessage number errorNumber
                    if dispatchPhase is "pre_dispatch" then
                        return "IMESSAGE_MAX_RESULT" & tab & "failure" & tab & "not_started" & tab & errorNumber & tab & errorMessage
                    end if
                    return "IMESSAGE_MAX_RESULT" & tab & "failure" & tab & "may_have_completed" & tab & errorNumber & tab & errorMessage
                end try
            end run
            """)
    }

    func testUnknownPhaseIsMayHaveCompleted() {
        let result = interpret("IMESSAGE_MAX_RESULT\tfailure\tsomething_else\t0\tx\n")
        guard case .failure(let failure) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(failure.disposition, .mayHaveCompleted)
    }
}
