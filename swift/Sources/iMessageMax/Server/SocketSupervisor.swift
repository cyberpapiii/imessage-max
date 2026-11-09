import Dispatch
import Foundation
import Synchronization

/// Keeps the stdio-bridge socket listening for the life of the HTTP helper.
/// Every `interval` it checks that the socket file is still the one its
/// listener bound. When the file is gone, or no listener runs because setup
/// failed or another helper held the path, it starts one again (088 #32).
///
/// A listener whose file vanished is retired, not stopped: its open bridge
/// sessions keep working, and only stop() ends them.
final class SocketSupervisor: Sendable {
    static let defaultInterval: Duration = .seconds(30)

    typealias Start = @Sendable () async throws(SocketSetupError) -> SocketListener

    private struct State {
        var listener: SocketListener?
        var retired: [SocketListener] = []
        var timer: (any DispatchSourceTimer)?
        var checking = false
        var stopped = false
        /// The last failure logged, so a retry that fails the same way stays quiet.
        var lastProblem: String?
    }

    private let state = Mutex(State())
    private let path: String
    private let startListener: Start

    init(path: String, start: @escaping Start) {
        self.path = path
        startListener = start
    }

    /// Starts the first listener, then checks every `interval`.
    static func start(
        at socket: SocketPath,
        interval: Duration = defaultInterval,
        serve: @escaping SocketListener.Serve
    ) async -> SocketSupervisor {
        let supervisor = SocketSupervisor(path: socket.path) { () throws(SocketSetupError) in
            try await SocketListener.start(at: socket, serve: serve)
        }
        await supervisor.check()
        supervisor.schedule(every: interval)
        return supervisor
    }

    var isListening: Bool { state.withLock { $0.listener != nil } }

    /// One check: nothing while the listener's file is in place, otherwise
    /// retire it and start a new one. Overlapping calls do nothing.
    func check() async {
        let current: SocketListener?? = state.withLock { state in
            guard !state.stopped, !state.checking else { return .none }
            state.checking = true
            return .some(state.listener)
        }
        guard case .some(let listener) = current else { return }
        defer { state.withLock { $0.checking = false } }

        if let listener {
            if listener.isReachable { return }
            Log.warning("Socket file \(path) disappeared; listening on it again")
            listener.retire()
            state.withLock { state in
                state.retired.append(listener)
                state.listener = nil
            }
        }

        let started: SocketListener
        do throws(SocketSetupError) {
            started = try await startListener()
        } catch {
            let problem = Self.message(for: error)
            let isNew = state.withLock { state in
                defer { state.lastProblem = problem }
                return state.lastProblem != problem
            }
            if isNew { Log.warning(problem) }
            return
        }
        let keep = state.withLock { state in
            guard !state.stopped else { return false }
            state.listener = started
            state.lastProblem = nil
            return true
        }
        if !keep { await started.stop() }
    }

    /// Stops checking, then stops every listener and ends their sessions.
    func stop() async {
        let listeners: [SocketListener] = state.withLock { state in
            state.stopped = true
            state.timer?.cancel()
            state.timer = nil
            defer { state.listener = nil; state.retired = [] }
            return (state.listener.map { [$0] } ?? []) + state.retired
        }
        for listener in listeners {
            await listener.stop()
        }
    }

    private func schedule(every interval: Duration) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let period = AsyncTimeout.dispatchInterval(for: interval)
        timer.schedule(deadline: .now() + period, repeating: period)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.check() }
        }
        // Resumed before it is stored, so no path releases it unresumed.
        timer.resume()
        let stored = state.withLock { state in
            guard !state.stopped else { return false }
            state.timer = timer
            return true
        }
        if !stored { timer.cancel() }
    }

    private static func message(for error: SocketSetupError) -> String {
        if case .inUse(let path) = error {
            return "Another iMessage Max answers on \(path); stdio bridges use it. Serving HTTP only."
        }
        return "Serving HTTP only; stdio bridges cannot connect. \(error)"
    }
}
