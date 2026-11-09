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

    let memory: AutomationMemory
    private let check: Check
    private let launch: Launch
    private let launchedForDiagnose = Mutex(false)

    init(
        memory: AutomationMemory,
        check: @escaping Check = { AutomationPermission.checkAutomationPermission(askUserIfNeeded: $0) },
        launch: @escaping Launch = { MessagesLauncher.ensureRunningHidden(reason: $0) }
    ) {
        self.memory = memory
        self.check = check
        self.launch = launch
    }

    /// For diagnose: never prompts. While Messages is closed it reports the
    /// remembered answer. With none, it starts Messages hidden once per
    /// helper to get one, so a poll never starts Messages again and again.
    func automationStatus() -> (ok: Bool, status: PermissionStatus) {
        var answer = check(false)
        if answer.status == .messagesNotRunning {
            if let remembered = memory.answer {
                return (remembered == .authorized, remembered)
            }
            let first = launchedForDiagnose.withLock { launched in
                defer { launched = true }
                return !launched
            }
            guard first, launch("the Automation check") else { return answer }
            answer = check(false)
        }
        memory.remember(answer.status)
        return answer
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

    /// Runs blocking work on a GCD thread. A wait for Messages to launch, for
    /// the user to answer a prompt, or for a script must not hold a
    /// cooperative-pool thread: GCD adds threads when its threads block, the
    /// cooperative pool does not, so a blocked thread there would stall
    /// unrelated requests across the whole service.
    static func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}
