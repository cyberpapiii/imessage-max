import Foundation
import IMessageMaxContract
import MCP
import Synchronization
import XCTest
@testable import iMessageMax

/// Messages is never started or told anything here. The account reads are
/// fakes that return what a signed-in, signed-out, disabled or SMS-only Mac
/// reports, and the one real-shaped output is copied from a signed-in Mac.
final class IMessageAccountTests: XCTestCase {
    private typealias Record = MessagesAccountRecord

    private final class Box<Value: Sendable>: Sendable {
        let value: Mutex<Value>
        init(_ value: Value) { self.value = Mutex(value) }
        var current: Value { value.withLock { $0 } }
        func update(_ change: (inout Value) -> Void) { value.withLock { change(&$0) } }
    }

    // MARK: The script's report

    /// Output of the account script on a signed-in Mac (macOS 26). Three
    /// built-in accounts have a service type the sdef cannot name.
    private static let signedInOutput = """
        IMESSAGE_MAX_ACCOUNT\tother\ttrue\tconnected
        IMESSAGE_MAX_ACCOUNT\tSMS\ttrue\tconnected
        IMESSAGE_MAX_ACCOUNT\tother\ttrue\tconnected
        IMESSAGE_MAX_ACCOUNT\tother\ttrue\tconnected
        IMESSAGE_MAX_ACCOUNT\tiMessage\ttrue\tconnected
        IMESSAGE_MAX_ACCOUNT\tRCS\tfalse\tdisconnected
        IMESSAGE_MAX_ACCOUNTS_DONE\t6
        """

    func testParsesARealReport() throws {
        let accounts = try XCTUnwrap(IMessageAccountScript.parse(Self.signedInOutput))
        XCTAssertEqual(accounts.count, 6)
        XCTAssertEqual(accounts[4], Record(service: "iMessage", enabled: true, connection: "connected"))
        XCTAssertEqual(accounts[5], Record(service: "RCS", enabled: false, connection: "disconnected"))
        XCTAssertEqual(IMessageAccountScript.status(of: accounts), .signedIn)
    }

    func testAPartialReportIsNotAReport() {
        XCTAssertNil(IMessageAccountScript.parse(""))
        XCTAssertNil(IMessageAccountScript.parse("IMESSAGE_MAX_ACCOUNT\tiMessage\ttrue\tconnected\n"))
        XCTAssertNil(IMessageAccountScript.parse(
            "IMESSAGE_MAX_ACCOUNT\tiMessage\ttrue\tconnected\nIMESSAGE_MAX_ACCOUNTS_DONE\t2"))
        XCTAssertEqual(IMessageAccountScript.parse("IMESSAGE_MAX_ACCOUNTS_DONE\t0"), [])
    }

    func testTheScriptOnlyReads() {
        let source = IMessageAccountScript.source
        for property in ["service type", "enabled", "connection status"] {
            XCTAssertTrue(source.contains("(\(property) of anAccount)"), property)
        }
        for word in ["send ", "set enabled", "log in", "log out", "delete", "make "] {
            XCTAssertFalse(source.contains(word), "the account check must not \(word)")
        }
    }

    // MARK: What the accounts mean

    private func status(_ accounts: [Record]) -> IMessageAccountStatus {
        IMessageAccountScript.status(of: accounts)
    }

    private let sms = Record(service: "SMS", enabled: true, connection: "connected")
    private let smsOff = Record(service: "SMS", enabled: true, connection: "disconnected")

    func testSignedIn() {
        XCTAssertEqual(status([Record(service: "iMessage", enabled: true, connection: "connected"), sms]), .signedIn)
        // A second, turned-off account does not hide the working one.
        XCTAssertEqual(status([
            Record(service: "iMessage", enabled: false, connection: "disconnected"),
            Record(service: "iMessage", enabled: true, connection: "connected"),
        ]), .signedIn)
    }

