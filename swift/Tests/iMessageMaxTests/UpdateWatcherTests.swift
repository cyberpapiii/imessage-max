import CryptoKit
import Foundation
import IMessageMaxContract
import Synchronization
import XCTest
@testable import iMessageMax

/// A helper whose executable an update replaced stops once idle, so launchd
/// starts the new binary without the companion (088 #19).
final class UpdateWatcherTests: XCTestCase {
    private func file(inode: UInt64, size: Int64 = 100) -> ExecutableFile {
        ExecutableFile(
            device: 1, inode: inode, size: size,
            modified: timespec(tv_sec: 1, tv_nsec: 0), changed: timespec(tv_sec: Int(inode), tv_nsec: 0))
    }

    func testTheOriginalFileOrAMissingOneChangesNothing() {
        var replacement = ExecutableReplacement(original: file(inode: 1), idleWait: 120)
        XCTAssertEqual(replacement.observe(file(inode: 1), callsInFlight: 0, now: 0), .unchanged)
        // Midway through an update that removes the bundle first.
        XCTAssertEqual(replacement.observe(nil, callsInFlight: 0, now: 5), .unchanged)
        XCTAssertEqual(replacement.observe(nil, callsInFlight: 0, now: 10), .unchanged)
    }

    func testAMetadataChangeToTheOriginalIsNotAnUpdate() {
        var replacement = ExecutableReplacement(original: file(inode: 1), idleWait: 120)
        var touched = file(inode: 1)
        touched.changed = timespec(tv_sec: 99, tv_nsec: 0)
        XCTAssertEqual(replacement.observe(touched, callsInFlight: 0, now: 0), .unchanged)
        XCTAssertEqual(replacement.observe(touched, callsInFlight: 0, now: 5), .unchanged)
    }

    func testANewFileMustLookTheSameTwiceBeforeTheHelperStops() {
        var replacement = ExecutableReplacement(original: file(inode: 1), idleWait: 120)
        XCTAssertEqual(replacement.observe(file(inode: 2, size: 10), callsInFlight: 0, now: 0), .settling)
        // Still being written: it grew since the last read.
        XCTAssertEqual(replacement.observe(file(inode: 2, size: 20), callsInFlight: 0, now: 5), .settling)
        XCTAssertEqual(replacement.observe(file(inode: 2, size: 20), callsInFlight: 0, now: 10), .restart(idle: true))
    }

    func testAToolCallInFlightHoldsTheRestartUntilItFinishes() {
        var replacement = ExecutableReplacement(original: file(inode: 1), idleWait: 120)
        XCTAssertEqual(replacement.observe(file(inode: 2), callsInFlight: 1, now: 0), .settling)
        XCTAssertEqual(replacement.observe(file(inode: 2), callsInFlight: 1, now: 5), .waitingForIdle(calls: 1))
        XCTAssertEqual(replacement.observe(file(inode: 2), callsInFlight: 2, now: 60), .waitingForIdle(calls: 2))
        XCTAssertEqual(replacement.observe(file(inode: 2), callsInFlight: 0, now: 61), .restart(idle: true))
    }

    func testTheWaitForIdleIsBounded() {
        var replacement = ExecutableReplacement(original: file(inode: 1), idleWait: 120)
        _ = replacement.observe(file(inode: 2), callsInFlight: 1, now: 0)
        XCTAssertEqual(replacement.observe(file(inode: 2), callsInFlight: 1, now: 5), .waitingForIdle(calls: 1))
        XCTAssertEqual(replacement.observe(file(inode: 2), callsInFlight: 1, now: 124), .waitingForIdle(calls: 1))
        XCTAssertEqual(replacement.observe(file(inode: 2), callsInFlight: 1, now: 125), .restart(idle: false))
    }

    func testPuttingTheOriginalBackCancelsTheRestart() {
        var replacement = ExecutableReplacement(original: file(inode: 1), idleWait: 120)
        _ = replacement.observe(file(inode: 2), callsInFlight: 1, now: 0)
        XCTAssertEqual(replacement.observe(file(inode: 2), callsInFlight: 1, now: 5), .waitingForIdle(calls: 1))
        XCTAssertEqual(replacement.observe(file(inode: 1), callsInFlight: 1, now: 10), .unchanged)
        // A later update starts the wait afresh.
        XCTAssertEqual(replacement.observe(file(inode: 3), callsInFlight: 1, now: 200), .settling)
        XCTAssertEqual(replacement.observe(file(inode: 3), callsInFlight: 1, now: 205), .waitingForIdle(calls: 1))
    }

