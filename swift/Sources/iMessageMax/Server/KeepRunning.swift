import Darwin
import Foundation
import IMessageMaxContract
import Synchronization

/// The Keep running setting, as the HTTP helper applies it when it stops.
/// The agent plist relaunches the helper after any exit but a zero one, so
/// the exit code decides whether launchd starts it again. The companion's
/// Stop unloads the job instead, so it stays down whatever this says.
enum KeepRunning {
    /// EX_TEMPFAIL: non-zero, so launchd relaunches the helper, and a code
    /// that reads as "stopped, try again" rather than as a failure.
    static let relaunchExitCode = ServiceDefaults.relaunchExitCode

    /// Read as the helper stops, so a change applies without a restart.
    /// `folder` holds the token file, which keeps a test helper with
    /// `--token-file` away from the installed helper's setting. A stop asked
    /// for with `GracefulStop.signal` exits 0 whatever the setting says. A
    /// stop for an update (`UpdateWatcher`) relaunches whatever it says, so
    /// the new binary runs: the setting is about quits, not updates.
    static func exitCode(folder: URL, stopRequested: Bool = false, updateInstalled: Bool = false) -> Int32 {
        if stopRequested { return 0 }
        if updateInstalled { return relaunchExitCode }
        var info = stat()
        let stayStopped = lstat(folder.appendingPathComponent(ServiceDefaults.stayStoppedFileName).path, &info) == 0
        return stayStopped ? 0 : relaunchExitCode
    }
}

/// SIGUSR1 stops the helper for good: it drains as on SIGTERM, then exits 0
/// whatever Keep running says, so launchd leaves it down. The Homebrew cask's
/// `uninstall` sends it, because on SIGTERM a helper with Keep running on
/// exits 75 and launchd would relaunch it from the app brew just deleted.
///
/// A Dispatch signal source, not ServiceGroup's signal list, receives it, so
/// the exit code knows which signal stopped the helper. Create it before the
/// server starts: from then on the signal no longer kills the process, and
/// one that arrives before `onStop` is set runs the action as soon as it is.
final class GracefulStop: @unchecked Sendable {
    static let signal = SIGUSR1

    private struct State {
        var received = false
        var action: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())
    private let source: any DispatchSourceSignal

    init() {
        Darwin.signal(Self.signal, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: Self.signal, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in self?.receive() }
        source.resume()
    }

    deinit { source.cancel() }

    var wasRequested: Bool { state.withLock { $0.received } }

    func onStop(_ action: @escaping @Sendable () -> Void) {
        let received = state.withLock { state in
            state.action = action
            return state.received
        }
        if received { action() }
    }

    private func receive() {
        let action: (@Sendable () -> Void)? = state.withLock { state in
            guard !state.received else { return nil }
            state.received = true
            return state.action
        }
        Log.info("Received SIGUSR1; stopping without a relaunch")
        action?()
    }
}
