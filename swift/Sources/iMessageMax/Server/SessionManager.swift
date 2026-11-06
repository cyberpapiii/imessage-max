import Foundation
import MCP

/// Outcome of createSession: capacity refusal and startup failure need
/// different HTTP answers (503 retry-later vs 500 internal).
enum SessionCreationResult {
    case created(SessionManager.MCPSessionState)
    case atCapacity
    /// The SDK Server would not start; the error is logged here.
    case startFailed
}

/// Manages MCP sessions for the HTTP transport.
///
/// Each session has its own Server instance, enabling clean reconnection.
/// When a client reconnects, they get a new session with a fresh Server.
actor SessionManager {
    final class MCPSessionState: @unchecked Sendable {
        let id: String
        let server: Server
        let protocolVersion: String
        let messageContinuation: AsyncThrowingStream<Data, Error>.Continuation
        var lastActivity: Date
        var serverTask: Task<Void, Never>?

        init(
            id: String,
            server: Server,
            protocolVersion: String,
            messageContinuation: AsyncThrowingStream<Data, Error>.Continuation
        ) {
            self.id = id
            self.server = server
            self.protocolVersion = protocolVersion
            self.messageContinuation = messageContinuation
            self.lastActivity = Date()
        }
    }

    private var sessions: [String: MCPSessionState] = [:]

    /// Slots claimed by in-flight `createSession` calls. The cap is checked
    /// against `reservedSlots + sessions.count` so two concurrent creates
    /// cannot both pass the count check, await registration, and both insert.
    private var reservedSlots = 0

    /// Idle TTL before a session is reaped.
    private let sessionTimeout: TimeInterval

    private let maxSessions: Int

    /// Idle span after which a session is reclaimed to admit a new client
    /// when the table is full.
    private let reclaimableIdle: TimeInterval

    /// How often the expired-session sweep runs.
    private let cleanupInterval: Duration

    private var cleanupTask: Task<Void, Never>?

    /// Builds each session's SDK Server.
    private let makeServer: @Sendable () async -> Server

    private var responseHandler: ((String, Data) async -> Void)?

    private var sessionTerminationHandler: ((String) async -> Void)?

    /// Every limit comes from `configuration`, where the production values
    /// and their reasons live.
    init(catalog: ToolCatalog, configuration: HTTPTransport.Configuration) {
        let makeServer = configuration.makeServer
        self.makeServer = { await makeServer(catalog) }
        self.sessionTimeout = configuration.sessionTimeout
        self.maxSessions = configuration.maxSessions
        self.reclaimableIdle = configuration.reclaimableIdle
        self.cleanupInterval = configuration.cleanupInterval
    }

    deinit {
        cleanupTask?.cancel()
    }

    func setResponseHandler(_ handler: @escaping (String, Data) async -> Void) {
        self.responseHandler = handler
    }

    func setSessionTerminationHandler(_ handler: @escaping (String) async -> Void) {
        self.sessionTerminationHandler = handler
    }

    func createSession(
        protocolVersion: String = LegacyProtocol.latest
    ) async -> SessionCreationResult {
        if sessions.count >= maxSessions {
            await reclaimIdleSessions()
        }

        guard reservedSlots + sessions.count < maxSessions else {
            return .atCapacity  // Caller returns 503 Service Unavailable
        }
        reservedSlots += 1
        defer { reservedSlots -= 1 }

        if cleanupTask == nil {
            startCleanupTask()
        }

        let sessionId = UUID().uuidString

        let server = await makeServer()
        let (messageStream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()

        let session = MCPSessionState(
            id: sessionId,
            server: server,
            protocolVersion: protocolVersion,
            messageContinuation: continuation
        )

        let transport = LegacyLaneTransport(inbound: messageStream) { [weak self] data in
            await self?.handleServerResponse(sessionId: sessionId, data: data)
        }

        do {
            try await server.start(transport: transport)
        } catch {
            session.messageContinuation.finish()
            Log.error("session Server.start failed: \(error)")
            return .startFailed
        }

        session.serverTask = Task {
            await server.waitUntilCompleted()
        }

        sessions[sessionId] = session
        return .created(session)
    }

    func routeMessage(sessionId: String, data: Data) async -> Bool {
        guard let session = sessions[sessionId] else {
            return false
        }

        session.lastActivity = Date()
        session.messageContinuation.yield(data)
        return true
    }

    private func handleServerResponse(sessionId: String, data: Data) async {
        await responseHandler?(sessionId, data)
    }

    /// True when the id names a live session, which is marked active; false
    /// when it is unknown or expired (an expired one is terminated here).
    func validate(sessionId: String) async -> Bool {
        guard let session = sessions[sessionId] else {
            return false
        }

        let now = Date()
        if now.timeIntervalSince(session.lastActivity) > sessionTimeout {
            await terminateSession(sessionId: sessionId)
            return false
        }

        session.lastActivity = now
        return true
    }

    func touch(sessionId: String) {
        guard let session = sessions[sessionId] else { return }
        session.lastActivity = Date()
    }

    /// Sends `notification` to every live session. Errors are per-session
    /// and swallowed: a session whose Server has stopped just drops it.
    func notifyAllSessions<N: MCP.Notification>(_ notification: Message<N>) async -> Int {
        var delivered = 0
        for session in sessions.values {
            do {
                try await session.server.notify(notification)
                delivered += 1
            } catch {
                Log.warning("notify \(N.name) to session \(session.id.prefix(8)) failed: \(error)")
            }
        }
        return delivered
    }

    func protocolVersion(for sessionId: String) -> String? {
        sessions[sessionId]?.protocolVersion
    }

    /// Terminates a session: stops its SDK Server, then runs the termination
    /// handler (the transport closes the session's SSE streams and fails its
    /// waiting requests there). Every teardown path comes through here, so
    /// callers do nothing more.
    ///
    /// `Server.stop()` can hang on a wedged transport, so the wait is bounded
    /// to 2 seconds by racing against `AsyncTimeout.sleep`. Never `Task.sleep`.
    func terminateSession(sessionId: String) async {
        // Remove first: once termination starts, routeMessage and validate
        // must refuse this id even while server.stop() is still running.
        guard let session = sessions.removeValue(forKey: sessionId) else { return }

        session.serverTask?.cancel()
        session.messageContinuation.finish()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await session.server.stop() }
            group.addTask { await AsyncTimeout.sleep(.seconds(2)) }
            await group.next()
            group.cancelAll()
        }

        await sessionTerminationHandler?(sessionId)
    }

    func activeSessionIds() -> [String] {
        return Array(sessions.keys)
    }

    var sessionCount: Int {
        sessions.count
    }

    private func startCleanupTask() {
        let interval = cleanupInterval
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                await AsyncTimeout.sleep(interval)
                await self?.cleanupExpiredSessions()
            }
        }
    }

    /// Removes sessions idle long enough to be presumed abandoned.
    ///
    /// A client that disappears without sending DELETE leaves its session
    /// behind for the full `sessionTimeout`, and the sweep that removes it
    /// only runs every `cleanupInterval`. Without this, a table full of
    /// abandoned sessions refuses every new client until they expire (up to
    /// `sessionTimeout`), and the only faster recovery is restarting the
    /// service. A live client touches its session
    /// far more often than the reclaim window, so anything staler is a client
    /// that went away. This runs only under capacity pressure, so a quiet but
    /// live session is left alone while there is room.
    private func reclaimIdleSessions() async {
        let now = Date()
        let idleIds = sessions.filter { _, session in
            now.timeIntervalSince(session.lastActivity) > reclaimableIdle
        }.map(\.key)

        for id in idleIds {
            await terminateSession(sessionId: id)
        }
    }

    /// Removes expired sessions.
    ///
    /// Driven by the `cleanupInterval` loop above; also callable directly by
    /// tests, which inject a short `sessionTimeout` rather than waiting.
    func cleanupExpiredSessions() async {
        let now = Date()
        let expiredIds = sessions.filter { _, session in
            now.timeIntervalSince(session.lastActivity) > sessionTimeout
        }.map(\.key)

        for id in expiredIds {
            await terminateSession(sessionId: id)
        }
    }
}
