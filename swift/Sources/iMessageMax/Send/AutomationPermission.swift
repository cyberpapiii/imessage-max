import AppKit
import IMessageMaxContract
import Synchronization

typealias AutomationProbe = @Sendable () async -> (ok: Bool, status: PermissionStatus)

enum AutomationPermission {
    /// How long a probe that never asks may take. A running Messages answers
    /// in milliseconds; a hung one never does.
    static let probeTimeout: DispatchTimeInterval = .seconds(2)

    /// Every probe that never asks goes through here, so a hung Messages
    /// holds at most one thread however often diagnose and sends ask.
    static let boundedProbe = BoundedProbe(timeout: probeTimeout) { rawStatus(askUserIfNeeded: false) }

    /// With `askUserIfNeeded` false the probe is bounded, and a Messages that
    /// does not answer in time reports `messagesNotResponding`. A probe that
    /// may prompt waits for the user, so it has no bound.
    static func checkAutomationPermission(askUserIfNeeded: Bool = false) -> (ok: Bool, status: PermissionStatus) {
        guard !askUserIfNeeded else { return status(for: rawStatus(askUserIfNeeded: true)) }
        guard let raw = boundedProbe.run() else { return (false, .messagesNotResponding) }
        return status(for: raw)
    }

    static func rawStatus(askUserIfNeeded: Bool) -> OSStatus {
        guard let bundleIDData = MessagesLauncher.bundleID.data(using: .utf8) else {
            return OSStatus(procNotFound)
        }
        var targetDesc = AEDesc()
        let createErr: OSErr = bundleIDData.withUnsafeBytes { bytes in
            AECreateDesc(typeApplicationBundleID, bytes.baseAddress, bytes.count, &targetDesc)
        }
        guard createErr == noErr else {
            return OSStatus(createErr)
        }
        defer { AEDisposeDesc(&targetDesc) }
        return AEDeterminePermissionToAutomateTarget(
            &targetDesc,
            typeWildCard,
            typeWildCard,
            askUserIfNeeded
        )
    }

    static func status(for permStatus: OSStatus) -> (ok: Bool, status: PermissionStatus) {
        switch permStatus {
        case noErr:
            return (true, .authorized)
        case OSStatus(errAEEventNotPermitted):
            return (false, .denied)
        case OSStatus(procNotFound):
            return (false, .messagesNotRunning)
        case OSStatus(errAEEventWouldRequireUserConsent):
            return (false, .notDetermined)
        default:
            return (false, .checkFailed(permStatus))
        }
    }
}

/// Runs a blocking probe on its own thread and waits at most `timeout` for
/// it. `AEDeterminePermissionToAutomateTarget` has no time limit, and against
/// a Messages that is running but hung it blocks until Messages answers,
/// which may be never.
///
/// Only one probe runs at a time. A caller waits for the one in flight, and
/// the wait counts against its own timeout, so while a probe is stuck every
/// caller gives up after `timeout` and no second thread is started. The probe
/// thread frees the slot when the probe returns, whoever still waits for it.
final class BoundedProbe: Sendable {
    private let slot = DispatchSemaphore(value: 1)
    private let timeout: DispatchTimeInterval
    private let probe: @Sendable () -> OSStatus

    init(timeout: DispatchTimeInterval, probe: @escaping @Sendable () -> OSStatus) {
        self.timeout = timeout
        self.probe = probe
    }

    /// The probe's answer, or nil when it did not answer in time.
    func run() -> OSStatus? {
        let deadline = DispatchTime.now() + timeout
        guard slot.wait(timeout: deadline) == .success else { return nil }
        let answer = Answer()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread { [slot, probe] in
            let status = probe()
            answer.value.withLock { $0 = status }
            slot.signal()
            done.signal()
        }
        thread.name = "imessage-max.automation-probe"
        thread.start()
        guard done.wait(timeout: deadline) == .success else { return nil }
        return answer.value.withLock { $0 }
    }

    private final class Answer: Sendable {
        let value = Mutex<OSStatus?>(nil)
    }
}
