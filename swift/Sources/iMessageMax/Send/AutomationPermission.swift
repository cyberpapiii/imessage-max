import AppKit
import IMessageMaxContract

/// Closure type for automation permission probes.
/// Using a typealias allows tests to inject mock probes instead of calling the real TCC check.
/// CI runners report "not_determined" so tests MUST inject rather than call the real probe.
typealias AutomationProbe = @Sendable () -> (ok: Bool, status: PermissionStatus)

enum AutomationPermission {
    /// Check whether this process has Automation permission to drive Messages.app,
    /// using AEDeterminePermissionToAutomateTarget against "com.apple.MobileSMS".
    ///
    /// This is a non-prompting read-only TCC check (askUserIfNeeded: false).
    /// Explicit setup requests opt in to prompting; ordinary diagnose calls do not.
    static func checkAutomationPermission(askUserIfNeeded: Bool = false) -> (ok: Bool, status: PermissionStatus) {
        guard let bundleIDData = "com.apple.MobileSMS".data(using: .utf8) else {
            return (false, .messagesNotFound)
        }
        var targetDesc = AEDesc()
        let createErr: OSErr = bundleIDData.withUnsafeBytes { bytes in
            AECreateDesc(typeApplicationBundleID, bytes.baseAddress, bytes.count, &targetDesc)
        }
        guard createErr == noErr else {
            return (false, .messagesNotFound)
        }
        defer { AEDisposeDesc(&targetDesc) }
        let permStatus = AEDeterminePermissionToAutomateTarget(
            &targetDesc,
            typeWildCard,
            typeWildCard,
            askUserIfNeeded
        )
        return status(for: permStatus)
    }

    @concurrent
    static func requestAccess() async -> (ok: Bool, status: PermissionStatus) {
        checkAutomationPermission(askUserIfNeeded: true)
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