    func testSignedOutIsTurnedOnButNotConnected() {
        for connection in ["disconnected", "disconnecting", "unknown"] {
            XCTAssertEqual(status([Record(service: "iMessage", enabled: true, connection: connection), sms]), .signedOut, connection)
        }
    }

    func testConnecting() {
        XCTAssertEqual(status([Record(service: "iMessage", enabled: true, connection: "connecting")]), .connecting)
    }

    func testDisabled() {
        XCTAssertEqual(status([Record(service: "iMessage", enabled: false, connection: "disconnected"), smsOff]), .disabled)
    }

    func testNoIMessageAccountButSMSIsSMSOnlyNotBroken() {
        XCTAssertEqual(status([sms]), .smsOnly)
        XCTAssertEqual(status([Record(service: "iMessage", enabled: false, connection: "disconnected"), sms]), .smsOnly)
    }

    func testNoAccountThatCanSend() {
        XCTAssertEqual(status([]), .noAccount)
        XCTAssertEqual(status([smsOff, Record(service: "RCS", enabled: false, connection: "disconnected")]), .noAccount)
    }

    // MARK: Monitor: bounded, cached, one read at a time

    private final class Reads: Sendable {
        let answers: Mutex<[IMessageAccountStatus]>
        let mayStart = Mutex<[Bool]>([])
        init(_ answers: [IMessageAccountStatus]) { self.answers = Mutex(answers) }
        var count: Int { mayStart.withLock { $0.count } }
        func next(_ mayStartMessages: Bool) -> IMessageAccountStatus {
            mayStart.withLock { $0.append(mayStartMessages) }
            return answers.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
        }
    }

    private final class FakeClock: Sendable {
        let instant = Mutex(ContinuousClock.now)
        func advance(_ by: Duration) { instant.withLock { $0 += by } }
        var now: ContinuousClock.Instant { instant.withLock { $0 } }
    }

    func testDefiniteAnswerIsKeptForSixtySeconds() {
        let reads = Reads([.signedIn, .signedOut])
        let clock = FakeClock()
        let monitor = IMessageAccountMonitor(now: { clock.now }, read: reads.next)

        XCTAssertEqual(monitor.status(), .signedIn)
        clock.advance(.seconds(59))
        XCTAssertEqual(monitor.status(), .signedIn)
        XCTAssertEqual(monitor.keptStatus, .signedIn)
        XCTAssertEqual(reads.count, 1)

        clock.advance(.seconds(2))
        XCTAssertNil(monitor.keptStatus)
        XCTAssertEqual(monitor.status(), .signedOut)
        XCTAssertEqual(reads.count, 2)
    }

    func testAnswersThatAreNotAboutTheAccountAreReadAgain() {
        let reads = Reads([.connecting, .messagesNotResponding, .checkFailed, .signedIn])
        let monitor = IMessageAccountMonitor(read: reads.next)
        XCTAssertEqual(monitor.status(), .connecting)
        XCTAssertEqual(monitor.status(), .messagesNotResponding)
        XCTAssertEqual(monitor.status(), .checkFailed)
        XCTAssertEqual(monitor.status(), .signedIn)
        XCTAssertEqual(monitor.status(), .signedIn)
        XCTAssertEqual(reads.count, 4)
    }

    /// Messages may be started for the check only until the account has been
    /// read once, so a diagnose poll never keeps bringing back a Messages
    /// that someone quit.
    func testMessagesIsStartedOnlyUntilTheFirstAnswer() {
        let reads = Reads([.messagesNotResponding, .signedIn, .messagesNotRunning])
        let clock = FakeClock()
        let monitor = IMessageAccountMonitor(now: { clock.now }, read: reads.next)
        _ = monitor.status()
        _ = monitor.status()
        clock.advance(.seconds(61))
        XCTAssertEqual(monitor.status(), .messagesNotRunning)
        XCTAssertEqual(reads.mayStart.withLock { $0 }, [true, true, false])
    }

