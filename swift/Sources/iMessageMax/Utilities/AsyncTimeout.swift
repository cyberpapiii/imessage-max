import Foundation

enum AsyncTimeout {
    /// Dispatch-backed sleep. NEVER sleep Swift tasks inside the launchd service
    /// (sleeping unstructured tasks abort in swift_task_dealloc at wakeup —
    /// see HTTPTransport.swift storePendingRequest for the known-good pattern).
    static func sleep(_ duration: Duration) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + dispatchInterval(for: duration)
            ) { cont.resume() }
        }
    }

    /// Runs `operation` with a deadline enforced by a Dispatch timer.
    /// Returns its value, or nil on deadline/throw. The operation task is
    /// cancelled on timeout; operations that ignore cancellation may linger —
    /// callers must treat nil as "no answer", not "declined".
    static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let gate = ResumeGate()

            // Timeout side: Dispatch timer claims the gate and resumes with nil.
            let workItem = DispatchWorkItem {
                if gate.claim() {
                    gate.task?.cancel()
                    cont.resume(returning: nil)
                }
            }
            gate.workItem = workItem

            // Operation side: unstructured Task claims the gate and resumes with the value.
            let task = Task {
                let value = try? await operation()
                if gate.claim() {
                    gate.workItem?.cancel()
                    cont.resume(returning: value)
                }
            }
            gate.task = task

            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + dispatchInterval(for: timeout),
                execute: workItem
            )
        }
    }

    // MARK: - Private

    /// Once-only resume guard. @unchecked Sendable because internal state is
    /// protected by NSLock; this is the only type that needs this annotation.
    private final class ResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var did = false
        var task: Task<Void, Never>?
        var workItem: DispatchWorkItem?

        /// Returns true iff this is the first claim (caller may resume the continuation).
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !did else { return false }
            did = true
            return true
        }
    }

    private static func dispatchInterval(for duration: Duration) -> DispatchTimeInterval {
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
}
