// Sources/iMessageMax/Utilities/AutomationPermission.swift
import AppKit

/// Closure type for automation permission probes.
/// Using a typealias allows tests to inject mock probes instead of calling the real TCC check.
/// CI runners report "not_determined" so tests MUST inject rather than call the real probe.
typealias AutomationProbe = @Sendable () -> (ok: Bool, status: String)

enum AutomationPermission {
    /// Check whether this process has Automation permission to drive Messages.app,
    /// using AEDeterminePermissionToAutomateTarget against "com.apple.MobileSMS".
    ///
    /// This is a non-prompting read-only TCC check (askUserIfNeeded: false).
    /// Returns:
    ///   - (true, "authorized")      — permission is granted
    ///   - (false, "denied")         — TCC explicitly denied (errAEEventNotPermitted)
    ///   - (false, "not_determined") — TCC entry not yet established
    ///   - (false, "messages_not_found") — descriptor could not be created
    static func checkAutomationPermission() -> (ok: Bool, status: String) {
        guard let bundleIDData = "com.apple.MobileSMS".data(using: .utf8) else {
            return (false, "messages_not_found")
        }
        var targetDesc = AEDesc()
        let createErr: OSErr = bundleIDData.withUnsafeBytes { bytes in
            AECreateDesc(typeApplicationBundleID, bytes.baseAddress, bytes.count, &targetDesc)
        }
        guard createErr == noErr else {
            return (false, "messages_not_found")
        }
        defer { AEDisposeDesc(&targetDesc) }
        let permStatus = AEDeterminePermissionToAutomateTarget(
            &targetDesc,
            typeWildCard,
            typeWildCard,
            false
        )
        switch permStatus {
        case noErr:
            return (true, "authorized")
        case OSStatus(errAEEventNotPermitted):
            return (false, "denied")
        default:
            return (false, "not_determined")
        }
    }
}
