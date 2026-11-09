import XCTest
import IMessageMaxContract
import Synchronization
@testable import iMessageMax

/// Messages is never started or told anything here: every check, launch
/// and script is a fake that records what the helper asked for.
final class MessagesAccessTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("imax-automation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Remembered answer

    func testMemoryKeepsDefiniteAnswersBesideTheToken() throws {
        let memory = AutomationMemory(folder: folder)
        XCTAssertNil(memory.answer)
        XCTAssertEqual(memory.file?.lastPathComponent, ServiceDefaults.automationAnswerFileName)

        memory.remember(.authorized)
        XCTAssertEqual(memory.answer, .authorized)
        XCTAssertEqual(AutomationMemory(folder: folder).answer, .authorized, "a new helper reads the saved answer")

        let file = try XCTUnwrap(memory.file)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o600)

        memory.remember(.denied)
        XCTAssertEqual(AutomationMemory(folder: folder).answer, .denied)
        memory.remember(.notDetermined)
        XCTAssertEqual(AutomationMemory(folder: folder).answer, .notDetermined)
    }

    func testMemoryIgnoresAnswersThatAreNotDefinite() {
        let memory = AutomationMemory(folder: folder)
        memory.remember(.authorized)
        for word in [PermissionStatus.messagesNotRunning, .messagesNotFound, .checkFailed(-1)] {
            memory.remember(word)
        }
        XCTAssertEqual(memory.answer, .authorized)
        XCTAssertEqual(AutomationMemory(folder: folder).answer, .authorized)
    }

    func testMemoryIgnoresAFileThatHoldsSomethingElse() throws {
        let file = folder.appendingPathComponent(ServiceDefaults.automationAnswerFileName)
        for content in ["messages_not_running\n", "garbage", String(repeating: "a", count: 200)] {
            try Data(content.utf8).write(to: file)
            XCTAssertNil(AutomationMemory(folder: folder).answer, content)
        }
        try Data("denied\n".utf8).write(to: file)
        XCTAssertEqual(AutomationMemory(folder: folder).answer, .denied)
    }

    func testMemoryWithoutAFolderWritesNothing() throws {
        let memory = AutomationMemory(folder: nil)
        memory.remember(.authorized)
        XCTAssertEqual(memory.answer, .authorized)
        XCTAssertNil(memory.file)
    }

    // MARK: Diagnose's check

    func testRunningMessagesAnswersLiveAndIsRemembered() {
        let fake = FakeMessages(running: true, answer: .denied)
        let access = fake.access(memory: AutomationMemory(folder: folder))
        let result = access.automationStatus()
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.status, .denied)
        XCTAssertEqual(fake.launches, [])
        XCTAssertEqual(fake.prompts, [false])
        XCTAssertEqual(AutomationMemory(folder: folder).answer, .denied)
    }

    func testClosedMessagesReportsTheRememberedAnswerWithoutLaunching() {
        AutomationMemory(folder: folder).remember(.authorized)
        let fake = FakeMessages(running: false, answer: .authorized)
        let access = fake.access(memory: AutomationMemory(folder: folder))
        for _ in 0..<3 {
            let result = access.automationStatus()
            XCTAssertTrue(result.ok)
            XCTAssertEqual(result.status, .authorized)
        }
        XCTAssertEqual(fake.launches, [], "a poll must not start Messages when an answer is remembered")
    }

    func testClosedMessagesWithNothingRememberedLaunchesHiddenOnce() {
        let fake = FakeMessages(running: false, answer: .authorized)
        let access = fake.access(memory: AutomationMemory(folder: folder))
        let first = access.automationStatus()
        XCTAssertEqual(first.status, .authorized)
        XCTAssertTrue(first.ok)
        XCTAssertEqual(fake.launches.count, 1)
        XCTAssertEqual(AutomationMemory(folder: folder).answer, .authorized)

        fake.quit()
        XCTAssertEqual(access.automationStatus().status, .authorized)
        XCTAssertEqual(fake.launches.count, 1)
    }

    func testFailedLaunchIsRetriedAfterTheRecheckInterval() {
        let fake = FakeMessages(running: false, answer: .authorized, launchSucceeds: false)
        let clock = FakeClock()
        let access = fake.access(memory: AutomationMemory(folder: folder), clock: clock)
        XCTAssertEqual(access.automationStatus().status, .messagesNotRunning)
        XCTAssertEqual(access.automationStatus().status, .messagesNotRunning)
        XCTAssertEqual(fake.launches.count, 1, "a poll must not start Messages again and again")
        XCTAssertNil(AutomationMemory(folder: folder).answer)

        clock.advance(by: MessagesAccess.recheckInterval - .seconds(1))
        _ = access.automationStatus()
        XCTAssertEqual(fake.launches.count, 1)

        fake.launchSucceeds(true)
        clock.advance(by: .seconds(1))
        XCTAssertEqual(access.automationStatus().status, .authorized, "a failed launch must not stick for the helper's lifetime")
        XCTAssertEqual(fake.launches.count, 2)
    }

    /// The person turns Automation on in System Settings while Messages is
    /// closed. Diagnose must see it within the recheck interval.
    func testRememberedDenialIsRecheckedAtMostEveryInterval() {
        AutomationMemory(folder: folder).remember(.denied)
        let fake = FakeMessages(running: false, answer: .denied)
        let clock = FakeClock()
        let access = fake.access(memory: AutomationMemory(folder: folder), clock: clock)

        XCTAssertEqual(access.automationStatus().status, .denied)
        XCTAssertEqual(fake.launches.count, 1)
        fake.quit()
        fake.setAnswer(.authorized)

        for _ in 0..<3 {
            XCTAssertEqual(access.automationStatus().status, .denied, "the remembered answer stands between rechecks")
        }
        clock.advance(by: .seconds(299))
        XCTAssertEqual(access.automationStatus().status, .denied)
        XCTAssertEqual(fake.launches.count, 1)

        clock.advance(by: .seconds(1))
        let result = access.automationStatus()
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.status, .authorized)
        XCTAssertEqual(fake.launches.count, 2)
        XCTAssertEqual(AutomationMemory(folder: folder).answer, .authorized)

        fake.quit()
        clock.advance(by: .seconds(3600))
        XCTAssertEqual(access.automationStatus().status, .authorized)
        XCTAssertEqual(fake.launches.count, 2, "a remembered grant is never rechecked by starting Messages")
    }

    func testRememberedNotDeterminedIsRechecked() {
        AutomationMemory(folder: folder).remember(.notDetermined)
        let fake = FakeMessages(running: false, answer: .authorized)
        let access = fake.access(memory: AutomationMemory(folder: folder))
        XCTAssertEqual(access.automationStatus().status, .authorized)
        XCTAssertEqual(fake.launches.count, 1)
    }

    func testHungMessagesIsReportedAndNotRemembered() {
        AutomationMemory(folder: folder).remember(.authorized)
        let fake = FakeMessages(running: true, answer: .messagesNotResponding)
        let access = fake.access(memory: AutomationMemory(folder: folder))
        let result = access.automationStatus()
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.status, .messagesNotResponding)
        XCTAssertEqual(fake.launches, [])
        XCTAssertEqual(AutomationMemory(folder: folder).answer, .authorized)
    }

    // MARK: Setup request

    func testRequestStartsMessagesHiddenBeforeAsking() {
        let fake = FakeMessages(running: false, answer: .notDetermined, answerAfterPrompt: .authorized)
        let access = fake.access(memory: AutomationMemory(folder: folder))
        let result = access.requestAutomation()
        XCTAssertTrue(result.ok)
        XCTAssertEqual(fake.events, ["launch", "check prompt=true"])
        XCTAssertEqual(AutomationMemory(folder: folder).answer, .authorized)
    }

    // MARK: Sends

    func testTextSendStartsMessagesHiddenBeforeItsScript() {
        let fake = FakeMessages(running: false, answer: .authorized)
        let runner = LiveScriptRunner(
            access: fake.access(memory: AutomationMemory(folder: folder)),
            runScript: fake.script(output: Self.resultLine("ok", "completed", "0", "")))
        let result = runner.sendBlocking(.text("hello"), to: .participant(handle: "+15555550123", chatId: nil))
        guard case .success = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(fake.events, ["launch", "script"])
        XCTAssertEqual(AutomationMemory(folder: folder).answer, .authorized)
    }

    func testFileSendStartsMessagesBeforeTheTransferQuery() throws {
        let fake = FakeMessages(running: false, answer: .authorized)
        let stagingRoot = folder.appendingPathComponent("staging", isDirectory: true)
        let source = folder.appendingPathComponent("photo.txt")
        try Data("x".utf8).write(to: source)
        let runner = LiveScriptRunner(
            access: fake.access(memory: AutomationMemory(folder: folder)),
            stager: OutgoingFileStager(root: stagingRoot),
            runScript: fake.script(output: ""))
        _ = runner.sendBlocking(.file(path: source.path), to: .participant(handle: "+15555550123", chatId: nil))
        XCTAssertEqual(fake.events.prefix(2), ["launch", "script"])
    }

    func testMissingFileDoesNotStartMessages() {
        let fake = FakeMessages(running: false, answer: .authorized)
        let runner = LiveScriptRunner(
            access: fake.access(memory: AutomationMemory(folder: folder)),
            stager: OutgoingFileStager(root: folder.appendingPathComponent("staging", isDirectory: true)),
            runScript: fake.script(output: ""))
        _ = runner.sendBlocking(.file(path: "/definitely/missing/file.png"), to: .participant(handle: "+15555550123", chatId: nil))
        XCTAssertEqual(fake.events, [])
    }

    // MARK: Automation gate before a send

    /// Nobody can answer a consent prompt on a headless Mac. The send must
    /// stop before any script, say nothing was sent, and remember why.
    func testNotDeterminedSendStopsBeforeAnyScript() {
        let fake = FakeMessages(running: false, answer: .notDetermined)
        let runner = LiveScriptRunner(
            access: fake.access(memory: AutomationMemory(folder: folder)),
            runScript: fake.script(output: Self.resultLine("ok", "completed", "0", "")))
        let started = ContinuousClock.now
        let result = runner.sendBlocking(.text("hello"), to: .participant(handle: "+15555550123", chatId: nil))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        guard case .failure(let failure) = result, case .automationPermissionRequired = failure.error else {
            return XCTFail("expected an Automation stop, got \(result)")
        }
        XCTAssertEqual(failure.disposition, .notStarted)
        XCTAssertTrue(failure.disposition.retrySafe)
        XCTAssertEqual(fake.events, ["launch"], "no script may run, so no prompt can appear")
        XCTAssertEqual(fake.prompts, [false])
        XCTAssertEqual(AutomationMemory(folder: folder).answer, .notDetermined)
    }

    func testDeniedSendStopsBeforeAnyScript() {
        let fake = FakeMessages(running: true, answer: .denied)
        let runner = LiveScriptRunner(
            access: fake.access(memory: AutomationMemory(folder: folder)),
            runScript: fake.script(output: Self.resultLine("ok", "completed", "0", "")))
        let result = runner.sendBlocking(.text("hello"), to: .chat(guid: "iMessage;-;x", chatId: 1))
        guard case .failure(let failure) = result, case .automationPermissionRequired = failure.error else {
            return XCTFail("expected an Automation stop, got \(result)")
        }
        XCTAssertEqual(failure.disposition, .notStarted)
        XCTAssertFalse(fake.events.contains("script"))
        XCTAssertEqual(AutomationMemory(folder: folder).answer, .denied)
    }

    func testNotDeterminedFileSendStopsBeforeStaging() throws {
        let fake = FakeMessages(running: true, answer: .notDetermined)
        let stagingRoot = folder.appendingPathComponent("staging", isDirectory: true)
        let source = folder.appendingPathComponent("photo.txt")
        try Data("x".utf8).write(to: source)
        let runner = LiveScriptRunner(
            access: fake.access(memory: AutomationMemory(folder: folder)),
            stager: OutgoingFileStager(root: stagingRoot),
            runScript: fake.script(output: ""))
        let result = runner.sendBlocking(.file(path: source.path), to: .participant(handle: "+15555550123", chatId: nil))
        guard case .failure(let failure) = result, case .automationPermissionRequired = failure.error else {
            return XCTFail("expected an Automation stop, got \(result)")
        }
        XCTAssertEqual(failure.disposition, .notStarted)
        XCTAssertFalse(fake.events.contains("script"))
        let staged = (try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)) ?? []
        XCTAssertEqual(staged, [], "nothing may be staged for a send that never starts")
    }

    func testHungMessagesFailsTheSendFastAsNotStarted() {
        let fake = FakeMessages(running: true, answer: .messagesNotResponding)
        let runner = LiveScriptRunner(
            access: fake.access(memory: AutomationMemory(folder: folder)),
            runScript: fake.script(output: Self.resultLine("ok", "completed", "0", "")))
        let result = runner.sendBlocking(.text("hello"), to: .participant(handle: "+15555550123", chatId: nil))
        guard case .failure(let failure) = result, case .messagesAppUnavailable = failure.error else {
            return XCTFail("expected Messages unavailable, got \(result)")
        }
        XCTAssertEqual(failure.disposition, .notStarted)
        XCTAssertFalse(fake.events.contains("script"))
    }

    /// When macOS cannot answer (Messages did not start hidden), the script
    /// still runs and reports for itself, as before.
    func testUnansweredCheckStillRunsTheScript() {
        let fake = FakeMessages(running: false, answer: .authorized, launchSucceeds: false)
        let runner = LiveScriptRunner(
            access: fake.access(memory: AutomationMemory(folder: folder)),
            runScript: fake.script(output: Self.resultLine("ok", "completed", "0", "")))
        let result = runner.sendBlocking(.text("hello"), to: .participant(handle: "+15555550123", chatId: nil))
        guard case .success = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(fake.events, ["launch", "script"])
    }

    /// Messages may quit between polls. A poll that let the query start it
    /// would show its window, so each poll starts it hidden first.
    func testTransferPollsStartMessagesHiddenFirst() throws {
        let fake = FakeMessages(running: true, answer: .authorized)
        let source = folder.appendingPathComponent("photo.txt")
        try Data("x".utf8).write(to: source)
        let transferQueries = Mutex(0)
        let sendScript = fake.script(output: Self.resultLine("ok", "completed", "0", ""))
        let emptyScript = fake.script(output: "")
        let script: ScriptExecutor = { script, arguments in
            guard script.contains("file transfer") else { return sendScript(script, arguments) }
            _ = emptyScript(script, arguments)
            let count = transferQueries.withLock { count in
                count += 1
                return count
            }
            return .success(Osascript.Output(stdout: count == 1 ? "" : "finished", stderr: "", terminationStatus: 0))
        }
        let runner = LiveScriptRunner(
            access: fake.access(memory: AutomationMemory(folder: folder)),
            // The stager refuses a root under a symlink, and /var is one.
            stager: OutgoingFileStager(
                root: URL(fileURLWithPath: try XCTUnwrap(SecurePath.absoluteLexicalPath(folder.path)))
                    .appendingPathComponent("staging", isDirectory: true)),
            runScript: script)
        let result = runner.sendBlocking(.file(path: source.path), to: .participant(handle: "+15555550123", chatId: nil))
        guard case .success = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(fake.events, ["launch", "script", "script", "launch", "script"])
    }

    func testRefusedSendRemembersDenied() {
        let memory = AutomationMemory(folder: folder)
        memory.remember(.authorized)
        let fake = FakeMessages(running: true, answer: .authorized)
        let runner = LiveScriptRunner(
            access: fake.access(memory: memory),
            runScript: fake.script(output: Self.resultLine(
                "failure", "not_started", "-1743", "Not authorized to send Apple events to Messages.")))
        let result = runner.sendBlocking(.text("hello"), to: .participant(handle: "+15555550123", chatId: nil))
        guard case .failure(let failure) = result, case .automationPermissionRequired = failure.error else {
            return XCTFail("expected an Automation refusal, got \(result)")
        }
        XCTAssertEqual(AutomationMemory(folder: folder).answer, .denied)
    }

    func testOtherSendFailuresLeaveTheAnswerAlone() {
        let memory = AutomationMemory(folder: folder)
        memory.remember(.authorized)
        let fake = FakeMessages(running: true, answer: .authorized)
        let runner = LiveScriptRunner(
            access: fake.access(memory: memory),
            runScript: fake.script(output: Self.resultLine(
                "failure", "not_started", "-1728", "Can't get participant.")))
        _ = runner.sendBlocking(.text("hello"), to: .participant(handle: "+15555550123", chatId: nil))
        XCTAssertEqual(AutomationMemory(folder: folder).answer, .authorized)
    }

    // MARK: Diagnose

    func testDiagnoseWithMessagesClosedReportsRememberedAccess() async throws {
        AutomationMemory(folder: folder).remember(.authorized)
        let fake = FakeMessages(running: false, answer: .authorized)
        let access = fake.access(memory: AutomationMemory(folder: folder))
        let result = try await DiagnoseTool.execute(
            resolver: ContactResolver(seedCache: [:]),
            dbProbe: { (true, .accessible) },
            automationProbe: { access.automationStatus() })
        let automation = try XCTUnwrap(result.capabilities[CapabilityKey.permAutomation.rawValue])
        XCTAssertEqual(automation.state, .supported)
        XCTAssertEqual(automation.detail, PermissionStatus.authorized.rawValue)
        XCTAssertEqual(result.capabilities[CapabilityKey.sendTextDM.rawValue]?.state, .supported)
        XCTAssertEqual(fake.launches, [])
    }

    func testDiagnoseWithMessagesClosedReportsRememberedDenial() async throws {
        AutomationMemory(folder: folder).remember(.denied)
        let fake = FakeMessages(running: false, answer: .denied)
        let access = fake.access(memory: AutomationMemory(folder: folder))
        let result = try await DiagnoseTool.execute(
            resolver: ContactResolver(seedCache: [:]),
            dbProbe: { (true, .accessible) },
            automationProbe: { access.automationStatus() })
        let automation = try XCTUnwrap(result.capabilities[CapabilityKey.permAutomation.rawValue])
        XCTAssertEqual(automation.state, .permissionGated)
        XCTAssertEqual(automation.detail, PermissionStatus.denied.rawValue)
        XCTAssertNotNil(automation.fix)
    }

    func testHiddenLaunchConfiguration() {
        let configuration = MessagesLauncher.hiddenConfiguration()
        XCTAssertFalse(configuration.activates)
        XCTAssertTrue(configuration.hides)
        XCTAssertFalse(configuration.addsToRecentItems)
    }

    private static func resultLine(_ outcome: String, _ disposition: String, _ errno: String, _ message: String) -> String {
        [SendScript.resultMarker, outcome, disposition, errno, message].joined(separator: "\t") + "\n"
    }
}

