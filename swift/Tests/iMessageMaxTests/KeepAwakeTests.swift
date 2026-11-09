import IMessageMaxContract
import IOKit.pwr_mgt
import Synchronization
import XCTest
@testable import iMessageMax

/// 088 finding #20: the opt-in Keep this Mac awake setting.
final class KeepAwakeTests: XCTestCase {
    private final class FakeAssertions: Sendable {
        let held = Mutex<Set<IOPMAssertionID>>([])
        let created = Mutex(0)
        let refuse = Mutex(false)

        var assertions: KeepAwake.Assertions {
            KeepAwake.Assertions(
                create: {
                    if self.refuse.withLock({ $0 }) { return nil }
                    let id = IOPMAssertionID(self.created.withLock { $0 += 1; return $0 })
                    self.held.withLock { _ = $0.insert(id) }
                    return id
                },
                release: { id in self.held.withLock { _ = $0.remove(id) } })
        }
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keep-awake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func marker(in folder: URL) -> URL {
        folder.appendingPathComponent(ServiceDefaults.keepAwakeFileName)
    }

    func testHoldsTheAssertionOnlyWhileTheFileExists() throws {
        let folder = try folder()
        let fake = FakeAssertions()
        let keeper = KeepAwake(folder: folder, assertions: fake.assertions, interval: .seconds(60))
        keeper.start()
        defer { keeper.stop() }

        XCTAssertEqual(keeper.refresh(), KeepAwake.State(requested: false, held: false))
        XCTAssertTrue(fake.held.withLock { $0.isEmpty })

        FileManager.default.createFile(atPath: marker(in: folder).path, contents: nil)
        XCTAssertEqual(keeper.refresh(), KeepAwake.State(requested: true, held: true))
        XCTAssertEqual(keeper.refresh(), KeepAwake.State(requested: true, held: true))
        XCTAssertEqual(fake.created.withLock { $0 }, 1, "one assertion, not one per check")

        try FileManager.default.removeItem(at: marker(in: folder))
        XCTAssertEqual(keeper.refresh(), KeepAwake.State(requested: false, held: false))
        XCTAssertTrue(fake.held.withLock { $0.isEmpty })
    }

    /// The timer applies a change with nobody calling diagnose, so toggling
    /// the setting needs no restart.
    func testTheTimerAppliesAChangeWithoutARestart() async throws {
        let folder = try folder()
        let fake = FakeAssertions()
        let keeper = KeepAwake(folder: folder, assertions: fake.assertions, interval: .milliseconds(50))
        keeper.start()
        defer { keeper.stop() }

        FileManager.default.createFile(atPath: marker(in: folder).path, contents: nil)
        let deadline = ContinuousClock.now + .seconds(3)
        while fake.held.withLock({ $0.isEmpty }), ContinuousClock.now < deadline {
            await AsyncTimeout.sleep(.milliseconds(20))
        }
        XCTAssertEqual(fake.held.withLock { $0.count }, 1)
    }

    func testStopReleasesTheAssertion() throws {
        let folder = try folder()
        FileManager.default.createFile(atPath: marker(in: folder).path, contents: nil)
        let fake = FakeAssertions()
        let keeper = KeepAwake(folder: folder, assertions: fake.assertions, interval: .seconds(60))
        keeper.start()
        XCTAssertEqual(fake.held.withLock { $0.count }, 1)
        keeper.stop()
        XCTAssertTrue(fake.held.withLock { $0.isEmpty })
    }

    /// A refused assertion is tried once per toggle, not every tick, and is
    /// reported as requested but not held.
    func testARefusedAssertionIsReportedAndNotRetriedEveryTick() throws {
        let folder = try folder()
        FileManager.default.createFile(atPath: marker(in: folder).path, contents: nil)
        let fake = FakeAssertions()
        fake.refuse.withLock { $0 = true }
        let keeper = KeepAwake(folder: folder, assertions: fake.assertions, interval: .seconds(60))
        keeper.start()
        defer { keeper.stop() }
        XCTAssertEqual(keeper.refresh(), KeepAwake.State(requested: true, held: false))
        fake.refuse.withLock { $0 = false }
        XCTAssertEqual(keeper.refresh(), KeepAwake.State(requested: true, held: false))

        try FileManager.default.removeItem(at: marker(in: folder))
        keeper.refresh()
        FileManager.default.createFile(atPath: marker(in: folder).path, contents: nil)
        XCTAssertEqual(keeper.refresh(), KeepAwake.State(requested: true, held: true))
    }

    /// macOS grants the real assertion to an unprivileged process.
    func testTheSystemAssertionIsCreatedAndReleased() throws {
        let id = try XCTUnwrap(KeepAwake.Assertions.system.create())
        KeepAwake.Assertions.system.release(id)
    }

    // MARK: - SleepSettings

    func testSleepSettingsReadTheProvidingPowerSource() {
        let preferences: [String: Any] = [
            "AC Power": ["System Sleep Timer": 0, "Display Sleep Timer": 5],
            "Battery Power": ["System Sleep Timer": 15],
        ]
        XCTAssertEqual(
            SleepSettings(activePreferences: preferences, systemSettings: ["SleepDisabled": 1], powerSource: "Battery Power"),
            SleepSettings(sleepMinutes: 15, sleepDisabled: true))
        XCTAssertEqual(
            SleepSettings(activePreferences: preferences, systemSettings: [:], powerSource: "AC Power"),
            SleepSettings(sleepMinutes: 0, sleepDisabled: nil))
        // An unknown source falls back to AC Power, the only profile on a desktop Mac.
        XCTAssertEqual(
            SleepSettings(activePreferences: preferences, systemSettings: nil, powerSource: nil).sleepMinutes, 0)
        XCTAssertEqual(SleepSettings(activePreferences: nil, systemSettings: nil, powerSource: nil), SleepSettings())
    }

    /// This Mac's own setting reads without crashing; pmset reads the same
    /// functions, so a Mac with power management reports minutes.
    func testCurrentSleepSettingsRead() {
        XCTAssertNotNil(SleepSettings.current().sleepMinutes)
    }
}
