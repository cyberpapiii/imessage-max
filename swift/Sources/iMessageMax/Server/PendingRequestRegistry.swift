import Foundation
import MCP

/// In-flight JSON-RPC requests awaiting a response from the session's server,
/// keyed by (session, request id), each with a cancellable timeout timer.
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

    /// Returns false when a request with the same id is already pending.
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
        // Use a cancellable DispatchSourceTimer, not asyncAfter: a cancelled
        // asyncAfter work item stays enqueued (timer source, group, blocks,
        // ~0.65 KiB) until its deadline, so every served request retained its
        // 300 s timer and sustained load carried tens of MB of dead timers.
        // Cancelling a timer source releases it immediately.
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

    func remove(sessionId: String, id: String) -> CheckedContinuation<Data, Error>? {
        let key = Key(sessionId: sessionId, requestId: id)
        let entry = entries.removeValue(forKey: key)
        entry?.timer.cancel()
        return entry?.continuation
    }

    func timeout(sessionId: String, id: String) {
        if let continuation = remove(sessionId: sessionId, id: id) {
            continuation.resume(
                throwing: MCPError.serverError(code: -32000, message: "Request timeout")
            )
        }
    }

    func cleanup(for sessionId: String) {
        let keys = entries.keys.filter { $0.sessionId == sessionId }
        for key in keys {
            guard let entry = entries.removeValue(forKey: key) else { continue }
            entry.timer.cancel()
            entry.continuation.resume(
                throwing: MCPError.serverError(code: -32000, message: "Session terminated")
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