/// Messages as the helper sees it, with a log of what it was asked.
private final class FakeMessages: Sendable {
    private struct State {
        var running: Bool
        var answer: PermissionStatus
        var launchSucceeds: Bool
        var events: [String] = []
        var launches: [String] = []
        var prompts: [Bool] = []
        var prompted = false
    }

    private let state: Mutex<State>
    private let answerAfterPrompt: PermissionStatus?

    init(running: Bool, answer: PermissionStatus, answerAfterPrompt: PermissionStatus? = nil, launchSucceeds: Bool = true) {
        state = Mutex(State(running: running, answer: answer, launchSucceeds: launchSucceeds))
        self.answerAfterPrompt = answerAfterPrompt
    }

    var events: [String] { state.withLock { $0.events } }
    var launches: [String] { state.withLock { $0.launches } }
    var prompts: [Bool] { state.withLock { $0.prompts } }
    func quit() { state.withLock { $0.running = false } }
    func setAnswer(_ answer: PermissionStatus) { state.withLock { $0.answer = answer } }
    func launchSucceeds(_ succeeds: Bool) { state.withLock { $0.launchSucceeds = succeeds } }

    func access(memory: AutomationMemory, clock: FakeClock = FakeClock()) -> MessagesAccess {
        MessagesAccess(
            memory: memory,
            check: { prompt in self.check(prompt: prompt) },
            launch: { reason in self.launch(reason) },
            now: { clock.now })
    }

    func script(output: String) -> ScriptExecutor {
        { _, _ in
            self.state.withLock { $0.events.append("script") }
            return .success(Osascript.Output(stdout: output, stderr: "", terminationStatus: 0))
        }
    }

    private func check(prompt: Bool) -> (ok: Bool, status: PermissionStatus) {
        state.withLock { state in
            state.prompts.append(prompt)
            if prompt { state.events.append("check prompt=true") }
            guard state.running else { return (false, .messagesNotRunning) }
            if prompt { state.prompted = true }
            let status = state.prompted ? (answerAfterPrompt ?? state.answer) : state.answer
            return (status == .authorized, status)
        }
    }

    private func launch(_ reason: String) -> Bool {
        state.withLock { state in
            state.events.append("launch")
            state.launches.append(reason)
            if state.launchSucceeds { state.running = true }
            return state.launchSucceeds
        }
    }
}

/// A clock the test moves by hand.
private final class FakeClock: Sendable {
    private let current = Mutex(ContinuousClock.now)
    var now: ContinuousClock.Instant { current.withLock { $0 } }
    func advance(by duration: Duration) { current.withLock { $0 += duration } }
}
