import Foundation
import Synchronization

enum AsyncTimeout {
    /// Dispatch-backed sleep. NEVER sleep Swift tasks inside the launchd service
    /// (sleeping unstructured tasks abort in swift_task_dealloc at wakeup;
    /// PendingRequestRegistry.store has the other known-good timer pattern).
    static func sleep(_ duration: Duration) async {
        await sleep(duration, gate: ResumeGate())
    }

    static func sleep(_ duration: Duration, gate: ResumeGate) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // A timer source, not asyncAfter: cancelling a source releases
                // its handler at once, while a cancelled asyncAfter item stays
                // enqueued, with everything it captured, until its deadline.
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                timer.setEventHandler {
                    gate.resume()
                }
                timer.schedule(deadline: .now() + dispatchInterval(for: duration))
                guard gate.arm(timer: timer, continuation: continuation) else {
                    // Releasing a never-activated source traps in libdispatch,
                    // so cancel it and activate it; it never fires.
                    timer.cancel()
                    timer.activate()
                    return
                }
                timer.resume()
            }
        } onCancel: {
            gate.cancelAndResume()
        }
    }

    static func dispatchInterval(for duration: Duration) -> DispatchTimeInterval {
        .nanoseconds(nanoseconds(for: duration))
    }

    static func nanoseconds(for duration: Duration) -> Int {
        let components = duration.components
        let maxWholeSeconds = Int64(Int.max / 1_000_000_000)
        let clampedSeconds = max(0, min(components.seconds, maxWholeSeconds))
        let secondNanoseconds = Int(clampedSeconds) * 1_000_000_000
        let fractionalNanoseconds = max(0, Int(components.attoseconds / 1_000_000_000))
        return secondNanoseconds > Int.max - fractionalNanoseconds
            ? Int.max
            : secondNanoseconds + fractionalNanoseconds
    }

    /// Invariant: `resumed` is true only after a continuation has actually
    /// been resumed. `withTaskCancellationHandler` runs `onCancel` before the
    /// body when the task is already cancelled on entry, so `cancelAndResume`
    /// can run before `arm`; it must not claim the resume in that case, or the
    /// continuation that `arm` later delivers is never resumed.
    final class ResumeGate: @unchecked Sendable {
        private let state = Mutex(())
        private var timer: DispatchSourceTimer?
        private var continuation: CheckedContinuation<Void, Never>?
        private var resumed = false
        private var cancelled = false
        private var timerStarted = false

        var startedTimer: Bool {
            state.withLock { _ in timerStarted }
        }

        func arm(timer: DispatchSourceTimer, continuation: CheckedContinuation<Void, Never>) -> Bool {
            state.withLock { _ in
                if cancelled || resumed {
                    if !resumed {
                        resumed = true
                        continuation.resume()
                    }
                    return false
                }
                self.timer = timer
                self.continuation = continuation
                timerStarted = true
                return true
            }
        }

        func resume() {
            finish(cancelling: false)
        }

        func cancelAndResume() {
            finish(cancelling: true)
        }

        private func finish(cancelling: Bool) {
            let (timer, cont) = state.withLock { _ in
                if cancelling { cancelled = true }
                let cont = resumed ? nil : continuation
                if cont != nil { resumed = true }
                let timer = self.timer
                self.timer = nil
                self.continuation = nil
                return (timer, cont)
            }
            timer?.cancel()
            cont?.resume()
        }
    }
}
