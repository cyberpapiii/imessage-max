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

    /// Session timeout duration (1 hour by default)
    private let sessionTimeout: TimeInterval

    /// Maximum number of concurrent sessions
    private let maxSessions: Int

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
    init(
        database: Database,
        resolver: ContactResolver,
        sessionTimeout: TimeInterval = 3600,
        maxSessions: Int = 100
    ) {
        self.database = database
        self.resolver = resolver
        self.sessionTimeout = sessionTimeout
        self.maxSessions = maxSessions
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
        guard sessions.count < maxSessions else {
            return .atCapacity  // Caller returns 503 Service Unavailable
        }

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
            FileHandle.standardError.write(
                Data("[iMessage Max] session Server.start failed: \(error)\n".utf8)
            )
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
    func validate(sessionId: String) -> MCPSessionState? {
        guard let session = sessions[sessionId] else {
            return nil
        }

        // Check if session has expired
        if Date().timeIntervalSince(session.lastActivity) > sessionTimeout {
            terminateSession(sessionId: sessionId)
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

    /// Terminates a session and cleans up its Server
    func terminateSession(sessionId: String) {
        guard let session = sessions[sessionId] else { return }

        // Cancel server task
        session.serverTask?.cancel()

        // Complete the message stream
        session.messageContinuation.finish()

        // Remove from active sessions
        sessions.removeValue(forKey: sessionId)

        // Notify HTTPTransport to clean up SSE connections
        Task {
            await sessionTerminationHandler?(sessionId)
        }
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
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                await AsyncTimeout.sleep(.seconds(300))  // Run every 5 minutes
                await self?.cleanupExpiredSessions()
            }
        }
    }

    /// Removes expired sessions.
    ///
    /// Driven by the 5-minute timer loop above; also callable directly by
    /// tests, which inject a short `sessionTimeout` rather than waiting.
    func cleanupExpiredSessions() {
        let now = Date()
        let expiredIds = sessions.filter { _, session in
            now.timeIntervalSince(session.lastActivity) > sessionTimeout
        }.map(\.key)

        for id in expiredIds {
            terminateSession(sessionId: id)
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
