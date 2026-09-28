import Foundation
import Synchronization

enum AsyncTimeout {
    /// Test seam: number of Dispatch timers started by `sleep`. Only
    /// incremented on the path that actually resumes a timer source.
    nonisolated(unsafe) static var enqueuedTimersForTesting = 0

    /// Dispatch-backed sleep. NEVER sleep Swift tasks inside the launchd service
    /// (sleeping unstructured tasks abort in swift_task_dealloc at wakeup.
    /// See HTTPTransport.swift storePendingRequest for the known-good pattern).
    ///
    /// Honors task cancellation: cancels the Dispatch timer and resumes so the
    /// awaiting task can observe `Task.isCancelled` without leaking a continuation.
    static func sleep(_ duration: Duration) async {
        await sleep(duration, gate: ResumeGate())
    }

    /// Test seam: lets a test hold a weak reference to the gate.
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
                enqueuedTimersForTesting += 1
                timer.resume()
            }
        } onCancel: {
            gate.cancelAndResume()
        }
    }

    // MARK: - Shared helpers

    /// Overflow-clamped `Duration` → `DispatchTimeInterval` conversion, shared by
    /// every Dispatch-deadline site in the service (this file's `sleep` and
    /// HTTPTransport's request-timeout timer).
    ///
    /// It saturates at `Int.max` nanoseconds rather than trapping: `Duration`
    /// spans far more than the ~292 years `Int` nanoseconds can hold, so both the
    /// whole-seconds multiply and the fractional add would otherwise overflow on
    /// large or adversarial values. Keep the saturation if you change this.
    /// A trap here would take down the launchd service.
    static func dispatchInterval(for duration: Duration) -> DispatchTimeInterval {
        let components = duration.components
        let maxWholeSeconds = Int64(Int.max / 1_000_000_000)
        let clampedSeconds = max(0, min(components.seconds, maxWholeSeconds))
        let secondNanoseconds = Int(clampedSeconds) * 1_000_000_000
        let fractionalNanoseconds = max(0, Int(components.attoseconds / 1_000_000_000))
        let nanoseconds = secondNanoseconds > Int.max - fractionalNanoseconds
            ? Int.max
            : secondNanoseconds + fractionalNanoseconds
        return .nanoseconds(nanoseconds)
    }

    /// Single-resume gate for Dispatch sleep + cancellation.
    ///
    /// Invariant: `resumed` is true only after a continuation has actually
    /// been resumed. `withTaskCancellationHandler` runs `onCancel` before the
    /// body when the task is already cancelled on entry, so `cancelAndResume`
    /// can run before `arm`; it must not claim the resume in that case, or the
    /// continuation that `arm` later delivers is never resumed.
    ///
    /// `arm` returns true when the caller must start the timer, false when
    /// cancellation already resumed the continuation and nothing should run.
    ///
    /// The timer's handler captures the gate, so the gate must drop the
    /// timer (and cancel it, which releases the handler) whichever way the
    /// sleep ends. Holding it formed a cycle that leaked every gate.
    final class ResumeGate: @unchecked Sendable {
        private let state = Mutex(())
        private var timer: DispatchSourceTimer?
        private var continuation: CheckedContinuation<Void, Never>?
        private var resumed = false
        private var cancelled = false

        /// Returns true when the gate now holds `timer` and `continuation`, i.e.
        /// the caller must start `timer`. Returns false when cancellation
        /// already resumed the continuation; the caller must not start it.
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
                return true
            }
        }

        /// Timer fired.
        func resume() {
            finish(cancelling: false)
        }

        func cancelAndResume() {
            finish(cancelling: true)
        }

        private func finish(cancelling: Bool) {
            let (timer, cont) = state.withLock { _ in
                if cancelling { cancelled = true }
                // Only claim the resume if we actually hold the continuation. If
                // arm() has not run yet, leave `resumed` false so arm() resumes
                // on arrival.
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
