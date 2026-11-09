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

    func testFailedLaunchReportsNotRunningAndNeverRetriesFromDiagnose() {
        let fake = FakeMessages(running: false, answer: .authorized, launchSucceeds: false)
        let access = fake.access(memory: AutomationMemory(folder: folder))
        XCTAssertEqual(access.automationStatus().status, .messagesNotRunning)
        XCTAssertEqual(access.automationStatus().status, .messagesNotRunning)
        XCTAssertEqual(fake.launches.count, 1)
        XCTAssertNil(AutomationMemory(folder: folder).answer)
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
        var events: [String] = []
        var launches: [String] = []
        var prompts: [Bool] = []
        var prompted = false
    }

    private let state: Mutex<State>
    private let answer: PermissionStatus
    private let answerAfterPrompt: PermissionStatus?
    private let launchSucceeds: Bool

    init(running: Bool, answer: PermissionStatus, answerAfterPrompt: PermissionStatus? = nil, launchSucceeds: Bool = true) {
        state = Mutex(State(running: running))
        self.answer = answer
        self.answerAfterPrompt = answerAfterPrompt
        self.launchSucceeds = launchSucceeds
    }

    var events: [String] { state.withLock { $0.events } }
    var launches: [String] { state.withLock { $0.launches } }
    var prompts: [Bool] { state.withLock { $0.prompts } }
    func quit() { state.withLock { $0.running = false } }

    func access(memory: AutomationMemory) -> MessagesAccess {
        MessagesAccess(
            memory: memory,
            check: { prompt in self.check(prompt: prompt) },
            launch: { reason in self.launch(reason) })
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
            let status = state.prompted ? (answerAfterPrompt ?? answer) : answer
            return (status == .authorized, status)
        }
    }

    private func launch(_ reason: String) -> Bool {
        state.withLock { state in
            state.events.append("launch")
            state.launches.append(reason)
            if launchSucceeds { state.running = true }
        }
        return launchSucceeds
    }
}
