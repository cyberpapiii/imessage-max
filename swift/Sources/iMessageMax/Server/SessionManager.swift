import Foundation
import Logging
import MCP

/// Outcome of createSession: capacity refusal and startup failure need
/// different HTTP answers (503 retry-later vs 500 internal). Collapsing both
/// into `nil` told clients to retry against a server that would never succeed.
enum SessionCreationResult {
    case created(SessionManager.MCPSessionState)
    case atCapacity
    case startFailed(any Error)
}

/// Manages MCP sessions for the HTTP transport.
///
/// Each session has its own Server instance, enabling clean reconnection.
/// When a client reconnects, they get a new session with a fresh Server.
actor SessionManager {
    /// Complete session state including Server instance
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

    /// Active sessions keyed by session ID
    private var sessions: [String: MCPSessionState] = [:]

    /// Slots claimed by in-flight `createSession` calls. The cap is checked
    /// against `reservedSlots + sessions.count` so two concurrent creates
    /// cannot both pass the count check, await registration, and both insert.
    private var reservedSlots = 0

    /// Session timeout duration (1 hour by default)
    private let sessionTimeout: TimeInterval

    /// Maximum number of concurrent sessions
    private let maxSessions: Int

    /// Idle span after which a session is reclaimed to admit a new client
    /// when the table is full.
    private let reclaimableIdle: TimeInterval

    /// How often the expired-session sweep runs. Production uses 300s.
    /// Tests pass a short interval so a leftover cleanup `Task` cannot pin
    /// a `swift test --parallel` worker for five minutes.
    private let cleanupInterval: Duration

    /// Task for periodic cleanup
    private var cleanupTask: Task<Void, Never>?

    /// Database for tool registration
    private let database: Database

    /// Contact resolver for tool registration
    private let resolver: ContactResolver

    /// Callback to route Server responses back to HTTP
    private var responseHandler: ((String, Data) async -> Void)?

    /// Callback when sessions are terminated (for SSE cleanup)
    private var sessionTerminationHandler: ((String) async -> Void)?

    /// - Parameters:
    ///   - sessionTimeout: idle TTL before a session is reaped. Production
    ///     uses the 3600s default; tests shrink it to exercise cleanup.
    ///   - maxSessions: concurrent-session cap. Production uses the default.
    ///     A session costs about half a kilobyte of resident memory (measured
    ///     across 100 live sessions), so the cap is a guard against runaway
    ///     clients rather than a resource limit; 100 turned a fleet of agents
    ///     that each open their own session into 503s within seconds.
    ///   - reclaimableIdle: idle span after which a session may be reclaimed
    ///     to admit a new client once the cap is reached. Production uses the
    ///     default; tests shrink it to reach the reclaim path.
    ///   - cleanupInterval: sweep period. Production uses 300s; tests shrink
    ///     it so cancelled `asyncAfter` work does not occupy a parallel
    ///     worker until the five-minute deadline.
    init(
        database: Database,
        resolver: ContactResolver,
        sessionTimeout: TimeInterval = 3600,
        maxSessions: Int = 512,
        reclaimableIdle: TimeInterval = 300,
        cleanupInterval: Duration = .seconds(300)
    ) {
        self.database = database
        self.resolver = resolver
        self.sessionTimeout = sessionTimeout
        self.maxSessions = maxSessions
        self.reclaimableIdle = reclaimableIdle
        self.cleanupInterval = cleanupInterval
    }

    deinit {
        cleanupTask?.cancel()
    }

    /// Sets the response handler for routing Server responses
    func setResponseHandler(_ handler: @escaping (String, Data) async -> Void) {
        self.responseHandler = handler
    }

    /// Sets the session termination handler (for SSE cleanup on timeout)
    func setSessionTerminationHandler(_ handler: @escaping (String) async -> Void) {
        self.sessionTerminationHandler = handler
    }

    /// Creates a new session with its own Server instance
    ///
    /// This is the key to supporting reconnection - each session gets a fresh Server.
    func createSession(
        protocolVersion: String = MCPProtocolVersion.defaultAssumed
    ) async -> SessionCreationResult {
        if sessions.count >= maxSessions {
            await reclaimIdleSessions()
        }

        guard reservedSlots + sessions.count < maxSessions else {
            return .atCapacity  // Caller returns 503 Service Unavailable
        }
        reservedSlots += 1
        defer { reservedSlots -= 1 }

        // Start cleanup task on first session creation
        if cleanupTask == nil {
            startCleanupTask()
        }

        let sessionId = UUID().uuidString

        // Create per-session Server instance
        let server = Server(
            name: Version.name,
            version: Version.current,
            title: Version.title,
            instructions: Version.instructions,
            capabilities: Version.serverCapabilities
        )

        // Register tools on this server instance
        await ToolRegistry.registerAll(on: server, db: database, resolver: resolver)

        // Create message stream for this session
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        let messageStream = AsyncThrowingStream<Data, Error> { continuation = $0 }

        let session = MCPSessionState(
            id: sessionId,
            server: server,
            protocolVersion: protocolVersion,
            messageContinuation: continuation
        )

        // Create per-session transport adapter
        let adapter = SessionTransportAdapter(
            sessionId: sessionId,
            messageStream: messageStream,
            responseHandler: { [weak self] data in
                await self?.handleServerResponse(sessionId: sessionId, data: data)
            }
        )

        do {
            try await server.start(transport: adapter)
        } catch {
            session.messageContinuation.finish()
            Log.error("session Server.start failed: \(error)")
            return .startFailed(error)
        }

        session.serverTask = Task {
            await server.waitUntilCompleted()
        }

        sessions[sessionId] = session
        return .created(session)
    }

    /// Routes an incoming message to the appropriate session's Server
    func routeMessage(sessionId: String, data: Data) async -> Bool {
        guard let session = sessions[sessionId] else {
            return false
        }

        session.lastActivity = Date()
        session.messageContinuation.yield(data)
        return true
    }

    /// Handles response from a session's Server
    private func handleServerResponse(sessionId: String, data: Data) async {
        await responseHandler?(sessionId, data)
    }

    /// Validates a session ID and returns the session if valid
    func validate(sessionId: String) async -> MCPSessionState? {
        guard let session = sessions[sessionId] else {
            return nil
        }

        // Check if session has expired
        if Date().timeIntervalSince(session.lastActivity) > sessionTimeout {
            await terminateSession(sessionId: sessionId)
            return nil
        }

        return session
    }

    /// Updates the last activity time for a session
    func touch(sessionId: String) {
        guard let session = sessions[sessionId] else { return }
        session.lastActivity = Date()
    }

    /// Returns the negotiated protocol version for a session.
    func protocolVersion(for sessionId: String) -> String? {
        sessions[sessionId]?.protocolVersion
    }

    /// Terminates a session and stops its SDK Server.
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

        Task { await sessionTerminationHandler?(sessionId) }
    }

    /// Returns all active session IDs
    func activeSessionIds() -> [String] {
        return Array(sessions.keys)
    }

    func registerMethodHandlerForTesting<M: MCP.Method>(
        sessionId: String,
        _ method: M.Type,
        handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
    ) async -> Bool {
        guard let server = sessions[sessionId]?.server else { return false }
        await server.withMethodHandler(method, handler: handler)
        return true
    }

    /// Returns session count for monitoring
    var sessionCount: Int {
        sessions.count
    }

    /// Starts the background cleanup task
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
    /// only runs every five minutes. Without this, a table full of abandoned
    /// sessions refuses every new client for up to an hour, and the only
    /// recovery is restarting the service. A live client touches its session
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
    /// Driven by the 5-minute timer loop above; also callable directly by
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

// MARK: - Per-Session Transport Adapter

/// A lightweight Transport adapter that bridges a session to its Server instance.
///
/// Each session has its own adapter, enabling independent Server lifecycles.
actor SessionTransportAdapter: Transport {
    private let sessionId: String
    private let messageStream: AsyncThrowingStream<Data, Error>
    private let responseHandler: (Data) async -> Void
    private var isConnected = true

    /// Logger for transport events (required by Transport protocol)
    nonisolated let logger: Logger

    init(
        sessionId: String,
        messageStream: AsyncThrowingStream<Data, Error>,
        responseHandler: @escaping (Data) async -> Void
    ) {
        self.sessionId = sessionId
        self.messageStream = messageStream
        self.responseHandler = responseHandler
        self.logger = Logger(
            label: "mcp.transport.session.\(sessionId.prefix(8))",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )
    }

    func connect() async throws {
        // Already connected via messageStream
    }

    func disconnect() async {
        isConnected = false
    }

    func send(_ data: Data) async throws {
        guard isConnected else { return }
        await responseHandler(IconMetadata.injectServerIcons(into: data))
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        return messageStream
    }
}
