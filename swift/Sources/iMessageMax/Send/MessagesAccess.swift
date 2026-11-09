import Foundation
import IMessageMaxContract
import Synchronization

/// The helper's one way to Messages: diagnose, the setup request and every
/// AppleScript go through here, so none of them needs the user to open
/// Messages and none of them shows its window.
final class MessagesAccess: Sendable {
    typealias Check = @Sendable (_ askUserIfNeeded: Bool) -> (ok: Bool, status: PermissionStatus)
    /// Starts Messages hidden and returns once it answers Apple events.
    /// The argument is the reason, for the log.
    typealias Launch = @Sendable (_ reason: String) -> Bool
    typealias Clock = @Sendable () -> ContinuousClock.Instant

    /// How often diagnose may start Messages to ask macOS again while
    /// Messages is closed: when nothing is remembered, when the remembered
    /// answer is not `authorized`, or when the last start failed.
    static let recheckInterval: Duration = .seconds(300)

    let memory: AutomationMemory
    private let check: Check
    private let launch: Launch
    private let now: Clock
    private let recheckInterval: Duration
    /// When diagnose last started Messages to ask, whether or not it started.
    private let lastDiagnoseLaunch = Mutex<ContinuousClock.Instant?>(nil)

    init(
        memory: AutomationMemory,
        check: @escaping Check = { AutomationPermission.checkAutomationPermission(askUserIfNeeded: $0) },
        launch: @escaping Launch = { MessagesLauncher.ensureRunningHidden(reason: $0) },
        recheckInterval: Duration = MessagesAccess.recheckInterval,
        now: @escaping Clock = { ContinuousClock.now }
    ) {
        self.memory = memory
        self.check = check
        self.launch = launch
        self.recheckInterval = recheckInterval
        self.now = now
    }

    /// For diagnose: never prompts. While Messages is closed it reports the
    /// remembered answer. When that answer is anything but `authorized`, or
    /// there is none, it starts Messages hidden to ask again, at most once per
    /// `recheckInterval`, so a poll never starts Messages again and again and
    /// a grant made in System Settings while Messages is closed still shows.
    func automationStatus() -> (ok: Bool, status: PermissionStatus) {
        var answer = check(false)
        if answer.status == .messagesNotRunning {
            let remembered = memory.answer
            if remembered == .authorized { return (true, .authorized) }
            let fallback = remembered.map { (false, $0) } ?? answer
            guard claimDiagnoseLaunch(), launch("the Automation check") else { return fallback }
            answer = check(false)
        }
        memory.remember(answer.status)
        return answer
    }

    private func claimDiagnoseLaunch() -> Bool {
        let current = now()
        return lastDiagnoseLaunch.withLock { last in
            if let last, current - last < recheckInterval { return false }
            last = current
            return true
        }
    }

    /// For the companion's setup request: may show the macOS prompt.
    func requestAutomation() -> (ok: Bool, status: PermissionStatus) {
        _ = launch("the Automation request")
        let answer = check(true)
        memory.remember(answer.status)
        return answer
    }

    /// Before any AppleScript that tells Messages something. If Messages
    /// cannot start hidden, the script still runs and starts it the normal way.
    func prepareForScript() {
        _ = launch("a send")
    }

    /// Before a send's first script: starts Messages hidden, then asks macOS
    /// about Automation without prompting. A send must never wait on a consent
    /// prompt, because on a headless Mac nobody can answer it, and osascript
    /// would block until its timeout and leave the outcome unknown. Returns
    /// the error that stops the send before anything reaches Messages, or nil
    /// when the script may run. When macOS cannot answer (Messages did not
    /// start, or an unmapped status) the script runs and reports for itself.
    func prepareForSend() -> SendError? {
        prepareForScript()
        let answer = check(false)
        memory.remember(answer.status)
        switch answer.status {
        case .denied, .notDetermined:
            Log.warning("Send not started: Automation for Messages is \(answer.status.rawValue)")
            return .automationPermissionRequired
        case .messagesNotResponding:
            Log.warning("Send not started: Messages did not answer the Automation check")
            return .messagesAppUnavailable
        default:
            return nil
        }
    }

    /// A script Messages ran proves access, and one refused with
    /// errAEEventNotPermitted (-1743) proves the opposite.
    func noteScriptOutcome(_ result: Result<Void, SendFailure>) {
        switch result {
        case .success:
            memory.remember(.authorized)
        case .failure(let failure):
            if case .automationPermissionRequired = failure.error { memory.remember(.denied) }
        }
    }

    /// Runs blocking work on a thread of its own. A wait for Messages to
    /// launch, for the user to answer a prompt, or for a script must not hold
    /// a cooperative-pool thread, which would stall unrelated requests across
    /// the whole service. It must not hold a GCD worker either: many sends at
    /// once would each park a worker on the osascript gate, and the pool's
    /// thread limit would then starve the pipe readers and exit handlers the
    /// running scripts need, which turns into false timeouts.
    static func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: work())
            }
            thread.name = "imessage-max.messages"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }
}
