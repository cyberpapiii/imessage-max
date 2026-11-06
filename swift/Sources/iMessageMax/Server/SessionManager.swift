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

    private var reservedSlots = 0

    private let sessionTimeout: TimeInterval

    private let maxSessions: Int

    private let reclaimableIdle: TimeInterval

    private let cleanupInterval: Duration

    private var cleanupTask: Task<Void, Never>?

    private let makeServer: @Sendable () async -> Server

    private var responseHandler: ((String, Data) async -> Void)?

    private var sessionTerminationHandler: ((String) async -> Void)?

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
        let now = Date()
        let idleIds = sessions.filter { _, session in
            now.timeIntervalSince(session.lastActivity) > reclaimableIdle
        }.map(\.key)

        for id in idleIds {
            await terminateSession(sessionId: id)
        }
    }

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
