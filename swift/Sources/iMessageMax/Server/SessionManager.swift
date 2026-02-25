import Foundation
import Logging
import MCP

/// Manages MCP sessions for the HTTP transport.
///
/// Each session has its own Server instance, enabling clean reconnection.
/// When a client reconnects, they get a new session with a fresh Server.
actor SessionManager {
    /// Complete session state including Server instance
    final class MCPSessionState: @unchecked Sendable {
        let id: String
        let server: Server
        let messageContinuation: AsyncThrowingStream<Data, Error>.Continuation
        let createdAt: Date
        var lastActivity: Date
        var serverTask: Task<Void, Error>?

        init(
            id: String,
            server: Server,
            messageContinuation: AsyncThrowingStream<Data, Error>.Continuation,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.server = server
            self.messageContinuation = messageContinuation
            self.createdAt = createdAt
            self.lastActivity = createdAt
        }
    }

    /// Active sessions keyed by session ID
    private var sessions: [String: MCPSessionState] = [:]

    /// Session timeout duration (1 hour)
    private let sessionTimeout: TimeInterval = 3600

    /// Maximum number of concurrent sessions
    private let maxSessions = 100

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

    init(database: Database, resolver: ContactResolver) {
        self.database = database
        self.resolver = resolver
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
    func createSession() async -> MCPSessionState? {
        guard sessions.count < maxSessions else {
            return nil  // Caller returns 503 Service Unavailable
        }

        // Start cleanup task on first session creation
        if cleanupTask == nil {
            startCleanupTask()
        }

        let sessionId = UUID().uuidString

        // Create per-session Server instance
        let server = Server(
            name: Version.name,
            version: Version.current
        )

        // Register tools on this server instance
        ToolRegistry.registerAll(on: server, db: database, resolver: resolver)

        // Create message stream for this session
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        let messageStream = AsyncThrowingStream<Data, Error> { continuation = $0 }

        let session = MCPSessionState(
            id: sessionId,
            server: server,
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

        // Start server in background
        session.serverTask = Task {
            try await server.start(transport: adapter)
        }

        sessions[sessionId] = session
        return session
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
            terminateSession(sessionId)
            return nil
        }

        return session
    }

    /// Updates the last activity time for a session
    func touch(sessionId: String) {
        guard let session = sessions[sessionId] else { return }
        session.lastActivity = Date()
    }

    /// Terminates a session and cleans up its Server
    func terminate(sessionId: String) {
        terminateSession(sessionId)
    }

    /// Internal session termination with cleanup
    private func terminateSession(_ sessionId: String) {
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

    /// Returns session count for monitoring
    var sessionCount: Int {
        sessions.count
    }

    /// Starts the background cleanup task
    private func startCleanupTask() {
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))  // Run every 5 minutes
                await self?.cleanupExpiredSessions()
            }
        }
    }

    /// Removes expired sessions
    private func cleanupExpiredSessions() {
        let now = Date()
        let expiredIds = sessions.filter { _, session in
            now.timeIntervalSince(session.lastActivity) > sessionTimeout
        }.map(\.key)

        for id in expiredIds {
            terminateSession(id)
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
        await responseHandler(data)
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        return messageStream
    }
}
