import Darwin
import Foundation
import IMessageMaxContract

/// The Keep running setting, as the HTTP helper applies it when it stops.
/// The agent plist relaunches the helper after any exit but a zero one, so
/// the exit code decides whether launchd starts it again. The companion's
/// Stop unloads the job instead, so it stays down whatever this says.
enum KeepRunning {
    /// EX_TEMPFAIL: non-zero, so launchd relaunches the helper, and a code
    /// that reads as "stopped, try again" rather than as a failure.
    static let relaunchExitCode: Int32 = 75

    /// Read as the helper stops, so a change applies without a restart.
    /// `folder` holds the token file, which keeps a test helper with
    /// `--token-file` away from the installed helper's setting.
    static func exitCode(folder: URL) -> Int32 {
        var info = stat()
        let stayStopped = lstat(folder.appendingPathComponent(ServiceDefaults.stayStoppedFileName).path, &info) == 0
        return stayStopped ? 0 : relaunchExitCode
    }
}
