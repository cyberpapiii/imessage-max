import AppKit
import Synchronization

/// Starts Messages without showing it. macOS answers an Automation check
/// only while Messages runs, and an AppleScript `tell application "Messages"`
/// starts it the normal way, with its window. Launched with `hides`, Messages
/// runs with no window on screen and focus stays where it was, so the user
/// never has to open Messages for iMessage Max.
enum MessagesLauncher {
    static let bundleID = "com.apple.MobileSMS"

    /// Messages answers Apple events about 0.4 s after launch on an M-series
    /// Mac. The bound only matters when something is wrong.
    static let readyTimeout: TimeInterval = 10
    private static let pollInterval: TimeInterval = 0.1

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Returns once Messages answers Apple events: true when it does, false
    /// when it is missing, failed to launch, or did not answer in time.
    /// Blocks its thread, so call it off the cooperative pool. `reason` goes
    /// to the log.
    ///
    /// Each probe is bounded (`AutomationPermission.boundedProbe`). A Messages
    /// that was already running and lets a probe time out is hung, and this
    /// returns false at once instead of waiting out `timeout`. One that is
    /// still starting gets until the deadline.
    static func ensureRunningHidden(
        reason: String,
        timeout: TimeInterval = readyTimeout,
        probe: () -> OSStatus? = { AutomationPermission.boundedProbe.run() }
    ) -> Bool {
        let launchError = Mutex<String?>(nil)
        let wasRunning = isRunning
        if !wasRunning {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                Log.warning("Messages is missing from this Mac; cannot start it for \(reason)")
                return false
            }
            Log.info("Starting Messages hidden for \(reason)")
            NSWorkspace.shared.openApplication(at: url, configuration: hiddenConfiguration()) { _, error in
                if let error { launchError.withLock { $0 = error.localizedDescription } }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            switch probe() {
            case .none where wasRunning:
                Log.warning("Messages is running but did not answer within 2 s for \(reason)")
                return false
            case .none, .some(OSStatus(procNotFound)):
                break
            case .some:
                return true
            }
            if let error = launchError.withLock({ $0 }) {
                Log.warning("Messages did not start for \(reason): \(error)")
                return false
            }
            if Date() >= deadline {
                Log.warning("Messages did not answer within \(Int(timeout)) s for \(reason)")
                return false
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    static func hiddenConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        return configuration
    }
}