    /// The Dispatch-timer driver, with a fake file and a fake in-flight count.
    func testTheWatcherFiresOnceWhenTheReplacedHelperIsIdle() throws {
        let current = Mutex(file(inode: 1))
        let inFlight = Mutex(1)
        let fired = Mutex(0)
        let watcher = try XCTUnwrap(UpdateWatcher(
            path: "/fake/imessage-max",
            timing: .init(interval: 0.05, idlePoll: 0.02, idleWait: 60),
            callsInFlight: { inFlight.withLock { $0 } },
            read: { _ in current.withLock { $0 } }))
        let stopped = expectation(description: "stopped for the update")
        watcher.start {
            fired.withLock { $0 += 1 }
            stopped.fulfill()
        }
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(fired.withLock { $0 }, 0, "fired with the original file in place")

        current.withLock { $0 = self.file(inode: 2) }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(fired.withLock { $0 }, 0, "fired with a tool call in flight")
        XCTAssertFalse(watcher.requestedRestart)

        inFlight.withLock { $0 = 0 }
        wait(for: [stopped], timeout: 5)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(fired.withLock { $0 }, 1)
        XCTAssertTrue(watcher.requestedRestart)
    }

    func testToolCallsCountWhileTheyRun() async throws {
        let (entered, enteredSink) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let held = fakeTool(named: "held") { _ in
            enteredSink.yield()
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    release.wait()
                    continuation.resume()
                }
            }
            return [.plainText("ok")]
        }
        let catalog = ToolCatalog([held])
        let before = ToolCallDispatch.callsInFlight.withLock { $0 }
        let call = Task {
            await ToolCallDispatch.execute(name: "held", arguments: nil, lane: .legacyStdio, catalog: catalog)
        }
        for await _ in entered { break }
        XCTAssertEqual(ToolCallDispatch.callsInFlight.withLock { $0 }, before + 1)
        release.signal()
        _ = await call.value
        XCTAssertEqual(ToolCallDispatch.callsInFlight.withLock { $0 }, before, "a finished call must not stay counted")
    }

    func testAnUpdateRelaunchesEvenWithKeepRunningOffButNotAfterAnUninstallStop() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent(ServiceDefaults.stayStoppedFileName))
        XCTAssertEqual(KeepRunning.exitCode(folder: folder), 0)
        XCTAssertEqual(KeepRunning.exitCode(folder: folder, updateInstalled: true), KeepRunning.relaunchExitCode)
        XCTAssertEqual(KeepRunning.exitCode(folder: folder, stopRequested: true, updateInstalled: true), 0)
    }

    func testTheExecutablePathIsThisProcessesResolvedPath() throws {
        let path = try XCTUnwrap(UpdateWatcher.executablePath())
        XCTAssertTrue(path.hasPrefix("/"), path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path), path)
        XCTAssertEqual(path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }
}

/// The helper cannot load a changed agent plist itself, so it says how to.
final class AgentDefinitionCheckTests: XCTestCase {
    private var root: URL!
    private let label = "com.example.imax-test.helper"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// An app bundle with a helper and a plist, and a support folder.
    private func install(plist: String, recorded: String?) throws -> (executable: String, support: URL) {
        let app = root.appendingPathComponent("Test Max.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        let agents = app.appendingPathComponent(ServiceDefaults.agentPlistDirectory)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent(ServiceDefaults.executableName)
        try Data().write(to: executable)
        try Data(plist.utf8).write(to: agents.appendingPathComponent("\(label).plist"))
        let support = root.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        if let recorded {
            try "\(recorded)\n".write(
                to: support.appendingPathComponent(ServiceDefaults.registeredAgentFileName), atomically: true, encoding: .utf8)
        }
        return (executable.path, support)
    }

    private func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func testTheRegisteredPlistSaysNothing() throws {
        let (executable, support) = try install(plist: "new", recorded: digest("new"))
        XCTAssertNil(AgentDefinitionCheck.staleRegistrationWarning(executablePath: executable, label: label, supportFolder: support))
    }

    func testAChangedPlistNamesTheAppAndTheCommand() throws {
        let (executable, support) = try install(plist: "new", recorded: digest("old"))
        let warning = try XCTUnwrap(AgentDefinitionCheck.staleRegistrationWarning(
            executablePath: executable, label: label, supportFolder: support))
        XCTAssertTrue(warning.contains("Open iMessage Max"), warning)
        XCTAssertTrue(warning.contains("open \"\(root.appendingPathComponent("Test Max.app").path)\" --args --register-helper"), warning)
    }

    func testNoRecordNoLabelOrNoAppSaysNothing() throws {
        let (executable, support) = try install(plist: "new", recorded: nil)
        XCTAssertNil(AgentDefinitionCheck.staleRegistrationWarning(executablePath: executable, label: label, supportFolder: support))
        let (_, recorded) = try install(plist: "new", recorded: digest("old"))
        XCTAssertNil(AgentDefinitionCheck.staleRegistrationWarning(executablePath: executable, label: nil, supportFolder: recorded))
        XCTAssertNil(AgentDefinitionCheck.staleRegistrationWarning(
            executablePath: "/usr/local/bin/imessage-max", label: label, supportFolder: recorded))
    }
}
