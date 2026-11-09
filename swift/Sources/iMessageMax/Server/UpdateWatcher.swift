import CryptoKit
import Darwin
import Foundation
import IMessageMaxContract
import MachO
import Synchronization

/// The file at a path, as `stat` sees it. An update that replaces the file,
/// as `brew upgrade`, `ditto` over a removed bundle or `make install` do,
/// gives it a new inode. Equal values mean nothing about the file changed,
/// so a copy still being written does not look settled.
struct ExecutableFile: Equatable, Sendable {
    var device: Int32
    var inode: UInt64
    var size: Int64
    var modified: timespec
    var changed: timespec

    init(device: Int32, inode: UInt64, size: Int64, modified: timespec, changed: timespec) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modified = modified
        self.changed = changed
    }

    /// nil when nothing is at `path`, as midway through an update that
    /// removes the bundle before copying the new one.
    static func read(_ path: String) -> ExecutableFile? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return ExecutableFile(
            device: info.st_dev, inode: info.st_ino, size: info.st_size,
            modified: info.st_mtimespec, changed: info.st_ctimespec)
    }

    func isSameFile(as other: ExecutableFile) -> Bool {
        device == other.device && inode == other.inode
    }

    static func == (lhs: ExecutableFile, rhs: ExecutableFile) -> Bool {
        lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
            && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
            && lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
    }
}

/// Decides when a helper whose executable was replaced on disk stops, so
/// launchd starts the new one (088 #19). Pure: the watcher feeds it what it
/// reads on each tick.
///
/// A new file must look the same on two ticks in a row before it counts,
/// so a copy still being written is not launched half done. Then the helper
/// waits for no tool call to be in flight, up to `idleWait`, and stops.
struct ExecutableReplacement: Sendable {
    enum Decision: Equatable, Sendable {
        /// The file is the one this process started from, or none is there.
        case unchanged
        /// A new file appeared and may still be being written.
        case settling
        /// The new file is complete, and tool calls are in flight.
        case waitingForIdle(calls: Int)
        /// Stop now. `idle` false means the wait ran out with calls in flight.
        case restart(idle: Bool)

        var isWaitingForIdle: Bool {
            if case .waitingForIdle = self { true } else { false }
        }
    }

    let original: ExecutableFile
    let idleWait: TimeInterval
    private var candidate: ExecutableFile?
    private var replacedAt: TimeInterval?

    init(original: ExecutableFile, idleWait: TimeInterval) {
        self.original = original
        self.idleWait = idleWait
    }

    /// When the new file was first seen complete, in the caller's clock.
    var replacementSeen: TimeInterval? { replacedAt }

    mutating func observe(_ current: ExecutableFile?, callsInFlight: Int, now: TimeInterval) -> Decision {
        // Only a new file counts. A chmod or an extended attribute changes
        // the original's ctime, and a write in place makes macOS kill the
        // process anyway.
        guard let current, !current.isSameFile(as: original) else {
            candidate = nil
            replacedAt = nil
            return .unchanged
        }
        guard current == candidate else {
            candidate = current
            replacedAt = nil
            return .settling
        }
        let since = replacedAt ?? now
        replacedAt = since
        if callsInFlight <= 0 { return .restart(idle: true) }
        if now - since >= idleWait { return .restart(idle: false) }
        return .waitingForIdle(calls: callsInFlight)
    }
}

/// Watches the helper's own executable with a Dispatch timer (no Task.sleep
/// in the service, see AGENTS.md) and calls `onReplaced` once, when an
/// update has replaced it and the helper is idle. The caller then drains as
/// on SIGTERM and exits with `KeepRunning.relaunchExitCode`, so launchd
/// starts the new binary whether or not the companion is running.
final class UpdateWatcher: @unchecked Sendable {
    struct Timing: Sendable {
        /// Between reads of the executable while it is unchanged.
        var interval: TimeInterval = 5
        /// Between checks for idle once a replacement is complete.
        var idlePoll: TimeInterval = 1
        /// The longest a replacement waits for in-flight calls to finish.
        /// Past it the helper stops anyway and the drain bounds the rest.
        var idleWait: TimeInterval = 120
    }

    let path: String
    private let timing: Timing
    private let callsInFlight: @Sendable () -> Int
    private let read: @Sendable (String) -> ExecutableFile?
    private let queue = DispatchQueue(label: "imessage-max.update-watcher", qos: .utility)
    private let state: Mutex<State>

    private struct State {
        var replacement: ExecutableReplacement
        var timer: (any DispatchSourceTimer)?
        var onReplaced: (@Sendable () -> Void)?
        var fired = false
        var lastDecision: ExecutableReplacement.Decision = .unchanged
    }

