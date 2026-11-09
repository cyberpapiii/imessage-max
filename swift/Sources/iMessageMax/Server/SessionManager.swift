import Foundation
import MCP

enum SessionCreationResult {
    case created(SessionManager.MCPSessionState)
    case atCapacity
    case startFailed
}

actor SessionManager {
    final class MCPSessionState: @unchecked Sendable {
        let id: String
        let server: Server
        let protocolVersion: String
        let messageContinuation: AsyncThrowingStream<Data, Error>.Continuation
        /// Seconds on `SessionManager.uptime`, not wall-clock time.
        var lastActivity: TimeInterval
        var serverTask: Task<Void, Never>?

        init(
            id: String,
            server: Server,
            protocolVersion: String,
            messageContinuation: AsyncThrowingStream<Data, Error>.Continuation,
            now: TimeInterval
        ) {
            self.id = id
            self.server = server
            self.protocolVersion = protocolVersion
            self.messageContinuation = messageContinuation
            self.lastActivity = now
        }
    }

    /// Idle time is measured on the uptime clock (mach_absolute_time), which
    /// a clock change cannot move and which stops while the Mac sleeps (088
    /// #30). Sleep time deliberately does not count: the clients asleep on
    /// the same Mac did not abandon their sessions, and a wall clock expired
    /// every session after an hour's sleep, or kept dead ones after the clock
    /// went back.
    static let uptime: @Sendable () -> TimeInterval = {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    private var sessions: [String: MCPSessionState] = [:]

    private var reservedSlots = 0

    private let sessionTimeout: TimeInterval

    private let maxSessions: Int

    private let reclaimableIdle: TimeInterval

    private let cleanupInterval: Duration

    private var cleanupTask: Task<Void, Never>?

    private let makeServer: @Sendable () async -> Server

    private let now: @Sendable () -> TimeInterval

    private var responseHandler: ((String, Data) async -> Void)?

    private var sessionTerminationHandler: ((String) async -> Void)?

    init(
        catalog: ToolCatalog,
        configuration: HTTPTransport.Configuration,
        now: @escaping @Sendable () -> TimeInterval = SessionManager.uptime
    ) {
        let makeServer = configuration.makeServer
        self.makeServer = { await makeServer(catalog) }
        self.now = now
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
        while reservedSlots + sessions.count >= maxSessions, let oldest = leastRecentlyActive() {
            let idle = Int(now() - oldest.lastActivity)
            Log.warning("Session cap of \(maxSessions) reached: closing the least recently active session \(oldest.id.prefix(8)), idle \(idle) s, to admit a new client")
            await terminateSession(sessionId: oldest.id)
        }

        guard reservedSlots + sessions.count < maxSessions else {
            return .atCapacity
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
            messageContinuation: continuation,
            now: now()
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

        session.lastActivity = now()
        session.messageContinuation.yield(data)
        return true
    }

    private func handleServerResponse(sessionId: String, data: Data) async {
        await responseHandler?(sessionId, data)
    }

    func validate(sessionId: String) async -> Bool {
        guard let session = sessions[sessionId] else {
            return false
        }

        let now = now()
        if now - session.lastActivity > sessionTimeout {
            await terminateSession(sessionId: sessionId)
            return false
        }

        session.lastActivity = now
        return true
    }

    func touch(sessionId: String) {
        guard let session = sessions[sessionId] else { return }
        session.lastActivity = now()
    }

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

    func terminateSession(sessionId: String) async {
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

    private func reclaimIdleSessions() async {
        let now = now()
        let idleIds = sessions.filter { _, session in
            now - session.lastActivity > reclaimableIdle
        }.map(\.key)
        guard !idleIds.isEmpty else { return }

        Log.info("Session cap of \(maxSessions) reached: closing \(idleIds.count) sessions idle over \(Int(reclaimableIdle)) s")
        for id in idleIds {
            await terminateSession(sessionId: id)
        }
    }

    /// The session that has gone longest without a request. Ties go to the
    /// lower id so the choice is stable.
    private func leastRecentlyActive() -> MCPSessionState? {
        sessions.values.min { ($0.lastActivity, $0.id) < ($1.lastActivity, $1.id) }
    }

    func cleanupExpiredSessions() async {
        let now = now()
        let expiredIds = sessions.filter { _, session in
            now - session.lastActivity > sessionTimeout
        }.map(\.key)

        for id in expiredIds {
            await terminateSession(sessionId: id)
        }
    }
}
