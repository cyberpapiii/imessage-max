import Foundation
import Synchronization

/// Returns `operation`'s result, or throws `CoreError.timeout` once `seconds`
/// pass. Time running out ends only the wait: an SMAppService call or a
/// permission prompt cannot be cancelled, so the operation keeps running.
/// The timer is Dispatch, never Task.sleep, which aborts in launchd-run
/// processes (AGENTS.md).
public func withDeadline<T: Sendable>(
  seconds: Double, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  let work = Task { try await operation() }
  return try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { continuation in
      let pending = Pending(continuation)
      let timer = DispatchSource.makeTimerSource(queue: .global())
      timer.schedule(deadline: .now() + seconds)
      timer.setEventHandler { pending.resume(with: .failure(CoreError.timeout)) }
      timer.resume()
      Task {
        let result = await work.result
        timer.cancel()
        pending.resume(with: result)
      }
    }
  } onCancel: {
    work.cancel()
  }
}

/// Resumes its continuation once, for whichever of the operation and the
/// timer finishes first.
private final class Pending<T: Sendable>: Sendable {
  private let continuation: Mutex<CheckedContinuation<T, any Error>?>

  init(_ continuation: CheckedContinuation<T, any Error>) {
    self.continuation = Mutex(continuation)
  }

  func resume(with result: Result<T, any Error>) {
    continuation.withLock { $0.take() }?.resume(with: result)
  }
}