    func testAHungReadTimesOutHoldsOneThreadAndIsKeptWhenItAnswers() {
        let release = DispatchSemaphore(value: 0)
        let started = Mutex(0)
        let monitor = IMessageAccountMonitor(timeout: .milliseconds(200)) { _ in
            started.withLock { $0 += 1 }
            release.wait()
            return .signedOut
        }

        let clock = ContinuousClock()
        let elapsed = clock.measure { XCTAssertEqual(monitor.status(), .messagesNotResponding) }
        XCTAssertLessThan(elapsed, .seconds(1))

        DispatchQueue.concurrentPerform(iterations: 6) { _ in
            XCTAssertEqual(monitor.status(), .messagesNotResponding)
        }
        XCTAssertEqual(started.withLock { $0 }, 1, "callers wait for the read in flight, they do not start another")

        release.signal()
        let deadline = ContinuousClock.now + .seconds(5)
        while monitor.keptStatus == nil, ContinuousClock.now < deadline {
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + .milliseconds(10))
        }
        XCTAssertEqual(monitor.status(), .signedOut, "the late answer is kept for the next caller")
        XCTAssertEqual(started.withLock { $0 }, 1)
    }

    // MARK: The live read, with a fake launch and script

    private func liveRead(
        running: Bool = true, launches: Bool = true,
        script: @escaping ScriptExecutor
    ) -> (IMessageAccountMonitor.Read, Box<[String]>) {
        let calls = Box<[String]>([])
        let read = IMessageAccountMonitor.liveRead(
            launch: { _ in calls.update { $0.append("launch") }; return launches },
            isRunning: { running },
            runScript: { source, arguments in
                calls.update { $0.append("script") }
                XCTAssertEqual(source, IMessageAccountScript.source)
                XCTAssertEqual(arguments, [])
                return script(source, arguments)
            })
        return (read, calls)
    }

    func testLiveReadStartsMessagesHiddenThenReads() {
        let (read, calls) = liveRead(running: false) { _, _ in
            .success(Osascript.Output(stdout: Self.signedInOutput, stderr: "", terminationStatus: 0))
        }
        XCTAssertEqual(read(true), .signedIn)
        XCTAssertEqual(calls.current, ["launch", "script"])
    }

    func testLiveReadLeavesAClosedMessagesClosedOnceAllowedNoMore() {
        let (read, calls) = liveRead(running: false) { _, _ in XCTFail("no script"); return .failure(.timeout) }
        XCTAssertEqual(read(false), .messagesNotRunning)
        XCTAssertEqual(calls.current, [])
    }

    func testLiveReadFailuresAreNotAccountAnswers() {
        let (noLaunch, calls) = liveRead(launches: false) { _, _ in XCTFail("no script"); return .failure(.timeout) }
        XCTAssertEqual(noLaunch(true), .messagesNotResponding)
        XCTAssertEqual(calls.current, ["launch"])

        XCTAssertEqual(liveRead { _, _ in .failure(.timeout) }.0(true), .messagesNotResponding)
        XCTAssertEqual(liveRead { _, _ in .failure(.messagesAppUnavailable) }.0(true), .messagesNotResponding)
        XCTAssertEqual(liveRead { _, _ in
            .success(Osascript.Output(stdout: "", stderr: "execution error: Not authorized (-1743)", terminationStatus: 1))
        }.0(true), .checkFailed)
        XCTAssertEqual(liveRead { _, _ in
            .success(Osascript.Output(stdout: "garbage", stderr: "", terminationStatus: 0))
        }.0(true), .checkFailed)
    }

    // MARK: Diagnose

    private func diagnose(
        account: IMessageAccountStatus?, automation: AutomationProbe = { (true, .authorized) },
        asked: Box<Int> = Box(0)
    ) async throws -> DiagnoseResult {
        try await DiagnoseTool.execute(
            resolver: ContactResolver(seedCache: [:], authorization: (true, .authorized)),
            dbProbe: { (true, .accessible) },
            automationProbe: automation,
            accountProbe: {
                asked.update { $0 += 1 }
                return account
            },
            usageDescriptionProbe: { true }
        )
    }

    private let sendKeys: [CapabilityKey] = [.sendTextDM, .sendTextGroup, .sendFileDM, .sendFileGroup]

    func testDiagnoseSignedIn() async throws {
        let result = try await diagnose(account: .signedIn)
        XCTAssertEqual(result[.imessageAccount], Capability(state: .supported, detail: "signed_in"))
        for key in sendKeys { XCTAssertEqual(result[key]?.state, .supported, key.rawValue) }
        XCTAssertEqual(result.status, .ready)
    }

    func testDiagnoseSignedOutDisabledOrMissingDegradesSendsWithTheSignInFix() async throws {
        for status in [IMessageAccountStatus.signedOut, .disabled, .noAccount] {
            let result = try await diagnose(account: status)
            let account = try XCTUnwrap(result[.imessageAccount])
            XCTAssertEqual(account.state, .degraded, status.rawValue)
            XCTAssertEqual(account.detail, status.rawValue)
            XCTAssertEqual(account.fix, DiagnoseTool.iMessageSignInFix)
            XCTAssertNotNil(account.note)
            for key in sendKeys {
                XCTAssertEqual(result[key]?.state, .degraded, "\(status) \(key)")
                XCTAssertEqual(result[key]?.fix, DiagnoseTool.iMessageSignInFix)
                XCTAssertEqual(result[key]?.detail, "imessage_account")
            }
            XCTAssertEqual(result[.permAutomation]?.state, .supported, "the grant itself is fine")
            XCTAssertEqual(result.status, .ready, "reads still work")
        }
    }

    func testDiagnoseSMSOnlyKeepsSendsSupported() async throws {
        let result = try await diagnose(account: .smsOnly)
        XCTAssertEqual(result[.imessageAccount]?.state, .degraded)
        XCTAssertEqual(result[.imessageAccount]?.detail, "sms_only")
        XCTAssertTrue(result[.imessageAccount]?.note?.contains("SMS") == true)
        for key in sendKeys { XCTAssertEqual(result[key]?.state, .supported, key.rawValue) }
    }

    func testDiagnoseConnectingDoesNotBlockSends() async throws {
        let result = try await diagnose(account: .connecting)
        XCTAssertEqual(result[.imessageAccount]?.state, .degraded)
        XCTAssertNil(result[.imessageAccount]?.fix)
        for key in sendKeys { XCTAssertEqual(result[key]?.state, .supported, key.rawValue) }
    }

    func testDiagnoseProbeTimeoutIsUnverifiedAndKeepsSends() async throws {
        for status in [IMessageAccountStatus.messagesNotResponding, .messagesNotRunning, .checkFailed] {
            let result = try await diagnose(account: status)
            XCTAssertEqual(result[.imessageAccount]?.state, .unverified, status.rawValue)
            XCTAssertEqual(result[.imessageAccount]?.detail, status.rawValue)
            XCTAssertNotNil(result[.imessageAccount]?.note)
            for key in sendKeys { XCTAssertEqual(result[key]?.state, .supported, "\(status) \(key)") }
        }
    }

    /// The account is read through Automation. Without it the script would
    /// be refused, or wait on a consent prompt nobody can see.
    func testDiagnoseDoesNotReadTheAccountWithoutAutomation() async throws {
        for answer in [PermissionStatus.denied, .notDetermined, .messagesNotResponding] {
            let asked = Box(0)
            let result = try await diagnose(account: .signedIn, automation: { (false, answer) }, asked: asked)
            XCTAssertEqual(asked.current, 0, answer.rawValue)
            XCTAssertEqual(result[.imessageAccount]?.state, .unverified)
            XCTAssertEqual(result[.imessageAccount]?.detail, "not_checked")
        }
    }

    // MARK: Send

    func testNoSendingAccountIsANotStartedRetrySafeError() throws {
        let result = SendScript.interpretResult(
            stdout: "IMESSAGE_MAX_RESULT\tfailure\tnot_started\t28100\tNo iMessage account is turned on in Messages.\n",
            stderr: "", terminationStatus: 0, sentFileName: "",
            missingTargetError: .recipientNotFound("+15555550100"))
        guard case .failure(let failure) = result else { return XCTFail("expected failure") }
        guard case .noSendingAccount = failure.error else { return XCTFail("got \(failure.error)") }
        XCTAssertEqual(failure.disposition, .notStarted)
        XCTAssertTrue(failure.disposition.retrySafe)
        let text = try XCTUnwrap(failure.error.errorDescription)
        XCTAssertTrue(text.hasPrefix("Nothing was sent"), text)
        XCTAssertTrue(text.contains(DiagnoseTool.iMessageSignInFix))

        let response = SendResponse.error(ClientErrorMessages.sanitized(failure.error), disposition: failure.disposition)
        XCTAssertEqual(response.status, .failed)
        XCTAssertTrue(response.retrySafe)
    }

    func testParticipantScriptPicksATurnedOnAccount() {
        let source = SendScript.source(.participant, .text)
        XCTAssertFalse(source.contains("1st account whose service type = iMessage\n"), "never the first account blindly")
        XCTAssertTrue(source.contains("1st account whose service type = iMessage and enabled is true and connection status is connected"))
        XCTAssertTrue(source.contains("1st account whose service type = iMessage and enabled is true\n"))
        XCTAssertTrue(source.contains("recipientId does not contain \"@\""), "SMS only for phone numbers")
        XCTAssertTrue(source.contains("number 28100"))
        // The account is chosen before the dispatch phase, so a failure is not_started.
        let pick = try! XCTUnwrap(source.range(of: "number 28100"))
        let dispatch = try! XCTUnwrap(source.range(of: "set dispatchPhase to \"dispatch_started\""))
        XCTAssertLessThan(pick.lowerBound, dispatch.lowerBound)
        XCTAssertFalse(SendScript.source(.chat, .text).contains("account"), "a chat send keeps its chat's account")
    }

    func testUnconfirmedSendNamesASignedOutAccount() async throws {
        let asked = Box(0)
        let tool = SendTool(
            resolver: ContactResolver(seedCache: [:]), runner: StubScriptRunner(),
            accountStatus: { asked.update { $0 += 1 }; return .signedOut })

        let uncertain = await tool.explainingAccount(.uncertain(deliveredTo: ["+15555550100"], chat: nil))
        XCTAssertTrue(uncertain.message?.contains("signed_out") == true, uncertain.message ?? "")
        XCTAssertTrue(uncertain.message?.contains(DiagnoseTool.iMessageSignInFix) == true)

        let failed = await tool.explainingAccount(.failedDelivery(guid: "g", errorCode: 22, deliveredTo: [], chat: nil))
        XCTAssertTrue(failed.message?.contains("signed_out") == true)
        XCTAssertEqual(asked.current, 2)

        let confirmed = await tool.explainingAccount(.confirmed(guid: "g", deliveredTo: [], chat: nil))
        XCTAssertNil(confirmed.message)
        XCTAssertEqual(asked.current, 2, "a confirmed send never waits on the account check")
    }

    func testUnconfirmedSendWithASignedInAccountIsUnchanged() async {
        let tool = SendTool(
            resolver: ContactResolver(seedCache: [:]), runner: StubScriptRunner(),
            accountStatus: { .signedIn })
        let response = SendResponse.uncertain(deliveredTo: [], chat: nil)
        let explained = await tool.explainingAccount(response)
        XCTAssertEqual(explained.message, response.message)
    }
}
