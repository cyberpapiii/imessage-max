import Foundation

enum AsyncTimeout {
    /// Runs `operation` with a deadline. Returns its value, or nil if the
    /// deadline elapses first (the operation task is then cancelled — note
    /// that operations which ignore cancellation may linger in the
    /// background; callers must treat nil as "no answer", not "declined").
    ///
    /// An operation that **throws** is also reported as nil (indistinguishable
    /// from a timeout). This is intentional for the send-confirmation path where
    /// both cases map to `.unavailable`.
    static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                try? await operation()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
