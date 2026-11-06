import AppKit
import IMessageMaxContract

typealias AutomationProbe = @Sendable () -> (ok: Bool, status: PermissionStatus)

enum AutomationPermission {
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
