import Darwin
import Foundation
import IMessageMaxContract
import IOKit.ps
import IOKit.pwr_mgt

/// The Keep this Mac awake setting, as the HTTP helper applies it. While the
/// `keep-awake` file exists beside the token file, the helper holds a
/// PreventUserIdleSystemSleep assertion, so the Mac does not sleep while
/// idle. The display may still sleep. A Dispatch timer checks the file, so
/// turning the setting on or off needs no restart.
final class KeepAwake: @unchecked Sendable {
    struct State: Equatable, Sendable {
        /// The setting is on.
        var requested = false
        /// The helper holds its assertion now.
        var held = false
    }

    /// Creates and releases the power assertion. Tests replace it.
    struct Assertions: Sendable {
        var create: @Sendable () -> IOPMAssertionID?
        var release: @Sendable (IOPMAssertionID) -> Void

        static let system = Assertions(
            create: {
                var id = IOPMAssertionID(0)
                let result = IOPMAssertionCreateWithName(
                    kIOPMAssertPreventUserIdleSystemSleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    "iMessage Max: Keep this Mac awake" as CFString,
                    &id)
                return result == kIOReturnSuccess ? id : nil
            },
            release: { _ = IOPMAssertionRelease($0) })
    }

    static let interval: DispatchTimeInterval = .seconds(5)

    private let marker: String
    private let assertions: Assertions
    private let interval: DispatchTimeInterval
    private let queue = DispatchQueue(label: "imessage-max.keep-awake")
    // Confined to `queue`.
    private var assertion: IOPMAssertionID?
    private var requested = false
    private var createFailed = false
    private var timer: DispatchSourceTimer?

    /// `folder` holds the token file, like the stay-stopped file.
    init(folder: URL, assertions: Assertions = .system, interval: DispatchTimeInterval = KeepAwake.interval) {
        marker = folder.appendingPathComponent(ServiceDefaults.keepAwakeFileName).path
        self.assertions = assertions
        self.interval = interval
    }

    deinit {
        timer?.cancel()
        if let assertion { assertions.release(assertion) }
    }

    func start() {
        queue.sync {
            applyLocked()
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.applyLocked() }
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            releaseLocked()
            requested = false
        }
    }

    /// Reads the file now, applies it, and returns the result, so diagnose
    /// reports the setting as it is, not as of the last tick.
    @discardableResult
    func refresh() -> State {
        queue.sync {
            applyLocked()
            return State(requested: requested, held: assertion != nil)
        }
    }

    private func applyLocked() {
        var info = stat()
        let on = lstat(marker, &info) == 0
        if on != requested { createFailed = false }
        requested = on
        if on, assertion == nil, !createFailed {
            if let id = assertions.create() {
                assertion = id
                Log.info("Keep this Mac awake is on: holding a PreventUserIdleSystemSleep assertion")
            } else {
                createFailed = true
                Log.warning("Keep this Mac awake is on, but macOS refused the power assertion")
            }
        } else if !on, assertion != nil {
            releaseLocked()
            Log.info("Keep this Mac awake is off: released the power assertion")
        }
    }

    private func releaseLocked() {
        if let assertion { assertions.release(assertion) }
        assertion = nil
    }
}

/// The system sleep setting, as `pmset -g` shows it.
struct SleepSettings: Equatable, Sendable {
    /// Minutes of inactivity before system sleep on the current power
    /// source; 0 means never. nil when macOS did not say.
    var sleepMinutes: Int?
    /// `pmset disablesleep 1`.
    var sleepDisabled: Bool?

    /// Reads IOKit's power preferences. The two copy functions are what
    /// pmset reads; IOKit exports them but the SDK does not declare them, so
    /// they are looked up at run time and a missing one reads as unknown.
    static func current() -> SleepSettings {
        typealias Copy = @convention(c) () -> Unmanaged<CFDictionary>?
        func copy(_ name: String) -> [String: Any]? {
            guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
            return unsafeBitCast(symbol, to: Copy.self)()?.takeRetainedValue() as? [String: Any]
        }
        let source = IOPSCopyPowerSourcesInfo()
            .flatMap { IOPSGetProvidingPowerSourceType($0.takeRetainedValue())?.takeUnretainedValue() as String? }
        return SleepSettings(
            activePreferences: copy("IOPMCopyActivePMPreferences"),
            systemSettings: copy("IOPMCopySystemPowerSettings"),
            powerSource: source)
    }

    init(sleepMinutes: Int? = nil, sleepDisabled: Bool? = nil) {
        self.sleepMinutes = sleepMinutes
        self.sleepDisabled = sleepDisabled
    }

    /// `activePreferences` is keyed by power source ("AC Power", "Battery
    /// Power", "UPS Power"); the providing source's entry applies.
    init(activePreferences: [String: Any]?, systemSettings: [String: Any]?, powerSource: String?) {
        let profiles = activePreferences ?? [:]
        let profile =
            (powerSource.flatMap { profiles[$0] } ?? profiles[kIOPMACPowerKey]) as? [String: Any]
        sleepMinutes = (profile?["System Sleep Timer"] as? NSNumber)?.intValue
        sleepDisabled = (systemSettings?["SleepDisabled"] as? NSNumber)?.boolValue
    }
}
