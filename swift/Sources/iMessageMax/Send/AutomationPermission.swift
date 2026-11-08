import AppKit
import IMessageMaxContract

typealias AutomationProbe = @Sendable () async -> (ok: Bool, status: PermissionStatus)

enum AutomationPermission {
    static func checkAutomationPermission(askUserIfNeeded: Bool = false) -> (ok: Bool, status: PermissionStatus) {
        status(for: rawStatus(askUserIfNeeded: askUserIfNeeded))
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
