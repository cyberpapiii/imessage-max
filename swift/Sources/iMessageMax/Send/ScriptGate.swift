import Foundation

/// Bounds how many osascript processes run at once. Messages handles Apple
/// events one at a time anyway, so more scripts in parallel only add
/// processes, pipe readers and threads. Unbounded, a burst of sends exhausted
/// GCD's threads and scripts that had finished were reported as timeouts.
///
/// A script's own 30 s timeout starts when it gets a slot, never while it
/// waits for one, so a queue of quick scripts does not turn into false
/// timeouts. A script that waits longer than `waitLimit` for a slot never
/// runs and fails as `messagesAppUnavailable`, which the send reports as not
/// started.
final class ScriptGate: Sendable {
    static let shared = ScriptGate(slots: 4, waitLimit: .seconds(60))

    private let slots: DispatchSemaphore
    private let waitLimit: DispatchTimeInterval
    private let execute: ScriptExecutor

    init(
        slots: Int,
        waitLimit: DispatchTimeInterval,
        execute: @escaping ScriptExecutor = { Osascript.run($0, arguments: $1) }
    ) {
        self.slots = DispatchSemaphore(value: slots)
        self.waitLimit = waitLimit
        self.execute = execute
    }

    func run(_ script: String, arguments: [String]) -> Result<Osascript.Output, SendError> {
        guard slots.wait(timeout: .now() + waitLimit) == .success else {
            Log.warning("AppleScript not run: no free slot within the wait limit, earlier scripts are still running")
            return .failure(.messagesAppUnavailable)
        }
        defer { slots.signal() }
        return execute(script, arguments)
    }
}
