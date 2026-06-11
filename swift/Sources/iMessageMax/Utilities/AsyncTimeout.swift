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

    // MARK: - Private

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