    /// nil when the executable cannot be read now.
    init?(
        path: String, timing: Timing = Timing(),
        callsInFlight: @escaping @Sendable () -> Int = { ToolCallDispatch.callsInFlight.withLock { $0 } },
        read: @escaping @Sendable (String) -> ExecutableFile? = ExecutableFile.read
    ) {
        guard let original = read(path) else { return nil }
        self.path = path
        self.timing = timing
        self.callsInFlight = callsInFlight
        self.read = read
        state = Mutex(State(replacement: ExecutableReplacement(original: original, idleWait: timing.idleWait)))
    }

    /// The watcher for this process's executable, nil when its path cannot
    /// be found or read.
    static func forThisProcess() -> UpdateWatcher? {
        guard let path = executablePath() else { return nil }
        return UpdateWatcher(path: path)
    }

    /// Whether the watcher asked the helper to stop for an update.
    var requestedRestart: Bool { state.withLock { $0.fired } }

    func start(onReplaced: @escaping @Sendable () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.tick() }
        state.withLock { state in
            state.onReplaced = onReplaced
            state.timer?.cancel()
            state.timer = timer
        }
        schedule(timer, every: timing.interval)
        timer.resume()
    }

    func stop() {
        state.withLock { state in
            state.timer?.cancel()
            state.timer = nil
        }
    }

    deinit { state.withLock { $0.timer?.cancel() } }

    private func schedule(_ timer: any DispatchSourceTimer, every seconds: TimeInterval) {
        let interval = DispatchTimeInterval.milliseconds(Int(seconds * 1000))
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(seconds * 100)))
    }

    private func tick() {
        let current = read(path)
        let calls = callsInFlight()
        let now = ProcessInfo.processInfo.systemUptime
        let (decision, previous, action, timer) = state.withLock { state in
            let previous = state.lastDecision
            let decision = state.replacement.observe(current, callsInFlight: calls, now: now)
            state.lastDecision = decision
            var action: (@Sendable () -> Void)?
            if case .restart = decision, !state.fired {
                state.fired = true
                action = state.onReplaced
                state.timer?.cancel()
                state.timer = nil
            }
            return (decision, previous, action, state.timer)
        }
        switch decision {
        case .unchanged:
            break
        case .settling:
            if previous == .unchanged { Log.info("Executable replaced on disk at \(path); waiting for the copy to finish") }
        case .waitingForIdle(let calls):
            if !previous.isWaitingForIdle {
                Log.info("Update installed; restarting on the new binary when \(calls) tool call(s) finish (at most \(Int(timing.idleWait)) s)")
            }
        case .restart(let idle):
            Log.info(idle
                ? "Update installed; stopping so launchd starts the new binary"
                : "Update installed; tool calls still running after \(Int(timing.idleWait)) s, stopping anyway so launchd starts the new binary")
            action?()
            return
        }
        // Poll for idle quickly once the new file is complete, and slowly otherwise.
        if let timer, decision.isWaitingForIdle != previous.isWaitingForIdle {
            schedule(timer, every: decision.isWaitingForIdle ? timing.idlePoll : timing.interval)
        }
    }

    /// This process's executable, with symlinks resolved. argv[0] is the
    /// bare name launchd passes from ProgramArguments, so it cannot say.
    static func executablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        guard let resolved = realpath(buffer, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// The agent plist an update bundles can differ from the one launchd holds:
/// SMAppService keeps a registered job on the plist it first loaded, and
/// only an unregister and a register load the new one. That takes the app,
/// which records the plist it registered (`registered-agent.sha256`), so the
/// helper only compares and says what to do (088 #19).
enum AgentDefinitionCheck {
    /// The warning to log at startup, or nil when the plist launchd holds is
    /// the one the app bundles, or either cannot be read: a helper outside an
    /// app bundle, one not started by launchd, or an app that never recorded
    /// a registration.
    static func staleRegistrationWarning(
        executablePath: String, label: String?, supportFolder: URL
    ) -> String? {
        guard let label, !label.isEmpty,
            let app = appBundle(containing: executablePath)
        else { return nil }
        let plist = app.appendingPathComponent(ServiceDefaults.agentPlistDirectory)
            .appendingPathComponent("\(label).plist")
        let record = supportFolder.appendingPathComponent(ServiceDefaults.registeredAgentFileName)
        guard let bundled = try? Data(contentsOf: plist),
            let recorded = try? String(contentsOf: record, encoding: .utf8)
        else { return nil }
        let digest = SHA256.hash(data: bundled).map { String(format: "%02x", $0) }.joined()
        guard recorded.trimmingCharacters(in: .whitespacesAndNewlines) != digest else { return nil }
        return "This update changed the helper's launchd plist, and launchd still runs the helper "
            + "under the old one. Open iMessage Max, or run: open \"\(app.path)\" --args --register-helper"
    }

    /// The `.app` folder whose `Contents/MacOS` holds `executablePath`.
    static func appBundle(containing executablePath: String) -> URL? {
        let macOS = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
            app.pathExtension == "app"
        else { return nil }
        return app
    }
}
