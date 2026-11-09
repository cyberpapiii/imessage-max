import Foundation
import Synchronization

/// The `wait_for_messages` calls blocked until chat.db gains rows.
/// MessageWatcher reports each new MAX(ROWID) through `rowsArrived`. A drain
/// (SIGTERM, SIGUSR1, an installed update) ends every wait at once, and every
/// later wait before it blocks, so no wait holds up a stop or an update.
///
/// Each wait sleeps on a continuation and a Dispatch timer, never a Swift
/// task sleep (AGENTS.md), and holds no thread.
final class MessageArrivals: Sendable {
    /// Why a wait ended.
    enum Wake: Equatable, Sendable {
        /// chat.db has rows above the waiter's cursor.
        case arrived
        case deadline
        /// The helper is stopping or restarting.
        case draining
        case cancelled
        /// `capacity` waits were already blocked, so this one never started.
        case full
    }

    static let defaultCapacity = 32

    let capacity: Int

    private struct Waiter {
        let above: Int64
        let continuation: CheckedContinuation<Wake, Never>
        let timer: any DispatchSourceTimer
    }

    private struct State {
        /// The highest MAX(ROWID) reported so far.
        var latest: Int64 = 0
        var stopping = false
        var updatePending = false
        var draining: Bool { stopping || updatePending }
        var waiters: [UInt64: Waiter] = [:]
        /// Waits that have an id but no continuation yet, with whether their
        /// task was cancelled in that gap.
        var arming: [UInt64: Bool] = [:]
        var nextID: UInt64 = 0
    }

    private let state = Mutex(State())

    init(capacity: Int = defaultCapacity) {
        self.capacity = capacity
    }

    var waiting: Int { state.withLock { $0.waiters.count } }

    func rowsArrived(maxRowid: Int64) {
        let woken = state.withLock { state -> [Waiter] in
            state.latest = max(state.latest, maxRowid)
            let ids = state.waiters.filter { $0.value.above < maxRowid }.map(\.key)
            return ids.compactMap { state.waiters.removeValue(forKey: $0) }
        }
        for waiter in woken { Self.resume(waiter, .arrived) }
    }

    /// The helper is stopping: ends every wait with `.draining`, and every
    /// later one before it blocks.
    func drain() {
        endAll { $0.stopping = true }
    }

    /// An installed update waits for idle before the helper stops
    /// (`UpdateWatcher`). While it is pending, waits end as on `drain`.
    /// false when the original executable came back and no stop follows.
    func updatePending(_ pending: Bool) {
        endAll { $0.updatePending = pending }
    }

    private func endAll(after change: (inout State) -> Void) {
        let woken = state.withLock { state -> [Waiter] in
            change(&state)
            guard state.draining else { return [] }
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        for waiter in woken { Self.resume(waiter, .draining) }
    }

    /// Blocks until chat.db reports a row above `rowid`, `timeout` passes,
    /// the helper drains, or the calling task is cancelled.
    func wait(above rowid: Int64, timeout: Duration) async -> Wake {
        let id = state.withLock { state in
            state.nextID += 1
            state.arming[state.nextID] = false
            return state.nextID
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Wake, Never>) in
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                timer.setEventHandler { [weak self] in self?.end(id, .deadline) }
                timer.schedule(deadline: .now() + AsyncTimeout.dispatchInterval(for: timeout))
                let immediate: Wake? = state.withLock { state in
                    let cancelled = state.arming.removeValue(forKey: id) ?? false
                    if cancelled { return .cancelled }
                    if state.draining { return .draining }
                    if state.latest > rowid { return .arrived }
                    if state.waiters.count >= capacity { return .full }
                    state.waiters[id] = Waiter(above: rowid, continuation: continuation, timer: timer)
                    return nil
                }
                // A waker can cancel the timer before this resume. Resuming a
                // cancelled source only activates it, and releasing one that
                // was never activated traps in libdispatch.
                if let immediate {
                    timer.cancel()
                    timer.activate()
                    continuation.resume(returning: immediate)
                } else {
                    timer.resume()
                }
            }
        } onCancel: {
            let armed = state.withLock { state -> Bool in
                if state.arming[id] != nil {
                    state.arming[id] = true
                    return false
                }
                return true
            }
            if armed { end(id, .cancelled) }
        }
    }

    private func end(_ id: UInt64, _ wake: Wake) {
        guard let waiter = state.withLock({ $0.waiters.removeValue(forKey: id) }) else { return }
        Self.resume(waiter, wake)
    }

    private static func resume(_ waiter: Waiter, _ wake: Wake) {
        waiter.timer.cancel()
        waiter.continuation.resume(returning: wake)
    }
}
