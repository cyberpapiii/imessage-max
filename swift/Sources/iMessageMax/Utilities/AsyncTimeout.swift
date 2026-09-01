import Foundation
import Synchronization

enum AsyncTimeout {
    /// Dispatch-backed sleep. NEVER sleep Swift tasks inside the launchd service
    /// (sleeping unstructured tasks abort in swift_task_dealloc at wakeup.
    /// See HTTPTransport.swift storePendingRequest for the known-good pattern).
    ///
    /// Honors task cancellation: cancels the Dispatch timer and resumes so the
    /// awaiting task can observe `Task.isCancelled` without leaking a continuation.
    static func sleep(_ duration: Duration) async {
        let gate = ResumeGate()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let work = DispatchWorkItem {
                    gate.resume(continuation)
                }
                gate.arm(work: work, continuation: continuation)
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + dispatchInterval(for: duration),
                    execute: work
                )
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
    private final class ResumeGate: @unchecked Sendable {
        private let state = Mutex(())
        private var work: DispatchWorkItem?
        private var continuation: CheckedContinuation<Void, Never>?
        private var resumed = false
        private var cancelled = false

        func arm(work: DispatchWorkItem, continuation: CheckedContinuation<Void, Never>) {
            state.withLock { _ in
                if cancelled || resumed {
                    if !resumed {
                        resumed = true
                        continuation.resume()
                    }
                    return
                }
                self.work = work
                self.continuation = continuation
            }
        }

        func resume(_ continuation: CheckedContinuation<Void, Never>) {
            state.withLock { _ in
                guard !resumed else { return }
                resumed = true
                self.continuation = nil
                continuation.resume()
            }
        }

        func cancelAndResume() {
            let (item, cont, already) = state.withLock { _ in
                cancelled = true
                let item = work
                let cont = continuation
                let already = resumed
                // Only claim the resume if we actually hold the continuation. If arm()
                // has not run yet, leave `resumed` false so arm() resumes on arrival.
                if !already, cont != nil {
                    resumed = true
                    continuation = nil
                }
                return (item, cont, already)
            }
            item?.cancel()
            if !already, let cont {
                cont.resume()
            }
        }
    }
}
