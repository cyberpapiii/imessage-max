import Foundation
import MCP
import Synchronization

actor PendingRequestRegistry {
    struct Key: Hashable {
        let sessionId: String
        let requestId: String
    }

    private struct Entry {
        let continuation: CheckedContinuation<Data, Error>
        let timer: DispatchSourceTimer
    }

    private var entries: [Key: Entry] = [:]
    private let timeout: Duration

    init(timeout: Duration) {
        self.timeout = timeout
    }

    func store(
        sessionId: String,
        id: String,
        continuation: CheckedContinuation<Data, Error>
    ) -> Bool {
        let key = Key(sessionId: sessionId, requestId: id)
        guard entries[key] == nil else { return false }

        // Use a Dispatch timer instead of Task.sleep here. On this launchd-run
        // service, sleeping unstructured Swift tasks have repeatedly aborted in
        // swift_task_dealloc when they wake around the timeout boundary.
        //
        // Use a cancellable DispatchSourceTimer, not asyncAfter. A cancelled
        // asyncAfter work item stays enqueued (timer source, group, blocks,
        // about 0.65 KiB) until its deadline. Every served request retained
        // its 300 s timer, and sustained load carried tens of MB of dead
        // timers. Cancelling a timer source releases it immediately.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.setEventHandler { [weak self] in
            Task { [weak self] in
                await self?.timeout(sessionId: sessionId, id: id)
            }
        }
        timer.schedule(deadline: .now() + AsyncTimeout.dispatchInterval(for: timeout))
        timer.resume()
        entries[key] = Entry(continuation: continuation, timer: timer)
        return true
    }

    func isPending(sessionId: String, id: String) -> Bool {
        entries[Key(sessionId: sessionId, requestId: id)] != nil
    }

    func remove(sessionId: String, id: String) -> CheckedContinuation<Data, Error>? {
        let key = Key(sessionId: sessionId, requestId: id)
        let entry = entries.removeValue(forKey: key)
        entry?.timer.cancel()
        return entry?.continuation
    }

    func timeout(sessionId: String, id: String) {
        if let continuation = remove(sessionId: sessionId, id: id) {
            continuation.resume(
                throwing: MCPError.serverError(code: JSONRPCErrorCode.serverError.rawValue, message: "Request timeout")
            )
        }
    }

    func cleanup(for sessionId: String) {
        let keys = entries.keys.filter { $0.sessionId == sessionId }
        for key in keys {
            guard let entry = entries.removeValue(forKey: key) else { continue }
            entry.timer.cancel()
            entry.continuation.resume(
                throwing: MCPError.serverError(code: JSONRPCErrorCode.serverError.rawValue, message: "Session terminated")
            )
        }
    }

    func removeAll() {
        for (_, entry) in entries {
            entry.timer.cancel()
            entry.continuation.resume(throwing: MCPError.connectionClosed)
        }
        entries.removeAll()
    }

    var count: Int { entries.count }
}

final class InFlightRequests<Key: Hashable & Sendable>: Sendable {
    struct Call<Value: Sendable>: Sendable {
        let task: Task<Value, Never>
        let trackedKey: Key?
    }

    private let cancellers = Mutex<[Key: @Sendable () -> Void]>([:])

    func start<Value: Sendable>(
        _ key: Key?,
        _ operation: @escaping @Sendable () async -> Value
    ) -> Call<Value> {
        let task = Task { await operation() }
        guard let key else { return Call(task: task, trackedKey: nil) }
        let tracked = cancellers.withLock { entries in
            guard entries[key] == nil else { return false }
            entries[key] = { task.cancel() }
            return true
        }
        return Call(task: task, trackedKey: tracked ? key : nil)
    }

    func startUnlessInFlight<Value: Sendable>(
        _ key: Key,
        _ operation: @escaping @Sendable () async -> Value
    ) -> Call<Value>? {
        cancellers.withLock { entries in
            guard entries[key] == nil else { return nil }
            let task = Task { await operation() }
            entries[key] = { task.cancel() }
            return Call(task: task, trackedKey: key)
        }
    }

    func isInFlight(_ key: Key) -> Bool {
        cancellers.withLock { $0[key] != nil }
    }

    func finish<Value>(_ call: Call<Value>) async -> Value {
        let value = await withTaskCancellationHandler {
            await call.task.value
        } onCancel: {
            call.task.cancel()
        }
        if let key = call.trackedKey {
            _ = cancellers.withLock { $0.removeValue(forKey: key) }
        }
        return value
    }

    func cancel(_ key: Key) {
        cancellers.withLock { $0[key] }?()
    }
}
